# merjs

<p align="center">
  <img src="merlion.png" alt="merjs logo" width="200" />
</p>

<p align="center">
  <em>A Zig-native web framework. No Node. No npm. Just WASM.</em>
</p>

<p align="center">
  <img alt="Status: Experimental" src="https://img.shields.io/badge/status-experimental-orange" />
  <img alt="Zig 0.15.1" src="https://img.shields.io/badge/zig-0.15.1-blue" />
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green" />
</p>

---

## merjs vs Next.js — at a glance

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
| Build toolchain        | `zig build` (one binary)   | Node + Webpack/Turbo + Babel   |
<!-- BENCH:START -->
| Requests/sec (wrk)    | **2442.67 req/s**     | **1861.20 req/s**          |
| Avg latency           | **40.80ms 2.74ms**           | **76.53ms 166.50ms**                |
| RAM usage (under load) | **469.6 MB**        | **72.3 MB**             |
| Build time             | **4127 ms**                | **51880 ms**                   |
<!-- BENCH:END -->

> **Note:** These are approximate comparisons. Benchmark rows are auto-updated by CI on each push to main. Next.js is a mature, production-grade framework — merjs is an early experiment exploring whether we can get the same DX without the runtime weight.

---

## Demo

<!-- TODO: Replace with a GIF/video of the counter page + hot reload in action -->
<p align="center">
  <em>🎬 Demo GIF coming soon — counter page with WASM interactivity + hot reload</em>
</p>

---

## Getting started

**Requirements:** Zig 0.15.1

```bash
# 1. Generate routes (scans app/ and api/)
zig build codegen

# 2. Build Tailwind CSS
zig build css

# 3. Build the WASM counter
zig build wasm

# 4. Start the dev server (hot reload on :3000)
zig build serve
```

Visit `http://localhost:3000`.

---

## Adding a page

Create `app/hello.zig`:

```zig
const mer = @import("mer");

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html("<h1>Hello from Zig</h1>");
}
```

Run `zig build codegen` — the route `/hello` is live on next restart.

## Adding an API route

Create `api/ping.zig`:

```zig
const mer = @import("mer");

const Pong = struct { status: []const u8, latency_ms: u32 };

pub fn render(req: mer.Request) mer.Response {
    return mer.typedJson(req.allocator, Pong{ .status = "ok", .latency_ms = 0 });
}
```

`GET /api/ping` returns `{"status":"ok","latency_ms":0}`.

## Adding client-side logic (WASM)

Create `wasm/yourmodule.zig`, export functions with `export`, compile with `zig build wasm`, serve the `.wasm` from `public/`. Load it in a page with a `WebAssembly.instantiateStreaming` call. The browser runs it natively — no bundler involved.

---

## Why

The honest answer: **WASM can do most of what Node.js does.**

Most of what Node.js actually *does* in a web framework is: parse HTTP, route requests, render HTML, serve static files, and run client-side logic. The last point is the interesting one — for decades it meant JavaScript had to be everywhere, server *and* client, which made Node.js the natural choice.

**WebAssembly changes the equation.** Zig compiles to `wasm32-freestanding` with a single flag. You can write client-side logic — counters, state machines, validation — in Zig, compile it to `.wasm`, and ship it directly to the browser. No transpiler. No bundler. The browser runs it natively.

That means the last moat defending Node.js — *"we need JS on the server because JS runs in the browser"* — no longer holds. You can write your entire stack in a systems language, compile the server to a native binary and the client to WASM, and skip the runtime entirely.

---

## Philosophy

**One language, two targets.**

```
app/counter.zig  →  native binary (SSR, served by Zig HTTP server)
wasm/counter.zig   →  counter.wasm  (interactive logic, runs in browser)
```

No transpilation step. No hydration framework. No virtual DOM. The server renders HTML. The browser runs WASM for anything interactive. The handoff is a `<script>` tag and a `.wasm` fetch — about 20 lines of JS total.

**File-based routing, like Next.js.**

```
app/index.zig      →  /
app/dashboard.zig  →  /dashboard
api/time.zig         →  /api/time
api/users.zig        →  /api/users
```

Drop a `.zig` file, export a `render()` function, get a route. The codegen tool scans those directories at build time and writes `src/generated/routes.zig` — a static dispatch table with zero runtime cost.

**Type-safe by default, via [dhi](https://github.com/justrach/dhi).**

API responses are typed Zig structs serialized through `std.json`. Request bodies are validated at parse time using dhi's Pydantic-style model system — comptime constraint checking, zero runtime overhead for the schema itself.

```zig
const UserModel = mer.dhi.Model("User", .{
    .name  = mer.dhi.Str(.{ .min_length = 1, .max_length = 100 }),
    .email = mer.dhi.EmailStr,
    .age   = mer.dhi.Int(i32, .{ .gt = 0, .le = 150 }),
    .score = mer.dhi.Float(f64, .{ .ge = 0.0, .le = 100.0 }),
});

// Validation runs at parse time. Constraints are checked comptime.
const user = try UserModel.parse(.{ .name = "Alice", .email = "alice@example.com", ... });

// Type-safe JSON serialization — no hand-rolled strings.
return mer.typedJson(req.allocator, UserResponse{ .name = user.name, ... });
```

**Hot reload without a daemon.**

The watcher polls `app/` every 300ms, detects mtime changes, and broadcasts an SSE event to connected browsers. The browser reloads. No webpack, no esbuild, no separate watch process — just polling in a Zig thread.

**Tailwind v4, zero Node.js.**

The standalone Tailwind CLI binary is downloaded once to `tools/tailwindcss`. `zig build css` runs it against `public/input.css` and writes `public/styles.css`. No `npm install`.

---

## Structure

```
merjs/
├── build.zig           # build system — scans app/ and api/, wires modules
├── build.zig.zon       # package manifest
├── src/
│   ├── mer.zig         # public API: Request, Response, typedJson, dhi
│   ├── server.zig      # HTTP server (Zig 0.15 std.http.Server)
│   ├── router.zig      # static dispatch table
│   ├── ssr.zig         # wires router to generated routes
│   ├── watcher.zig     # file watcher + SSE broadcaster
│   ├── static.zig      # static file server with MIME detection
│   ├── request.zig     # Request type
│   ├── response.zig    # Response type, ContentType enum
│   ├── dhi.zig         # re-exports from dhi validation library
│   ├── dhi/            # dhi source (model.zig, validator.zig, ...)
│   └── generated/
│       └── routes.zig  # codegen output — do not edit by hand
├── app/              # file-based page routes
│   ├── index.zig       # /
│   ├── counter.zig     # /counter  (WASM-powered interactive counter)
│   ├── dashboard.zig   # /dashboard (SSR + live API polling)
│   └── users.zig       # /users    (dhi-validated SSR + live /api/users)
├── api/                # file-based API routes (return JSON)
│   ├── hello.zig       # GET /api/hello
│   ├── time.zig        # GET /api/time
│   └── users.zig       # GET /api/users (dhi-validated typed response)
├── wasm/
│   └── counter.zig     # Zig WASM module — runs in browser
├── public/
│   ├── input.css       # Tailwind source
│   ├── styles.css      # generated by `zig build css`
│   └── counter-shim.js # 20-line JS bridge for counter.wasm
└── tools/
    ├── codegen.zig     # scans app/ + api/, writes routes.zig
    └── tailwindcss     # Tailwind v4 standalone CLI binary
```

---

## The bet

Node.js won the server in the 2010s because JavaScript was already in the browser. That moat was real.

WASM narrows it considerably. Any language that targets WASM can now ship logic to the browser. Zig is a particularly good fit — tiny binaries, no GC pauses, deterministic performance.

The question merjs is exploring: *can a Zig-native web framework — with file-based routing, SSR, type-safe APIs, hot reload, and WASM for client interactivity — match the developer experience of Next.js without any of its runtime weight?*

We think yes. This is early proof.

---

## Credits

- **[dhi](https://github.com/justrach/dhi)** — Pydantic-style validation for Zig, used for type-safe API models
- **[Tailwind CSS v4](https://tailwindcss.com)** — standalone CLI, no npm required
- **Zig 0.15.1** — the whole stack

## License

MIT
