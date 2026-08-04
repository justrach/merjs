export async function runBounded(items, concurrency, worker, onError) {
  let next = 0;
  let firstError;
  const runners = Array.from(
    { length: Math.min(concurrency, items.length) },
    async () => {
      while (next < items.length && firstError === undefined) {
        try {
          await worker(items[next++]);
        } catch (error) {
          firstError ??= error;
          onError(error);
        }
      }
    },
  );
  await Promise.all(runners);
  if (firstError !== undefined) throw firstError;
}

function boundedContentLength(headers, limit, message) {
  const value = headers.get("content-length");
  if (value === null) return;
  if (!/^(0|[1-9][0-9]*)$/.test(value)) throw new Error(`invalid ${message} content-length`);
  const length = Number(value);
  if (!Number.isSafeInteger(length) || length > limit) throw new Error(`${message} too large`);
}

async function readStreamBounded(body, limit, message, signal) {
  if (!body) return new Uint8Array();
  const reader = body.getReader();
  const chunks = [];
  let length = 0;
  let complete = false;
  const cancel = () => { void reader.cancel(signal?.reason).catch(() => {}); };
  signal?.addEventListener("abort", cancel, { once: true });
  try {
    while (true) {
      if (signal?.aborted) throw signal.reason;
      const { done, value } = await reader.read();
      if (signal?.aborted) throw signal.reason;
      if (done) { complete = true; break; }
      if (value.byteLength > limit - length) {
        await reader.cancel(`${message} too large`).catch(() => {});
        throw new Error(`${message} too large`);
      }
      chunks.push(value);
      length += value.byteLength;
    }
  } finally {
    signal?.removeEventListener("abort", cancel);
    if (!complete) await reader.cancel(signal?.reason || `${message} read failed`).catch(() => {});
    reader.releaseLock();
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

export async function readBoundedRequestBody(request, limit, maxDurationMs = 30000) {
  const controller = new AbortController();
  const abortFromRequest = () => controller.abort(request.signal?.reason);
  if (request.signal?.aborted) abortFromRequest();
  else request.signal?.addEventListener("abort", abortFromRequest, { once: true });
  const timeoutError = new Error("request body deadline exceeded");
  timeoutError.name = "TimeoutError";
  const timeout = setTimeout(() => controller.abort(timeoutError), maxDurationMs);
  try {
    if (controller.signal.aborted) throw controller.signal.reason;
    try {
      boundedContentLength(request.headers, limit, "request body");
    } catch (error) {
      await request.body?.cancel(error.message).catch(() => {});
      throw error;
    }
    return await readStreamBounded(request.body, limit, "request body", controller.signal);
  } finally {
    clearTimeout(timeout);
    request.signal?.removeEventListener("abort", abortFromRequest);
  }
}

export async function readBoundedBody(response, limit, signal) {
  try {
    boundedContentLength(response.headers, limit, "fetch response");
  } catch (error) {
    await response.body?.cancel(error.message).catch(() => {});
    throw error;
  }
  if (!response.body) return new Uint8Array();

  const reader = response.body.getReader();
  const chunks = [];
  let length = 0;
  let complete = false;
  const cancel = () => { void reader.cancel(signal?.reason).catch(() => {}); };
  signal?.addEventListener("abort", cancel, { once: true });
  try {
    while (true) {
      if (signal?.aborted) throw signal.reason;
      const { done, value } = await reader.read();
      if (signal?.aborted) throw signal.reason;
      if (done) { complete = true; break; }
      if (value.byteLength > limit - length)
        throw new Error("fetch response too large");
      chunks.push(value);
      length += value.byteLength;
    }
  } finally {
    signal?.removeEventListener("abort", cancel);
    if (!complete) await reader.cancel(signal?.reason || "fetch body read failed").catch(() => {});
    reader.releaseLock();
  }
  const body = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}


export async function collectFetchRounds(options) {
  const {
    maxRounds,
    maxRequests,
    maxRequestBytes,
    maxDurationMs = 30000,
    externalSignal,
    restore,
    collect,
    fetchRound,
  } = options;
  const controller = new AbortController();
  const abortFromExternal = () => controller.abort(externalSignal?.reason);
  if (externalSignal?.aborted) abortFromExternal();
  else externalSignal?.addEventListener("abort", abortFromExternal, { once: true });
  const timeout = setTimeout(
    () => controller.abort(new Error("fetch protocol deadline exceeded")),
    maxDurationMs,
  );
  let expectedState = new Uint8Array();
  const results = [];
  let requestBytes = 0;

  try {
    if (controller.signal.aborted) throw controller.signal.reason;
    for (let round = 0; round < maxRounds; round++) {
      if (controller.signal.aborted) throw controller.signal.reason;
      // Round zero starts from the application snapshot and has no protocol
      // state yet. Later rounds restore only validated, versioned state.
      if (expectedState.byteLength !== 0 || results.length !== 0)
        restore(expectedState, results);
      const collected = collect(results.length);
      if (!collected || !Number.isInteger(collected.errorCode) ||
          !Number.isInteger(collected.requestBytes) || collected.requestBytes < 0 ||
          !(collected.expectedState instanceof Uint8Array) || !Array.isArray(collected.requests))
        throw new Error("invalid WASM fetch collection");
      if (collected.errorCode !== 0)
        throw new Error(`WASM fetch collection error ${collected.errorCode}`);
      if (collected.requestBytes > maxRequestBytes - requestBytes)
        throw new Error("total fetch request bytes exceeded");
      requestBytes += collected.requestBytes;
      expectedState = collected.expectedState;
      if (collected.requests.length === 0) {
        restore(expectedState, results);
        return { requestBytes, responseCount: results.length };
      }
      if (results.length + collected.requests.length > maxRequests)
        throw new Error("too many fetch requests");
      const expectedResults = results.length + collected.requests.length;
      await fetchRound(collected.requests, results, controller.signal);
      if (results.length !== expectedResults || results.includes(undefined) || results.includes(null))
        throw new Error("incomplete fetch round");
    }
    throw new Error("fetch round limit exceeded");
  } catch (error) {
    controller.abort(error);
    throw error;
  } finally {
    clearTimeout(timeout);
    externalSignal?.removeEventListener("abort", abortFromExternal);
  }
}
