// worker.js — Cloudflare Workers fetch handler for merjs.
// Static assets from public/ are served automatically by Wrangler [assets].
// This worker handles dynamic routes via the merjs WASM module.

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
  "content-security-policy": "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://static.cloudflareinsights.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self' https://api.open-meteo.com https://cloudflareinsights.com; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  "x-frame-options": "DENY",
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "cross-origin-opener-policy": "same-origin",
  "permissions-policy": "camera=(), microphone=(), geolocation=()",
};

export default {
  async fetch(request) {
    const url = new URL(request.url);

    // /api/time — return real timestamp from JS (WASM has no clock).
    if (url.pathname === "/api/time") {
      const ts = Math.floor(Date.now() / 1000);
      return new Response(
        JSON.stringify({ timestamp: ts, unit: "unix_seconds", iso: new Date(ts * 1000).toISOString() }),
        { status: 200, headers: { "content-type": "application/json", ...securityHeaders } },
      );
    }

    const wasm = await getInstance();
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

    // Patch SSR timestamp for dashboard (WASM has no clock, renders 0).
    if (url.pathname === "/dashboard" && contentType.startsWith("text/html")) {
      let html = decoder.decode(body);
      const ts = Math.floor(Date.now() / 1000);
      html = html.replace(/(id="ssr-ts"[^>]*>)\s*0\s*(<)/, `$1${ts}$2`);
      return new Response(html, {
        status,
        headers: { "content-type": contentType, ...securityHeaders },
      });
    }

    return new Response(body, {
      status,
      headers: { "content-type": contentType, ...securityHeaders },
    });
  },
};
