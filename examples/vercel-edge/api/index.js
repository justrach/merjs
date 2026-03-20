// Vercel Edge Function — merjs WASM adapter
// Loads the compiled merjs.wasm and routes all requests through it.

import wasm from '../merjs.wasm?module';

let instance = null;

function getInstance() {
  if (instance) return instance;
  const inst = new WebAssembly.Instance(wasm, { env: {} });
  inst.exports.init();
  instance = inst;
  return inst;
}

function decodeResponse(exports, ptr, len) {
  const mem = new Uint8Array(exports.memory.buffer);
  const status = mem[ptr] | (mem[ptr + 1] << 8);
  const ctLen = mem[ptr + 2] | (mem[ptr + 3] << 8);
  const ct = new TextDecoder().decode(mem.slice(ptr + 4, ptr + 4 + ctLen));
  const body = mem.slice(ptr + 4 + ctLen, ptr + len);
  return { status, ct, body };
}

export const config = { runtime: 'edge' };

export default async function handler(req) {
  const exports = getInstance().exports;
  const url = new URL(req.url);
  const input = `${req.method} ${url.pathname}`;
  const encoded = new TextEncoder().encode(input);

  // Allocate WASM memory and write the request.
  const ptr = exports.alloc(encoded.length);
  if (!ptr) return new Response('WASM alloc failed', { status: 500 });
  const mem = new Uint8Array(exports.memory.buffer);
  mem.set(encoded, ptr);

  // Call handle.
  const respPtr = exports.handle(ptr, encoded.length);
  exports.dealloc(ptr, encoded.length);

  if (!respPtr) {
    return new Response('Not Found', { status: 404 });
  }

  const respLen = exports.response_len();
  const { status, ct, body } = decodeResponse(exports, respPtr, respLen);

  return new Response(body, {
    status,
    headers: { 'content-type': ct },
  });
}
