// worker.js — Cloudflare Workers handler for merjs kanban example

import merWasm from "./merjs.wasm";

const merModule = Promise.resolve(merWasm).then(source =>
  source instanceof WebAssembly.Module ? source : WebAssembly.compile(source));

const securityHeaders = {
  "strict-transport-security": "max-age=63072000; includeSubDomains; preload",
  "content-security-policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  "x-frame-options": "DENY",
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "cross-origin-opener-policy": "same-origin",
  "permissions-policy": "camera=(), microphone=(), geolocation=()",
};

function workerResponse(body, init = {}) {
  const headers = new Headers(securityHeaders);
  if (Array.isArray(init.headers)) {
    for (const [name, value] of init.headers) headers.append(name, value);
  } else {
    new Headers(init.headers || {}).forEach((value, name) => headers.append(name, value));
  }
  const status = init.status ?? 200;
  const responseBody = status === 204 || status === 205 || status === 304 ? null : body;
  return new Response(responseBody, { ...init, headers });
}

function finalizeWorkerResponse(request, response) {
  if (request.method !== "HEAD" || response.body === null) return response;
  return new Response(null, { status: response.status, statusText: response.statusText, headers: response.headers });
}

const RESPONSE_MAGIC = 0x3152454d;
const RESPONSE_VERSION = 1;
const MAX_RESPONSE_HEADERS = 10;
const MAX_RESPONSE_HEADER_NAME_BYTES = 64;
const MAX_RESPONSE_HEADER_VALUE_BYTES = 4096;
const MAX_RESPONSE_HEADER_BYTES = 32 * 1024;
const headerNamePattern = /^[!#$%&'*+.^_`|~0-9a-z-]+$/;

function decodeWorkerResponse(bytes, decoder) {
  if (bytes.byteLength < 16 || bytes.byteLength > 32 * 1024 * 1024) throw new Error("invalid WASM response size");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.getUint32(0, true) !== RESPONSE_MAGIC || view.getUint16(4, true) !== RESPONSE_VERSION ||
      view.getUint16(10, true) !== 0) throw new Error("unsupported WASM response protocol");
  const status = view.getUint16(6, true);
  const count = view.getUint16(8, true);
  const bodyLength = view.getUint32(12, true);
  if (status < 100 || status > 599 || count === 0 || count > MAX_RESPONSE_HEADERS) throw new Error("invalid WASM response metadata");
  const headers = [];
  let offset = 16;
  let contentTypes = 0;
  let locations = 0;
  for (let i = 0; i < count; i++) {
    if (offset + 6 > bytes.byteLength) throw new Error("truncated WASM response header");
    const nameLength = view.getUint16(offset, true);
    const valueLength = view.getUint32(offset + 2, true);
    offset += 6;
    if (!nameLength || nameLength > MAX_RESPONSE_HEADER_NAME_BYTES || valueLength > MAX_RESPONSE_HEADER_VALUE_BYTES ||
        offset + nameLength + valueLength > bytes.byteLength || offset + nameLength + valueLength - 16 > MAX_RESPONSE_HEADER_BYTES)
      throw new Error("invalid WASM response header length");
    const name = decoder.decode(bytes.subarray(offset, offset + nameLength));
    offset += nameLength;
    const value = decoder.decode(bytes.subarray(offset, offset + valueLength));
    offset += valueLength;
    if (!headerNamePattern.test(name) || /[\0\r\n\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value) ||
        (name !== "content-type" && name !== "location" && name !== "set-cookie"))
      throw new Error("invalid WASM response header");
    if (name === "content-type") contentTypes++;
    if (name === "location") locations++;
    headers.push([name, value]);
  }
  if (contentTypes !== 1 || locations > 1 || offset + bodyLength !== bytes.byteLength ||
      (locations === 1) !== (status >= 300 && status < 400)) throw new Error("inconsistent WASM response metadata");
  return { status, headers, body: bytes.slice(offset) };
}

const resolverScript = "(()=>{for(const s of document.querySelectorAll('template[data-mer-resolve]')){for(const p of document.querySelectorAll('[data-mer-placeholder]')){if(p.getAttribute('data-mer-placeholder')===s.getAttribute('data-mer-resolve')){p.replaceWith(s.content);s.remove();break}}}})();";

function resolverResponse(request) {
  return workerResponse(request.method === "HEAD" ? null : resolverScript, {
    headers: { "content-type": "application/javascript; charset=utf-8", "cache-control": "public, max-age=3600" },
  });
}

function injectEnv(wasm, env) {
  if (!wasm.__mer_set_env_status)
    throw new Error("WASM module does not expose observable environment injection");
  const encoder = new TextEncoder();
  for (const [key, value] of Object.entries(env)) {
    if (typeof value !== "string") continue;
    const keyBytes = encoder.encode(key);
    const valueBytes = encoder.encode(value);
    const keyPtr = keyBytes.length === 0 ? 0 : wasm.alloc(keyBytes.length);
    const valuePtr = valueBytes.length === 0 ? 0 : wasm.alloc(valueBytes.length);
    try {
      if ((keyBytes.length && !keyPtr) || (valueBytes.length && !valuePtr))
        throw new Error(`WASM env allocation failed for ${key}`);
      const memory = new Uint8Array(wasm.memory.buffer);
      memory.set(keyBytes, keyPtr);
      memory.set(valueBytes, valuePtr);
      if (wasm.__mer_set_env_status(keyPtr, keyBytes.length, valuePtr, valueBytes.length) !== 0)
        throw new Error(`WASM env injection failed for ${key}`);
    } finally {
      if (keyBytes.length && keyPtr) wasm.dealloc(keyPtr, keyBytes.length);
      if (valueBytes.length && valuePtr) wasm.dealloc(valuePtr, valueBytes.length);
    }
  }
}

const forwardedHeaders = ["accept", "authorization", "content-type", "origin", "referer", "user-agent"];

async function readIncomingBody(request, maxDurationMs = 30000) {
  const controller = new AbortController();
  const abortFromRequest = () => controller.abort(request.signal?.reason);
  if (request.signal?.aborted) abortFromRequest();
  else request.signal?.addEventListener("abort", abortFromRequest, { once: true });
  const timeoutError = new Error("request body deadline exceeded");
  timeoutError.name = "TimeoutError";
  const timeout = setTimeout(() => controller.abort(timeoutError), maxDurationMs);
  try {
    if (controller.signal.aborted) throw controller.signal.reason;
    const value = request.headers.get("content-length");
    if (value !== null && (!/^(0|[1-9][0-9]*)$/.test(value) ||
        !Number.isSafeInteger(Number(value)) || Number(value) > 1024 * 1024)) {
      await request.body?.cancel("invalid or oversized request body").catch(() => {});
      throw new Error("invalid or oversized request body");
    }
    if (!request.body) return new Uint8Array();
    const reader = request.body.getReader();
    const chunks = [];
    let length = 0;
    let complete = false;
    const cancel = () => { void reader.cancel(controller.signal.reason).catch(() => {}); };
    controller.signal.addEventListener("abort", cancel, { once: true });
    try {
      while (true) {
        if (controller.signal.aborted) throw controller.signal.reason;
        const { done, value: chunk } = await reader.read();
        if (controller.signal.aborted) throw controller.signal.reason;
        if (done) { complete = true; break; }
        if (chunk.byteLength > 1024 * 1024 - length) {
          await reader.cancel("request body too large").catch(() => {});
          throw new Error("request body too large");
        }
        chunks.push(chunk);
        length += chunk.byteLength;
      }
    } finally {
      controller.signal.removeEventListener("abort", cancel);
      if (!complete) await reader.cancel(controller.signal.reason || "request body read failed").catch(() => {});
      reader.releaseLock();
    }
    const body = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
    return body;
  } finally {
    clearTimeout(timeout);
    request.signal?.removeEventListener("abort", abortFromRequest);
  }
}

async function encodeIncomingRequest(request, url) {
  const encoder = new TextEncoder();
  const parts = [encoder.encode(request.method), encoder.encode(url.pathname + url.search)];
  parts.push(await readIncomingBody(request));
  parts.push(encoder.encode(request.headers.get("cookie") || ""));
  parts.push(encoder.encode(request.headers.get("cf-connecting-ip") || ""));
  const headers = forwardedHeaders.flatMap(name => {
    const value = request.headers.get(name);
    return value === null ? [] : [[encoder.encode(name), encoder.encode(value)]];
  });
  const headerBytes = headers.reduce((sum, [name, value]) => sum + 8 + name.length + value.length, 0);
  const total = 24 + parts.reduce((sum, part) => sum + part.length, 0) + headerBytes;
  if (!parts[0].length || parts[0].length > 16 || !parts[1].length || parts[1].length > 16 * 1024 ||
      parts[2].length > 1024 * 1024 || parts[3].length > 16 * 1024 || parts[4].length > 256 ||
      headerBytes > 64 * 1024 || total > 2 * 1024 * 1024)
    throw new Error("request metadata too large");
  const encoded = new Uint8Array(total);
  const view = new DataView(encoded.buffer);
  parts.forEach((part, index) => view.setUint32(index * 4, part.length, true));
  view.setUint32(20, headers.length, true);
  let offset = 24;
  for (const part of parts) { encoded.set(part, offset); offset += part.length; }
  for (const [name, value] of headers) {
    view.setUint32(offset, name.length, true); view.setUint32(offset + 4, value.length, true); offset += 8;
    encoded.set(name, offset); offset += name.length; encoded.set(value, offset); offset += value.length;
  }
  return encoded;
}

async function createInstance() {
  const instantiated = await WebAssembly.instantiate(await merModule, {});
  const wasm = instantiated.exports || instantiated;
  wasm.init();
  return wasm;
}

async function handleRequest(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/_mer/resolve.js" && (request.method === "GET" || request.method === "HEAD"))
      return resolverResponse(request);

    let wasm;
    try {
      // Mutable allocator/router/response state is isolated per request.
      wasm = await createInstance();
      injectEnv(wasm, env);
    } catch (_) {
      return workerResponse("WASM initialization failed", { status: 500 });
    }

    const decoder = new TextDecoder("utf-8", { fatal: true });
    let encoded;
    try {
      encoded = await encodeIncomingRequest(request, url);
    } catch (_) {
      return workerResponse("Request Too Large", { status: 413 });
    }
    const ptr = wasm.alloc(encoded.length);
    if (!ptr) return workerResponse("WASM alloc failed", { status: 500 });

    let resPtr;
    try {
      new Uint8Array(wasm.memory.buffer).set(encoded, ptr);
      resPtr = wasm.handle(ptr, encoded.length);
    } catch (_) {
      return workerResponse("Internal Server Error", { status: 500 });
    } finally {
      wasm.dealloc(ptr, encoded.length);
    }
    if (!resPtr) return workerResponse("Not Found", { status: 404 });

    try {
      const resLen = wasm.response_len();
      const decoded = decodeWorkerResponse(new Uint8Array(wasm.memory.buffer, resPtr, resLen), decoder);
      return workerResponse(decoded.body, decoded);
    } catch (_) {
      return workerResponse("Internal Server Error", { status: 500 });
    } finally {
      wasm.response_done();
    }
}

export default {
  async fetch(request, env, _ctx) {
    try {
      return finalizeWorkerResponse(request, await handleRequest(request, env));
    } catch (_) {
      return finalizeWorkerResponse(request, workerResponse("Internal Server Error", { status: 500 }));
    }
  },
};
