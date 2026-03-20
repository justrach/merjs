# AGENTS.md — for coding agents working on merjs

## What is this?

merjs is a Next.js-style web framework written in Zig. Zero Node.js.
File-based routing, SSR, type-safe APIs, WASM client logic, Cloudflare Workers deploy.

## Project structure

```
src/              Framework runtime (the library)
  mer.zig         Public API surface — thin re-exports
  server.zig      HTTP server, dev endpoints, error overlay
  router.zig      Route matching + dispatch
  session.zig     HMAC session sign/verify
  fetch.zig       SSR HTTP client (single + parallel)
  html.zig        Comptime HTML builder DSL
  static.zig      Static file serving from public/
  watcher.zig     File watcher + SSE hot reload
  main.zig        Server entry point (not app-specific)

build/            Build system modules
  helpers.zig     addDirModules, addWasmExe
  examples.zig    Example project targets
  tools.zig       Tailwind auto-download
  packages.zig    Package test wiring

examples/site/    Demo app (merlionjs.com) — NOT framework code
  app/            Page routes (*.zig → SSR HTML)
  api/            API routes (*.zig → JSON)
  wasm/           Client WASM modules
  public/         Static assets
  worker/         Cloudflare Workers config

cli.zig           `mer` CLI (init, dev, build, add, update)
build.zig         Top-level build — delegates to build/
```

## Quick commands

```bash
# Build & run the demo site
zig build codegen       # scan app/ + api/, generate route table
zig build serve         # dev server on :3000 with hot reload

# With verbose request logging
zig build serve -- --verbose

# Build CLI
zig build cli

# Build WASM modules
zig build wasm

# Build for Cloudflare Workers
zig build worker

# Run tests
zig build test

# Full production build
zig build prod
```

## Debugging

### Dev endpoints (only active in dev mode)

- `http://localhost:3000/_mer/debug` — shows all routes, framework version, Zig version, route counts
- `http://localhost:3000/_mer/debug?format=json` — same as above, machine-readable JSON
- `http://localhost:3000/_mer/events` — SSE hot reload stream

### Verbose mode

Run with `--verbose` to log every request with timing:
```
info(server): GET / 266µs
info(server): GET /api/hello 42µs
info(server): GET /counter 891µs
```

### Error overlay

When a route handler errors in dev mode, the browser shows a styled error page with:
- The error name (e.g. `OutOfMemory`)
- The request path
- Debugging tips
- Framework version

In production (`--no-dev`), errors log to stderr and return a clean 500.

### Common issues

| Symptom | Fix |
|---------|-----|
| `zig build` fails with "missing fingerprint" | Run `zig build` once, copy the suggested value into `build.zig.zon` |
| `codegen: wrote 0 routes` | Make sure `app/` and `api/` dirs exist with `.zig` files |
| Port 3000 in use | `zig build serve -- --port 8080` |
| Server unreachable in Docker | Use `--host 0.0.0.0` |
| CSS not working | Run `zig build css` (auto-downloads Tailwind CLI) or `mer add css` |
| WASM not loading | Run `zig build wasm` to compile `.wasm` files to `public/` |

### Telemetry (Sentry + Datadog)

Both are opt-in via env vars — zero overhead when not configured.

**Sentry** (error tracking):
```bash
SENTRY_DSN=https://your-key@sentry.io/your-project-id
```
Route handler errors are automatically reported with error name, request path, and framework version.

**Datadog** (request metrics via DogStatsD):
```bash
DD_AGENT_HOST=127.0.0.1
DD_DOGSTATSD_PORT=8125    # default
```
Sends per-request timing (`merjs.request.duration`) and error counts (`merjs.request.error`) with path/method/status tags.
### Docker

```bash
docker build -t merjs .
docker run -p 3000:3000 merjs
```

### Adding routes

1. Create `app/mypage.zig` (page) or `api/myendpoint.zig` (API)
2. Export `pub fn render(req: mer.Request) mer.Response`
3. Run `zig build codegen` to regenerate the route table
4. `zig build serve` picks it up

### Key conventions

- Pages return HTML: `return mer.html("<h1>Hello</h1>");`
- APIs return JSON: `return mer.json("{\"ok\":true}");`
- Use `mer.h.div(...)` for comptime HTML builder
- Use `mer.dhi.Model(...)` for request validation
- Use `pub const meta: mer.Meta = .{ .title = "..." }` for SEO
- Layouts: export from `app/layout.zig`, pages auto-wrap
- Dynamic routes: `app/users/[id].zig` → `/users/:id`
