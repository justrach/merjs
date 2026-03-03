// worker.js — Cloudflare Workers fetch handler for merjs.
// Loads merjs.wasm, calls handle() for each request, returns the response.

import merWasm from "./merjs.wasm";

let instance = null;

async function getInstance() {
  if (instance) return instance;
  const mod = await WebAssembly.instantiate(merWasm, {
    env: { memory: new WebAssembly.Memory({ initial: 256 }) },
  });
  instance = mod.exports || mod;
  instance.init();
  return instance;
}

export default {
  async fetch(request) {
    const wasm = await getInstance();
    const url = new URL(request.url);
    const input = `${request.method} ${url.pathname}`;
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    const encoded = encoder.encode(input);

    // Allocate memory in WASM and write the request.
    const ptr = wasm.alloc(encoded.length);
    if (!ptr) return new Response("WASM alloc failed", { status: 500 });

    const mem = new Uint8Array(wasm.memory.buffer);
    mem.set(encoded, ptr);

    // Call handle and read the response.
    const resPtr = wasm.handle(ptr, encoded.length);
    wasm.dealloc(ptr, encoded.length);

    if (!resPtr) return new Response("Not Found", { status: 404 });

    const resLen = wasm.response_len();
    const resBuf = new Uint8Array(wasm.memory.buffer, resPtr, resLen);

    // Decode: u16 status LE | u16 ct_len LE | content-type | body
    const status = resBuf[0] | (resBuf[1] << 8);
    const ctLen = resBuf[2] | (resBuf[3] << 8);
    const contentType = decoder.decode(resBuf.slice(4, 4 + ctLen));
    const body = resBuf.slice(4 + ctLen);

    return new Response(body, {
      status,
      headers: { "content-type": contentType },
    });
  },
};
