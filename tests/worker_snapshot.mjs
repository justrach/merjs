import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const bytes = await readFile(process.argv[2] || "examples/site/worker/worker/merjs.wasm");
const { instance } = await WebAssembly.instantiate(bytes, {});
const wasm = instance.exports;
assert.equal(typeof wasm.__mer_set_env_status, "function", "missing observable environment injection");
wasm.init();

const encoder = new TextEncoder();
const method = encoder.encode("GET");
const target = encoder.encode("/about?phase=test");
const clientIdentity = encoder.encode("198.51.100.9");
const request = new Uint8Array(24 + method.length + target.length + clientIdentity.length);
const view = new DataView(request.buffer);
view.setUint32(0, method.length, true);
view.setUint32(4, target.length, true);
view.setUint32(16, clientIdentity.length, true);
request.set(method, 24);
request.set(target, 24 + method.length);
request.set(clientIdentity, 24 + method.length + target.length);

const requestPtr = wasm.alloc(request.length);
assert.notEqual(requestPtr, 0);
new Uint8Array(wasm.memory.buffer).set(request, requestPtr);
const applicationState = new Uint8Array(wasm.memory.buffer).slice();

wasm.collect_fetch_urls(requestPtr, request.length);
assert.equal(wasm.fetch_protocol_error(), 0);
assert.equal(wasm.collect_urls_len(), 0, "focused route unexpectedly fetched");
assert.equal(wasm.dispatch_count(), 1);
const expected = new Uint8Array(
  wasm.memory.buffer,
  wasm.expected_state_ptr(),
  wasm.expected_state_len(),
).slice();
assert.ok(expected.length >= 8, "expected-state protocol header missing");
assert.equal(new DataView(expected.buffer).getUint32(0, true), 0x3246534d, "expected-state protocol version changed");

const malformed = new Uint8Array(24);
const malformedView = new DataView(malformed.buffer);
malformedView.setUint32(0, 3, true);
malformedView.setUint32(4, 1, true);
malformedView.setUint32(8, 1024 * 1024 + 1, true);
const malformedPtr = wasm.alloc(malformed.length);
new Uint8Array(wasm.memory.buffer).set(malformed, malformedPtr);
wasm.collect_fetch_urls(malformedPtr, malformed.length);
assert.equal(wasm.collect_urls_len(), 0, "failed collection retained prior request bytes");
assert.equal(wasm.fetch_protocol_error(), 0, "failed collection retained prior fetch error");
assert.equal(wasm.expected_state_len(), 0, "failed collection retained prior expected state");
wasm.dealloc(malformedPtr, malformed.length);

new Uint8Array(wasm.memory.buffer, 0, applicationState.length).set(applicationState);
const expectedPtr = expected.length === 0 ? 0 : wasm.alloc(expected.length);
if (expected.length !== 0) new Uint8Array(wasm.memory.buffer).set(expected, expectedPtr);
assert.equal(wasm.restore_expected_state(expectedPtr, expected.length), 0);
if (expected.length !== 0) wasm.dealloc(expectedPtr, expected.length);

const responsePtr = wasm.handle(requestPtr, request.length);
assert.notEqual(responsePtr, 0);
assert.equal(wasm.dispatch_count(), 1, "dry-render route side effects survived memory restore");
assert.equal(wasm.fetch_protocol_error(), 0);
const response = new Uint8Array(wasm.memory.buffer, responsePtr, wasm.response_len());
const responseView = new DataView(response.buffer, response.byteOffset, response.byteLength);
assert.equal(responseView.getUint32(0, true), 0x3152454d, "response protocol magic changed");
assert.equal(responseView.getUint16(4, true), 1, "unsupported response protocol version");
assert.equal(responseView.getUint16(10, true), 0, "response reserved field is nonzero");
assert.ok(responseView.getUint16(8, true) >= 1, "response omitted content-type");

function decodeFixture(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  assert.ok(bytes.length >= 16 && bytes.length <= 32 * 1024 * 1024);
  assert.equal(view.getUint32(0, true), 0x3152454d);
  assert.equal(view.getUint16(4, true), 1);
  const status = view.getUint16(6, true);
  const count = view.getUint16(8, true);
  const bodyLength = view.getUint32(12, true);
  assert.ok(status >= 100 && status <= 599 && count > 0 && count <= 10);
  let offset = 16;
  const headers = [];
  for (let i = 0; i < count; i++) {
    assert.ok(offset + 6 <= bytes.length);
    const nameLength = view.getUint16(offset, true);
    const valueLength = view.getUint32(offset + 2, true);
    offset += 6;
    assert.ok(nameLength > 0 && nameLength <= 64 && valueLength <= 4096 && offset + nameLength + valueLength <= bytes.length);
    const name = new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(offset, offset + nameLength));
    offset += nameLength;
    const value = new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(offset, offset + valueLength));
    offset += valueLength;
    assert.match(name, /^[!#$%&'*+.^_`|~0-9a-z-]+$/);
    assert.doesNotMatch(value, /[\0\r\n]/);
    headers.push([name, value]);
  }
  assert.equal(offset + bodyLength, bytes.length);
  return { status, headers };
}

function fixture(status, headers, body = new Uint8Array()) {
  const entries = headers.map(([name, value]) => [encoder.encode(name), encoder.encode(value)]);
  const length = 16 + entries.reduce((n, [name, value]) => n + 6 + name.length + value.length, 0) + body.length;
  const bytes = new Uint8Array(length);
  const view = new DataView(bytes.buffer);
  view.setUint32(0, 0x3152454d, true);
  view.setUint16(4, 1, true);
  view.setUint16(6, status, true);
  view.setUint16(8, entries.length, true);
  view.setUint32(12, body.length, true);
  let offset = 16;
  for (const [name, value] of entries) {
    view.setUint16(offset, name.length, true);
    view.setUint32(offset + 2, value.length, true);
    offset += 6;
    bytes.set(name, offset); offset += name.length;
    bytes.set(value, offset); offset += value.length;
  }
  bytes.set(body, offset);
  return bytes;
}

const redirect = decodeFixture(fixture(303, [
  ["content-type", "text/html; charset=utf-8"],
  ["location", "/dashboard"],
  ["set-cookie", "session=abc; Path=/; HttpOnly; SameSite=Lax"],
  ["set-cookie", "csrf=xyz; Path=/; SameSite=Strict"],
]));
assert.equal(redirect.headers.filter(([name]) => name === "set-cookie").length, 2, "repeated cookies collapsed");
assert.throws(() => decodeFixture(fixture(200, [["bad header", "value"]])));
assert.throws(() => decodeFixture(fixture(200, [["content-type", "x\r\ninjected: yes"]])));
assert.throws(() => decodeFixture(fixture(200, Array.from({ length: 11 }, () => ["set-cookie", "a=b"]))));

for (const shimPath of [
  "examples/kanban/worker/worker.js",
  "examples/singapore-data-dashboard/worker/worker.js",
  "examples/site/worker/worker/worker.js",
]) {
  const shim = await readFile(shimPath, "utf8");
  assert.doesNotMatch(shim, /x-forwarded-for/i, `${shimPath} trusts a general forwarding header`);
  assert.match(shim, /headers\.get\(["']cf-connecting-ip["']\)/, `${shimPath} omits Cloudflare client identity`);
}

wasm.response_done();
wasm.dealloc(requestPtr, request.length);
