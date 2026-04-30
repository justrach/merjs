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
| `examples/site/fastly/` | Fastly Compute deploy target (WASI) |
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

## Request lifecycle (Fastly Compute)

```
Fastly edge
  → src/fastly.zig        WASI _start entry point
      → tryServeStatic()  check embedded static assets (public/*)
      → buildMerRequest() parse downstream request into mer.Request
      → dispatch          hash-map route lookup → page fn pointer
      → sendFastlyResponse()  write status + headers + body to downstream
```

Unlike the Workers target, Fastly Compute runs native WASI — no JS shim is required. Static assets are embedded at compile time via `@embedFile`, so serving them is a memory lookup with no I/O. Outbound HTTP fetches during SSR are routed through named backends configured in `fastly.toml`.

### Outbound fetch security

The `resolveBackend` helper in `src/fastly.zig` walks a `backend_mappings` table to translate the URL passed to `mer.fetch()` into a Fastly backend name, falling back to `default_backend` when nothing matches. With Fastly's dynamic backends feature enabled, the backend selector is independent of the URL: any URL the program hands to the host is fetched verbatim. If user input ever reaches `mer.fetch()`, that becomes a server-side request forgery primitive whose destination is fully attacker-controlled.

Before deploying this adapter to production:

- Disable dynamic backends on the Compute service.
- Declare every reachable origin as a named backend in `fastly.toml`.
- Mirror each one in `backend_mappings` as an explicit `(origin, backend)` pair so that `resolveBackend` only ever returns a backend that the service is actually permitted to talk to.

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
