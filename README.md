<p align="center">
  <img src="merlion.png" alt="merjs" width="200" />
</p>

<p align="center">
  <a href="https://github.com/justrach/merjs/releases/latest"><img src="https://img.shields.io/github/v/release/justrach/merjs?style=flat-square&label=version" alt="Latest Release" /></a>
  <a href="https://github.com/justrach/merjs/blob/main/LICENSE"><img src="https://img.shields.io/github/license/justrach/merjs?style=flat-square" alt="License" /></a>
  <img src="https://img.shields.io/badge/zig-0.15.1-f7a41d?style=flat-square" alt="Zig 0.15.1" />
  <img src="https://img.shields.io/badge/node__modules-0_files-brightgreen?style=flat-square" alt="Zero node_modules" />
  <img src="https://img.shields.io/badge/status-experimental-orange?style=flat-square" alt="Experimental" />
</p>

<h1 align="center">merjs</h1>

<h3 align="center">Next.js-style web framework. Written in Zig. Zero Node.js.</h3>

<p align="center">
  File-based routing · SSR · Type-safe APIs · Hot reload · WASM client logic · Cloudflare Workers
</p>

<p align="center">
  <a href="#-quick-start">Quick Start</a> ·
  <a href="#-features">Features</a> ·
  <a href="#-demo">Demo</a> ·
  <a href="#-how-it-works">How It Works</a> ·
  <a href="#-deploy-to-cloudflare-workers">Deploy</a>
</p>

---

## The Problem

Every Node.js web framework drags in 300 MB of `node_modules`, a 1–3s cold start, and a JavaScript runtime you never asked for. The reason JS won the server was simple: it was already in the browser.

**WebAssembly changes that.** Zig compiles to `wasm32-freestanding` with a single flag. You can write client-side logic in Zig, compile it to `.wasm`, and ship it directly to the browser — no transpiler, no bundler, no runtime.

```
app/page.zig    →  native binary  (SSR, Zig HTTP server, < 5ms cold start)
wasm/logic.zig  →  logic.wasm     (client interactivity, runs in browser)
```

merjs is exploring whether you can get the full Next.js developer experience — file-based routing, SSR, type-safe APIs, hot reload — without any of its runtime weight.

---

## ⚡ Quick Start

**Requirements:** [Zig 0.15.1](https://ziglang.org/download/)

```bash
git clone https://github.com/justrach/merjs.git
cd merjs

# Copy env vars (needed for AI/data routes)
cp .env.example .env

zig build codegen   # scan app/ and api/, generate routes
zig build css       # compile Tailwind v4 (no npm)
zig build wasm      # compile wasm/ → public/*.wasm
zig build serve     # dev server on :3000 with hot reload
```

Visit `http://localhost:3000`.

---

## 🚀 Features

### File-based routing — like Next.js

```
app/index.zig       →  /
app/dashboard.zig   →  /dashboard
app/blog/post.zig   →  /blog/post
api/users.zig       →  /api/users
```

Drop a `.zig` file, export `render()`, get a route. The codegen tool writes `src/generated/routes.zig` — a static dispatch table with zero runtime cost.

### Type-safe APIs via [dhi](https://github.com/justrach/dhi)

```zig
const mer = @import("mer");

const UserModel = mer.dhi.Model("User", .{
    .name  = mer.dhi.Str(.{ .min_length = 1, .max_length = 100 }),
    .email = mer.dhi.EmailStr,
    .age   = mer.dhi.Int(i32, .{ .gt = 0, .le = 150 }),
});

pub fn render(req: mer.Request) mer.Response {
    const user = try UserModel.parse(req.body);
    return mer.typedJson(req.allocator, UserResponse{ .name = user.name });
}
```

Constraints are checked comptime. Validation runs at parse time. No hand-rolled JSON.

### HTML builder — comptime, type-safe

```zig
const h = mer.h;

fn page() h.Node {
    return h.div(.{ .class = "container" }, .{
        h.h1(.{}, "Hello from Zig"),
        h.p(.{}, "No virtual DOM. No hydration. Just HTML."),
        h.a(.{ .href = "/about" }, "Learn more"),
    });
}

comptime { mer.lint.check(page_node); } // catches missing alts, empty titles, etc.
```

### WASM client logic — no bundler

```zig
// wasm/counter.zig
export fn increment(n: i32) i32 { return n + 1; }
```

```bash
zig build wasm   # → public/counter.wasm
```

Load in the browser with `WebAssembly.instantiateStreaming`. That's it.

### Hot reload — no daemon

The watcher polls `app/` every 300ms, detects mtime changes, and fires an SSE event. Browser reloads. No webpack, no esbuild, no separate process.

### Tailwind v4 — zero Node.js

The standalone Tailwind CLI lives at `tools/tailwindcss`. `zig build css` runs it. No `npm install`.

---

## 📊 vs Next.js

|                        | **merjs**                  | **Next.js**                    |
| ---------------------- | -------------------------- | ------------------------------ |
| Runtime                | None (native binary)       | Node.js ≥ 18                   |
| `node_modules`         | **0 files**                | ~300 MB / ~85k files           |
| Cold start             | **< 5 ms**                 | ~1–3 s                         |
| Server binary size     | **~2 MB**                  | N/A (interpreted)              |
| Client interactivity   | WASM (Zig → `wasm32`)      | JavaScript bundle              |
| CSS                    | Tailwind v4 standalone CLI | Tailwind via npm               |
| Type safety            | Comptime (Zig + dhi)       | TypeScript (runtime-erased)    |
| Hot reload             | SSE file watcher (300 ms)  | Webpack/Turbopack HMR          |
<!-- BENCH:START -->
| Requests/sec (wrk)    | **2433.22 req/s**     | **2060.23 req/s**          |
| Avg latency           | **40.99ms 2.96ms**           | **77.21ms 178.37ms**                |
| RAM usage (under load) | **465.3 MB**        | **73.9 MB**             |
| Build time             | **3194 ms**                | **37795 ms**                   |
<!-- BENCH:END -->

> Benchmark rows are auto-updated by CI on each push to `main`. Next.js is a mature, production-grade framework — merjs is an early experiment.

---

## 🌐 Demo

Live demo: **[sgdata.merlionjs.com](https://sgdata.merlionjs.com)** — a real-time Singapore government data dashboard built entirely with merjs. SSR pages, JSON APIs, WASM, and a RAG-powered AI chat for Singapore's FY2026 Budget Statement. Deployed on Cloudflare Workers. Zero Node.js.

---

## ☁️ Deploy to Cloudflare Workers

```bash
# Set secrets
cd worker
wrangler secret put OPENAI_API_KEY

# Build + deploy
cd ..
zig build worker
cd worker
wrangler deploy
```

The `worker/worker.js` shim handles the fetch event and passes requests to the WASM binary. Routes that need outbound network calls (e.g. AI APIs) can be handled directly in the shim — see `worker/worker.js` for the pattern.

---

## ⚙️ How It Works

```
zig build codegen
  └── scans app/ + api/
  └── writes src/generated/routes.zig  (static dispatch table)

zig build serve
  └── compiles server binary
  └── binds :3000
  └── serves static files from public/
  └── dispatches requests → generated route handlers
  └── SSE watcher on app/ for hot reload

zig build worker
  └── compiles to wasm32-freestanding
  └── worker/worker.js wraps WASM in a CF Workers fetch handler
```

**Thread model:** `std.Thread.Pool` with 128 workers, kernel backlog 512.

**Layout convention:** Pages returning HTML fragments are auto-wrapped by `app/layout.zig`. Pages returning full documents (starting with `<!`) bypass it.

---

## 📁 Structure

```
merjs/
├── app/                    # file-based page routes (SSR HTML)
├── api/                    # file-based API routes (JSON)
├── wasm/                   # client-side WASM modules (Zig → wasm32)
├── worker/
│   ├── worker.js           # Cloudflare Workers fetch handler
│   └── wrangler.toml
├── src/
│   ├── mer.zig             # public API: Request, Response, h, lint, dhi
│   ├── server.zig          # HTTP server
│   ├── html.zig            # comptime HTML builder DSL
│   ├── html_lint.zig       # comptime HTML linter
│   ├── watcher.zig         # file watcher + SSE hot reload
│   ├── prerender.zig       # SSG: render pages at build time → dist/
│   └── generated/
│       └── routes.zig      # codegen output — do not edit
├── tools/
│   ├── codegen.zig
│   └── tailwindcss         # Tailwind v4 standalone CLI
└── public/                 # static assets
```

---

## 🤝 Contributing

Open an issue before submitting a large PR so we can align on the approach.

```bash
git clone https://github.com/justrach/merjs.git
cd merjs
zig build test   # make sure tests pass before and after your change
```

---

## Credits

- **[dhi](https://github.com/justrach/dhi)** — Pydantic-style validation for Zig
- **[Tailwind CSS v4](https://tailwindcss.com)** — standalone CLI, no npm
- **Zig 0.15.1** — the whole stack

## License

MIT
