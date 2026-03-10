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

// Track whether env bindings have been injected into the WASM module.
let envInjected = false;

function injectEnv(wasm, env) {
  if (envInjected || !wasm.__mer_set_env) return;
  envInjected = true;
  const enc = new TextEncoder();
  for (const [key, val] of Object.entries(env)) {
    if (typeof val !== "string") continue;
    const kb = enc.encode(key);
    const vb = enc.encode(val);
    const kp = wasm.alloc(kb.length);
    const vp = wasm.alloc(vb.length);
    if (!kp || !vp) continue;
    const mem = new Uint8Array(wasm.memory.buffer);
    mem.set(kb, kp);
    mem.set(vb, vp);
    wasm.__mer_set_env(kp, kb.length, vp, vb.length);
    // Originals freed here — Zig already copied into its string_buf.
    wasm.dealloc(kp, kb.length);
    wasm.dealloc(vp, vb.length);
  }
}

export default {
  async fetch(request, env, _ctx) {
    const url = new URL(request.url);

    const wasm = await getInstance();

    // Inject Cloudflare secret bindings into the Zig env table once per cold start.
    injectEnv(wasm, env);

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
      headers: { "content-type": contentType, ...securityHeaders },
    });
  },
};
