# merjs Architecture

## What this repo contains

merjs mixes two things in the top level — the **framework** and its own **website/demo app**. This is intentional for now (dogfooding), but worth understanding:

| Directory | What it is |
|---|---|
| `src/` | Framework runtime — server, router, SSR engine, HTML builder |
| `cli.zig` | `mer` CLI — `init`, `dev`, `build` commands |
| `build.zig` | Build system — framework binary, WASM, Workers, desktop |
| `packages/` | Optional packages (`merjs-auth`) |
| `app/`, `api/` | **merjs website** pages (not the framework source) |
| `public/` | **merjs website** static assets |
| `wasm/` | **merjs website** client-side WASM modules |
| `worker/` | **merjs website** Cloudflare Workers deploy target |
| `examples/` | Standalone demo apps |

## Request lifecycle (native dev server)

```
HTTP request
  → src/server.zig       accept() + thread pool dispatch
  → src/router.zig       trie-based URL match → page fn pointer
  → app/<page>.zig       render(req) → Response
  → src/server.zig       wrap in layout (app/layout.zig), write HTTP response
```

## Request lifecycle (Cloudflare Workers)

```
Cloudflare edge
  → worker/worker.js     fetch() handler
      → two-phase fetch: collect_fetch_urls() dry run → JS fetches in parallel
      → wasm.handle()    full WASM render with pre-fetched data
  → HTTP Response
```

## Streaming SSR

Pages can opt into streaming by exporting `renderStream` instead of `render`:

```zig
pub fn renderStream(req: mer.Request, stream: *mer.StreamWriter) void {
    stream.write(layout.head);
    stream.flush();                          // browser receives shell immediately

    stream.placeholder("weather", "<div class='loading'>...</div>");
    const data = mer.fetch(req.allocator, .{ .url = weather_api });
    stream.resolve("weather", renderWeather(data));
}
```

The server flushes the shell (head + nav) first via chunked transfer, then streams resolved content as it arrives. No hydration, no client JS required.

## Module system

Zig has no runtime module loader. merjs uses comptime codegen:

1. `zig build codegen` scans `app/` and `api/` and writes `src/generated/routes.zig`
2. `routes.zig` is a flat dispatch table: `"/about" => app_about.render`
3. The router (`src/router.zig`) does a hash-map lookup at request time

Named module imports in `build.zig` wire each `app/*.zig` file into the binary at compile time.

## Desktop (experimental)

`zig build desktop` produces `zig-out/MerApp.app` — a native macOS app bundle that:

1. Spawns the merjs HTTP server on a random port (`std.Thread`)
2. Signals readiness via `std.Thread.ResetEvent`
3. Opens an `NSWindow` + `WKWebView` pointing at `http://127.0.0.1:<port>/`

No Electron. No npm. The entire app is a single Zig binary.

See [examples/desktop/README.md](../examples/desktop/README.md) and [examples/desktop/spike.zig](../examples/desktop/spike.zig) for the ObjC bridge research notes.

## Hot reload

`src/watcher.zig` polls `app/` every 300ms. On change it broadcasts an SSE event to `/_mer/events`. A small inline script (injected in dev mode) listens and calls `location.reload()`.

## WASM client modules

`wasm/*.zig` files compile to `wasm32-freestanding`. They export pure functions that the browser calls directly. No JS glue generated — the HTML page imports the `.wasm` with a `<script>` that calls `WebAssembly.instantiateStreaming`.

## Thread model

- `std.Thread.Pool` sized to `min(cpu_count * 2, 64)`
- Each connection gets its own arena allocator (freed on response completion)
- Static file cache is initialized once at startup, read-only after that
- Hot reload watcher runs in its own detached thread
