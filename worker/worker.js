// worker.js — Cloudflare Workers fetch handler for merjs (merlionjs.com).

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

const securityHeaders = {
  "strict-transport-security": "max-age=63072000; includeSubDomains; preload",
  "content-security-policy": "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://unpkg.com https://static.cloudflareinsights.com https://fonts.googleapis.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://unpkg.com; font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self' https://api.open-meteo.com https://cloudflareinsights.com; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  "x-frame-options": "DENY",
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "cross-origin-opener-policy": "same-origin",
  "permissions-policy": "camera=(), microphone=(), geolocation=()",
};

export default {
  async fetch(request, _env, _ctx) {
    const url = new URL(request.url);

    // /api/time handled in JS — wasm32 has no clock
    if (url.pathname === "/api/time") {
      const ts = Math.floor(Date.now() / 1000);
      return new Response(
        JSON.stringify({ timestamp: ts, unit: "unix_seconds", iso: new Date().toISOString() }),
        { headers: { "content-type": "application/json", ...securityHeaders } }
      );
    }

    const wasm = await getInstance();
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    const input = `${request.method} ${url.pathname}`;
    const encoded = encoder.encode(input);

    const ptr = wasm.alloc(encoded.length);
    if (!ptr) return new Response("WASM alloc failed", { status: 500 });

    const mem = new Uint8Array(wasm.memory.buffer);
    mem.set(encoded, ptr);

    const resPtr = wasm.handle(ptr, encoded.length);
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
      headers: { "content-type": contentType, ...securityHeaders },
    });
  },
};
