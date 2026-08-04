// Vercel Edge Function — merjs WASM adapter.

import wasmModule from "../merjs.wasm?module";

export const config = { runtime: "edge" };

const MAX_BODY_BYTES = 1024 * 1024;
const MAX_FETCH_REQUESTS = 64;
const MAX_FETCH_BYTES = 1024 * 1024;
const MAX_FETCH_RESPONSE_SIZE = 8 * 1024 * 1024;
const MAX_FETCH_RESPONSE_BYTES = 32 * 1024 * 1024;
const decoder = new TextDecoder("utf-8", { fatal: true });
const encoder = new TextEncoder();

async function readBody(message, limit, signal) {
  const length = message.headers.get("content-length");
  if (length !== null && (!/^(0|[1-9][0-9]*)$/.test(length) ||
      !Number.isSafeInteger(Number(length)) || Number(length) > limit)) {
    await message.body?.cancel("invalid or oversized body").catch(() => {});
    throw new Error("invalid or oversized body");
  }
  if (!message.body) return new Uint8Array();
  const reader = message.body.getReader();
  const chunks = [];
  let size = 0;
  let complete = false;
  const abort = () => { void reader.cancel(signal?.reason).catch(() => {}); };
  signal?.addEventListener("abort", abort, { once: true });
  try {
    while (true) {
      if (signal?.aborted) throw signal.reason;
      const { done, value } = await reader.read();
      if (signal?.aborted) throw signal.reason;
      if (done) { complete = true; break; }
      if (value.byteLength > limit - size) {
        await reader.cancel("body too large").catch(() => {});
        throw new Error("body too large");
      }
      chunks.push(value); size += value.byteLength;
    }
  } finally {
    signal?.removeEventListener("abort", abort);
    if (!complete) await reader.cancel(signal?.reason || "body read failed").catch(() => {});
    reader.releaseLock();
  }
  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
  return body;
}

async function readRequestBody(request, limit, maxDurationMs = 30000) {
  const controller = new AbortController();
  const abortFromRequest = () => controller.abort(request.signal?.reason);
  if (request.signal?.aborted) abortFromRequest();
  else request.signal?.addEventListener("abort", abortFromRequest, { once: true });
  const timeoutError = new Error("request body deadline exceeded");
  timeoutError.name = "TimeoutError";
  const timeout = setTimeout(() => controller.abort(timeoutError), maxDurationMs);
  try {
    if (controller.signal.aborted) throw controller.signal.reason;
    return await readBody(request, limit, controller.signal);
  } finally {
    clearTimeout(timeout);
    request.signal?.removeEventListener("abort", abortFromRequest);
  }
}

async function encodeRequest(request) {
  const url = new URL(request.url);
  const clientIdentity = encoder.encode(request.headers.get("x-vercel-forwarded-for") || "");
  const parts = [encoder.encode(request.method), encoder.encode(url.pathname + url.search),
    await readRequestBody(request, MAX_BODY_BYTES), encoder.encode(request.headers.get("cookie") || ""), clientIdentity];
  const forwarded = ["accept", "authorization", "content-type", "origin", "referer", "user-agent"];
  const headers = forwarded.flatMap(name => {
    const value = request.headers.get(name);
    return value === null ? [] : [[encoder.encode(name), encoder.encode(value)]];
  });
  const headerBytes = headers.reduce((n, [name, value]) => n + 8 + name.length + value.length, 0);
  const total = 24 + parts.reduce((n, part) => n + part.length, 0) + headerBytes;
  if (!parts[0].length || parts[0].length > 16 || !parts[1].length || parts[1].length > 16 * 1024 ||
      parts[2].length > MAX_BODY_BYTES || parts[3].length > 16 * 1024 || parts[4].length > 256 ||
      headerBytes > 64 * 1024 || headers.length > 16 || total > 2 * 1024 * 1024)
    throw new Error("request metadata too large");
  const bytes = new Uint8Array(total);
  const view = new DataView(bytes.buffer);
  parts.forEach((part, index) => view.setUint32(index * 4, part.length, true));
  view.setUint32(20, headers.length, true);
  let offset = 24;
  for (const part of parts) { bytes.set(part, offset); offset += part.length; }
  for (const [name, value] of headers) {
    view.setUint32(offset, name.length, true); view.setUint32(offset + 4, value.length, true); offset += 8;
    bytes.set(name, offset); offset += name.length; bytes.set(value, offset); offset += value.length;
  }
  return bytes;
}

function decodeResponse(bytes) {
  if (bytes.length < 16 || bytes.length > 32 * 1024 * 1024) throw new Error("invalid response size");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.getUint32(0, true) !== 0x3152454d || view.getUint16(4, true) !== 1 || view.getUint16(10, true) !== 0)
    throw new Error("unsupported MER1 response");
  const status = view.getUint16(6, true);
  const count = view.getUint16(8, true);
  const bodyLength = view.getUint32(12, true);
  if (status < 100 || status > 599 || !count || count > 10) throw new Error("invalid response metadata");
  const headers = [];
  let offset = 16;
  let headerBytes = 0;
  let contentTypes = 0;
  let locations = 0;
  for (let i = 0; i < count; i++) {
    if (offset + 6 > bytes.length) throw new Error("truncated response header");
    const nameLength = view.getUint16(offset, true);
    const valueLength = view.getUint32(offset + 2, true);
    offset += 6; headerBytes += 6 + nameLength + valueLength;
    if (!nameLength || nameLength > 64 || valueLength > 4096 || headerBytes > 32 * 1024 ||
        nameLength + valueLength > bytes.length - offset) throw new Error("invalid response header length");
    const name = decoder.decode(bytes.subarray(offset, offset + nameLength)); offset += nameLength;
    const value = decoder.decode(bytes.subarray(offset, offset + valueLength)); offset += valueLength;
    if (!/^[!#$%&'*+.^_`|~0-9a-z-]+$/.test(name) || /[\0\r\n\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value) ||
        !["content-type", "location", "set-cookie"].includes(name)) throw new Error("invalid response header");
    if (name === "content-type") contentTypes++;
    if (name === "location") locations++;
    headers.push([name, value]);
  }
  if (contentTypes !== 1 || locations > 1 || offset + bodyLength !== bytes.length ||
      (locations === 1) !== (status >= 300 && status < 400)) throw new Error("inconsistent response metadata");
  return { status, headers, body: bytes.slice(offset) };
}

function decodeFetches(bytes, firstId) {
  if (bytes.length > MAX_FETCH_BYTES) throw new Error("fetch requests too large");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 0;
  const u32 = () => { if (offset + 4 > bytes.length) throw new Error("truncated fetch"); const n = view.getUint32(offset, true); offset += 4; return n; };
  const take = n => { if (n > bytes.length - offset) throw new Error("truncated fetch"); const value = bytes.slice(offset, offset + n); offset += n; return value; };
  const requests = [];
  while (offset < bytes.length) {
    const id = u32(); const maxResponseSize = u32(); const methodLength = u32(); const urlLength = u32();
    const bodyLength = u32(); const headerCount = u32();
    if (id !== firstId + requests.length || id >= MAX_FETCH_REQUESTS || maxResponseSize > MAX_FETCH_RESPONSE_SIZE || headerCount > 1024)
      throw new Error("invalid fetch request");
    const method = decoder.decode(take(methodLength));
    const url = decoder.decode(take(urlLength));
    const body = bodyLength === 0xffffffff ? undefined : take(bodyLength);
    const headers = [];
    for (let i = 0; i < headerCount; i++) { const nl = u32(); const vl = u32(); headers.push([decoder.decode(take(nl)), decoder.decode(take(vl))]); }
    requests.push({ id, maxResponseSize, method, url, body, headers });
  }
  return requests;
}

function provide(wasm, result) {
  const ptr = result.body.length ? wasm.alloc(result.body.length) : 0;
  if (result.body.length && !ptr) throw new Error("fetch allocation failed");
  try {
    if (result.body.length) new Uint8Array(wasm.memory.buffer).set(result.body, ptr);
    if (wasm.provide_fetch_result(result.id, result.status, ptr || 0, result.body.length) !== 0) throw new Error("fetch result rejected");
  } finally { if (result.body.length) wasm.dealloc(ptr, result.body.length); }
}

function restore(wasm, snapshot, expected, results) {
  new Uint8Array(wasm.memory.buffer, 0, snapshot.length).set(snapshot);
  const ptr = expected.length ? wasm.alloc(expected.length) : 0;
  if (expected.length && !ptr) throw new Error("state allocation failed");
  try {
    if (expected.length) new Uint8Array(wasm.memory.buffer).set(expected, ptr);
    if (wasm.restore_expected_state(ptr || 0, expected.length) !== 0) throw new Error("state restore failed");
  } finally { if (expected.length) wasm.dealloc(ptr, expected.length); }
  for (const result of results) provide(wasm, result);
}

async function replayFetches(wasm, requestPtr, requestLength, snapshot, externalSignal) {
  const results = [];
  let expected = new Uint8Array();
  let requestBytes = 0;
  let responseBytes = 0;
  const controller = new AbortController();
  const abortFromExternal = () => controller.abort(externalSignal?.reason);
  if (externalSignal?.aborted) abortFromExternal();
  else externalSignal?.addEventListener("abort", abortFromExternal, { once: true });
  const timeout = setTimeout(() => controller.abort(new Error("fetch deadline exceeded")), 30000);
  try {
    if (controller.signal.aborted) throw controller.signal.reason;
    for (let round = 0; round <= MAX_FETCH_REQUESTS; round++) {
      if (controller.signal.aborted) throw controller.signal.reason;
      if (expected.length || results.length) restore(wasm, snapshot, expected, results);
      const ptr = wasm.collect_fetch_urls(requestPtr, requestLength);
      const length = wasm.collect_urls_len();
      if (wasm.fetch_protocol_error() !== 0 || length > MAX_FETCH_BYTES - requestBytes) throw new Error("fetch collection failed");
      requestBytes += length;
      const requests = decodeFetches(new Uint8Array(wasm.memory.buffer, ptr, length).slice(), results.length);
      expected = new Uint8Array(wasm.memory.buffer, wasm.expected_state_ptr(), wasm.expected_state_len()).slice();
      if (!requests.length) { restore(wasm, snapshot, expected, results); return; }
      if (results.length + requests.length > MAX_FETCH_REQUESTS) throw new Error("too many fetches");
      for (const item of requests) {
        const response = await fetch(item.url, { method: item.method, headers: item.headers, body: item.body, signal: controller.signal });
        const body = await readBody(response, item.maxResponseSize, controller.signal);
        if (body.length > MAX_FETCH_RESPONSE_BYTES - responseBytes) throw new Error("fetch responses too large");
        responseBytes += body.length;
        const result = { id: item.id, status: response.status, body };
        provide(wasm, result); results[item.id] = result;
      }
    }
    throw new Error("fetch round limit exceeded");
  } finally {
    clearTimeout(timeout);
    externalSignal?.removeEventListener("abort", abortFromExternal);
  }
}

function injectEnvironment(wasm) {
  if (typeof wasm.__mer_set_env_status !== "function") throw new Error("environment injection unavailable");
  const bindings = typeof process !== "undefined" && process.env ? process.env : {};
  let totalBytes = 0;
  for (const [key, value] of Object.entries(bindings)) {
    if (typeof value !== "string") continue;
    const keyBytes = encoder.encode(key);
    const valueBytes = encoder.encode(value);
    if (!keyBytes.length || keyBytes.length > 256 || valueBytes.length > 64 * 1024 ||
        totalBytes + keyBytes.length + valueBytes.length > 1024 * 1024)
      throw new Error("environment bindings exceed limits");
    const keyPtr = wasm.alloc(keyBytes.length);
    const valuePtr = valueBytes.length ? wasm.alloc(valueBytes.length) : 0;
    try {
      if (!keyPtr || (valueBytes.length && !valuePtr)) throw new Error("environment allocation failed");
      const memory = new Uint8Array(wasm.memory.buffer);
      memory.set(keyBytes, keyPtr);
      if (valueBytes.length) memory.set(valueBytes, valuePtr);
      if (wasm.__mer_set_env_status(keyPtr, keyBytes.length, valuePtr || 0, valueBytes.length) !== 0)
        throw new Error("environment injection failed");
    } finally {
      if (keyPtr) wasm.dealloc(keyPtr, keyBytes.length);
      if (valueBytes.length && valuePtr) wasm.dealloc(valuePtr, valueBytes.length);
    }
    totalBytes += keyBytes.length + valueBytes.length;
  }
}

function edgeResponse(request, body, init = {}) {
  const status = init.status ?? 200;
  const responseBody = request.method === "HEAD" || status === 204 || status === 205 || status === 304 ? null : body;
  return new Response(responseBody, init);
}

export default async function handler(request) {
  let wasm;
  try {
    // All allocator, router, bridge, and response state is request-local.
    wasm = new WebAssembly.Instance(wasmModule, {}).exports;
    wasm.init();
    injectEnvironment(wasm);
  } catch (_) { return edgeResponse(request, "WASM initialization failed", { status: 500 }); }

  let encoded;
  try { encoded = await encodeRequest(request); }
  catch (_) { return edgeResponse(request, "Request Too Large", { status: 413 }); }
  const requestPtr = wasm.alloc(encoded.length);
  if (!requestPtr) return edgeResponse(request, "WASM alloc failed", { status: 500 });
  new Uint8Array(wasm.memory.buffer).set(encoded, requestPtr);
  try {
    try {
      await replayFetches(wasm, requestPtr, encoded.length, new Uint8Array(wasm.memory.buffer).slice(), request.signal);
    } catch (_) {
      return edgeResponse(request, "Fetch Bridge Error", { status: 502 });
    }
    const responsePtr = wasm.handle(requestPtr, encoded.length);
    if (wasm.fetch_protocol_error() !== 0) {
      if (responsePtr) wasm.response_done();
      return edgeResponse(request, "Fetch Bridge Error", { status: 502 });
    }
    if (!responsePtr) return edgeResponse(request, "Not Found", { status: 404 });
    try {
      const response = decodeResponse(new Uint8Array(wasm.memory.buffer, responsePtr, wasm.response_len()));
      return edgeResponse(request, response.body, { status: response.status, headers: response.headers });
    } finally { wasm.response_done(); }
  } catch (_) { return edgeResponse(request, "Internal Server Error", { status: 500 }); }
  finally { wasm.dealloc(requestPtr, encoded.length); }
}
