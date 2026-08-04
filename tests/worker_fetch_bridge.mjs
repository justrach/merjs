import assert from "node:assert/strict";
import { collectFetchRounds, readBoundedBody, readBoundedRequestBody, runBounded } from "../examples/site/worker/worker/fetch-bridge.js";

const encoder = new TextEncoder();
let restored = [];
let rounds = 0;
const fetched = [];
const summary = await collectFetchRounds({
  maxRounds: 4,
  maxRequests: 4,
  maxRequestBytes: 128,
  restore(expectedState, results) {
    assert.notEqual(expectedState.byteLength, 0, "round zero must not restore empty protocol state");
    restored = results.map(result => ({ ...result, body: result.body.slice() }));
  },
  collect(firstId) {
    rounds++;
    if (firstId === 0) {
      return {
        errorCode: 0,
        requestBytes: 24,
        expectedState: encoder.encode("round-1"),
        requests: [{ id: 0, url: "https://example.test/index" }],
      };
    }
    assert.equal(new TextDecoder().decode(restored[0].body), "detail-id");
    if (firstId === 1) {
      return {
        errorCode: 0,
        requestBytes: 32,
        expectedState: encoder.encode("round-2"),
        requests: [{ id: 1, url: `https://example.test/${new TextDecoder().decode(restored[0].body)}` }],
      };
    }
    assert.equal(new TextDecoder().decode(restored[1].body), "complete");
    return { errorCode: 0, requestBytes: 0, expectedState: encoder.encode("complete"), requests: [] };
  },
  async fetchRound(requests, results) {
    for (const request of requests) {
      fetched.push(request.url);
      results[request.id] = {
        id: request.id,
        status: 200,
        body: encoder.encode(request.id === 0 ? "detail-id" : "complete"),
      };
    }
  },
});

assert.deepEqual(fetched, ["https://example.test/index", "https://example.test/detail-id"]);
assert.equal(rounds, 3, "dependent request was not discovered iteratively");
assert.equal(restored.length, 2, "final replay state omitted fetched results");
assert.deepEqual(summary, { requestBytes: 56, responseCount: 2 });

await assert.rejects(collectFetchRounds({
  maxRounds: 1,
  maxRequests: 1,
  maxRequestBytes: 1,
  restore() {},
  collect() { return { errorCode: 0, requestBytes: 2, expectedState: new Uint8Array(), requests: [] }; },
  async fetchRound() {},
}), /request bytes exceeded/);

await assert.rejects(collectFetchRounds({
  maxRounds: 1,
  maxRequests: 1,
  maxRequestBytes: 1,
  restore() {},
  collect() { return { errorCode: 0, requestBytes: 0, expectedState: new Uint8Array(), requests: [{ id: 0 }] }; },
  async fetchRound(_requests, results) { results[0] = { id: 0, status: 200, body: new Uint8Array() }; },
}), /round limit exceeded/);

let deadlineSignal;
await assert.rejects(collectFetchRounds({
  maxRounds: 1,
  maxRequests: 1,
  maxRequestBytes: 1,
  maxDurationMs: 1,
  restore() {},
  collect() {
    return {
      errorCode: 0,
      requestBytes: 0,
      expectedState: new Uint8Array(),
      requests: [{ id: 0 }],
    };
  },
  async fetchRound(_requests, _results, signal) {
    deadlineSignal = signal;
    await new Promise(resolve => signal.addEventListener("abort", resolve, { once: true }));
    throw signal.reason;
  },
}), /deadline exceeded/);
assert.equal(deadlineSignal.aborted, true, "protocol deadline did not abort the shared signal");

const externalController = new AbortController();
const externallyCanceled = collectFetchRounds({
  maxRounds: 1,
  maxRequests: 1,
  maxRequestBytes: 1,
  externalSignal: externalController.signal,
  restore() {},
  collect() {
    return {
      errorCode: 0,
      requestBytes: 0,
      expectedState: new Uint8Array(),
      requests: [{ id: 0 }],
    };
  },
  async fetchRound(_requests, _results, signal) {
    await new Promise(resolve => signal.addEventListener("abort", resolve, { once: true }));
    throw signal.reason;
  },
});
externalController.abort(new Error("client disconnected"));
await assert.rejects(externallyCanceled, /client disconnected/);

let canceled = 0;
const bodyController = new AbortController();
const response = {
  headers: new Headers(),
  body: new ReadableStream({
    pull() {},
    cancel() { canceled++; },
  }),
};
const bodyRead = readBoundedBody(response, 16, bodyController.signal);
bodyController.abort(new Error("deterministic cancellation"));
await assert.rejects(bodyRead, /deterministic cancellation/);
assert.equal(canceled, 1, "aborted response body reader was not canceled");

let oversizedCanceled = 0;
await assert.rejects(readBoundedBody({
  headers: new Headers({ "content-length": "17" }),
  body: new ReadableStream({ cancel() { oversizedCanceled++; } }),
}, 16), /too large/);
assert.equal(oversizedCanceled, 1, "oversized content-length body was not canceled");

for (const contentLength of ["01", "+1", "1.0", "1, 1", "9007199254740992"]) {
  let invalidCanceled = 0;
  await assert.rejects(readBoundedRequestBody({
    headers: new Headers({ "content-length": contentLength }),
    body: new ReadableStream({ cancel() { invalidCanceled++; } }),
  }, 16), /content-length|too large/);
  assert.equal(invalidCanceled, 1, `${contentLength}: invalid request body was not canceled`);
}

let requestCanceled = 0;
await assert.rejects(readBoundedRequestBody({
  headers: new Headers(),
  body: new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(17)); },
    cancel() { requestCanceled++; },
  }),
}, 16), /too large/);
assert.equal(requestCanceled, 1, "streaming request overflow was not canceled immediately");

let stalledRequestCanceled = 0;
await assert.rejects(readBoundedRequestBody({
  headers: new Headers(),
  signal: new AbortController().signal,
  body: new ReadableStream({
    pull() {},
    cancel() { stalledRequestCanceled++; },
  }),
}, 16, 1), /deadline exceeded/);
assert.equal(stalledRequestCanceled, 1, "stalled request body was not canceled at its deadline");

let siblingSettled = false;
let abortObserved = false;
await assert.rejects(runBounded([0, 1], 2, async item => {
  if (item === 0) throw new Error("first runner failed");
  await new Promise(resolve => setTimeout(resolve, 5));
  abortObserved = true;
  siblingSettled = true;
}, () => { abortObserved = true; }), /first runner failed/);
assert.equal(abortObserved, true, "parallel failure did not trigger abort callback");
assert.equal(siblingSettled, true, "parallel failure returned before sibling cleanup settled");
