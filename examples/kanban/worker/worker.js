// worker.js — Cloudflare Workers handler for merjs kanban example

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
  async fetch(request, _env, _ctx) {
    const url = new URL(request.url);
    const wasm = await getInstance();
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    const input = `${request.method} ${url.pathname}`;
    const encoded = encoder.encode(input);

    const ptr = wasm.alloc(encoded.length);
    if (!ptr) return new Response("WASM alloc failed", { status: 500 });
    new Uint8Array(wasm.memory.buffer).set(encoded, ptr);

    let resPtr;
    try {
      resPtr = wasm.handle(ptr, encoded.length);
    } catch (_) {
      instance = null;
      return new Response("Internal Server Error", { status: 500 });
    }
    wasm.dealloc(ptr, encoded.length);

    if (!resPtr) return new Response("Not Found", { status: 404 });

    const resLen = wasm.response_len();
    const resBuf = new Uint8Array(wasm.memory.buffer, resPtr, resLen);

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
