# merjs on Vercel Edge

Deploy merjs as a Vercel Edge Function. The Zig framework compiles to
`wasm32-freestanding` and runs on Vercel's edge network — same binary
as Cloudflare Workers.

## Setup

1. Build the WASM binary:

```bash
cd ../..
zig build worker
cp examples/site/worker/merjs.wasm examples/vercel-edge/merjs.wasm
```

2. Deploy:

```bash
cd examples/vercel-edge
vercel
```

## How it works

- `api/index.js` — Edge Function that loads `merjs.wasm` and routes requests
  through the WASM binary using the shared-memory protocol
- All requests are rewritten to `/api` via `vercel.json`
- The WASM binary contains the full SSR router, page handlers, and API routes

## Limitations

- Static assets must be served separately (Vercel static hosting or CDN)
- No hot reload in edge mode
- WASM memory limit applies (default ~128MB on Vercel Edge)
