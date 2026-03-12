---
name: merjs
description: Work with the merjs Zig web framework. Use when creating pages, API routes, WASM modules, or modifying the merjs build system. Provides conventions for file-based routing, SSR, dynamic routes, type-safe APIs via dhi, sessions, and Cloudflare Workers deployment.
argument-hint: "[page|api|wasm] <name> - what to create"
user-invocable: true
allowed-tools:
  - Read
  - Edit
  - Write
  - Bash
  - Glob
  - Grep
---

# merjs — Zig Web Framework

merjs is a Next.js-style web framework written entirely in Zig. Zero Node.js, zero `node_modules`.

## Architecture

```
app/          → file-based page routes (SSR HTML)
api/          → file-based API routes (return JSON)
wasm/         → client-side WASM modules (Zig → wasm32)
src/          → framework internals
  mer.zig     → public API (Request, Response, typedJson, dhi, h, lint)
  html.zig    → HTML builder DSL (mer.h.*)
  html_lint.zig → comptime HTML linter (mer.lint.*)
  server.zig  → HTTP server (std.Thread.Pool, 128 workers)
  router.zig  → static dispatch table + dynamic segment matching
  ssr.zig     → wires router to generated routes
  prerender.zig → SSG: renders pages at build time → dist/
  watcher.zig → file watcher + SSE hot reload
  static.zig  → static file serving with MIME detection
  worker.zig  → Cloudflare Workers WASM entry point
  dhi.zig     → re-exports from dhi validation package
  generated/routes.zig → codegen output (DO NOT EDIT)
worker/       → Cloudflare Workers deployment
  worker.js   → JS fetch handler shim
  wrangler.toml → Wrangler config
public/       → static assets served at /
examples/     → example apps (not built by default)
tools/        → build tooling
  codegen.zig → scans app/ + api/, writes routes.zig
```

## Request Object

Every handler receives `req: mer.Request`. Fields available:

```zig
req.allocator   // arena allocator — use for all dynamic allocations
req.path        // []const u8  — e.g. "/blog/hello-world"
req.method      // []const u8  — "GET", "POST", etc.
req.params      // mer.Params  — dynamic route captures (see Dynamic Routes)
req.headers     // std.http.Server.Request.Headers
```

### Reading params (dynamic routes)

```zig
const slug = req.params.get("slug") orelse "unknown";
```

`mer.Params` is a simple key-value list populated by the router for `[bracket]` segments.

## Response Helpers

All helpers return `mer.Response`:

```zig
mer.html(body: []const u8)                          // 200 text/html
mer.render(allocator, node: h.Node)                 // 200 text/html (from builder)
mer.typedJson(allocator, value: anytype)            // 200 application/json
mer.redirect(location: []const u8)                 // 302
mer.notFound()                                      // 404
mer.internalError(msg: []const u8)                 // 500
```

For raw JSON strings:
```zig
return .{ .status = 200, .body = json_str, .content_type = "application/json" };
```

## File-Based Routing

| File | Route |
|------|-------|
| `app/index.zig` | `/` |
| `app/about.zig` | `/about` |
| `app/blog/post.zig` | `/blog/post` |
| `app/blog/[slug].zig` | `/blog/:slug` |
| `api/users.zig` | `/api/users` |
| `api/users/[id].zig` | `/api/users/:id` |
| `app/layout.zig` | wraps all pages (framework primitive) |
| `app/404.zig` | custom 404 (framework primitive) |

**After adding or removing any file in `app/` or `api/`, always run:**
```bash
zig build codegen
```

## Dynamic Route Segments

Create a file named `[param].zig` in any directory:

```
app/blog/[slug].zig      →  /blog/:slug
api/users/[id].zig       →  /api/users/:id
app/shop/[cat]/[item].zig →  /shop/:cat/:item
```

Access captured values via `req.params.get("param")`:

```zig
const mer = @import("mer");

pub fn render(req: mer.Request) mer.Response {
    const slug = req.params.get("slug") orelse return mer.notFound();
    const body = std.fmt.allocPrint(req.allocator, "<h1>{s}</h1>", .{slug})
        catch return mer.internalError("alloc failed");
    return mer.html(body);
}
```

## Creating a Page (HTML Builder — preferred for static content)

Use the `mer.h` DSL to build pages with type-safe comptime elements:

```zig
const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "My Page",
    .description = "A great page.",
    .extra_head = "<style>" ++ my_css ++ "</style>",
};

const page_node = page();
comptime { mer.lint.check(page_node); }

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn page() h.Node {
    return h.div(.{ .class = "container" }, .{
        h.h1(.{}, "Hello, world!"),
        h.p(.{}, "Built with Zig."),
        h.a(.{ .href = "/about" }, "Learn more"),
    });
}

const my_css = \\.container { max-width: 800px; margin: 0 auto; }
;
```

### HTML Builder conventions
- **Comptime only** — the builder creates static node trees at compile time. Never call builder functions at runtime (dangling pointers). For dynamic data, use raw HTML strings with `allocPrint`.
- Node tree must be a file-level `const`: `const page_node = page();`
- Each element takes `(Props, children)` where children can be:
  - A string: `h.h1(.{}, "Hello")` — auto-wrapped as text node
  - A tuple: `h.div(.{}, .{ h.p(.{}, "A"), h.p(.{}, "B") })`
  - A node slice: `h.div(.{}, &[_]h.Node{...})`
- Use `h.raw("...")` for HTML entities (`&middot;`, `&mdash;`) or inline HTML
- Use `h.text("...")` for escaped text
- Props struct fields: `.class`, `.id`, `.style`, `.href`, `.src`, `.alt`, `.name`, `.content`, `.property`, `.rel`, `.@"type"`, `.charset`, `.lang`, `.action`, `.method`, `.value`, `.placeholder`, `.target`, `.extra` (for arbitrary attrs)
- Self-closing tags (meta, img, input, br, hr, link) handled automatically
- `h.document(head, body)` produces `<!DOCTYPE html><html>...</html>`
- `h.documentLang("en", head, body)` for pages with lang attribute
- Head helpers: `h.charset("UTF-8")`, `h.viewport("...")`, `h.title("...")`, `h.description("...")`, `h.og("og:title", "...")`, `h.style("css")`, `h.script(.{}, "js")`, `h.scriptSrc(.{ .src = "url" })`
- `mer.render(allocator, node)` renders a node tree to an HTML Response

### HTML Linter (`mer.lint`)
- `mer.lint.check(node)` — comptime walk that `@compileError`s on violations
- `mer.lint.checkOpt(node, false)` — disable checks when needed
- Rules: `<a>` needs href, `<img>` needs alt, `<meta>` needs content, `<title>` can't be empty, `<button>`/`<input>` need type, `<form>` needs action, no nested `<a>`, no block elements in `<p>`

## Creating a Page (Raw HTML — for dynamic content)

For pages with runtime-dynamic data (e.g., API calls, timestamps, database results), use raw HTML strings:

```zig
const mer = @import("mer");
const std = @import("std");

pub fn render(req: mer.Request) mer.Response {
    const ts = std.time.timestamp();
    const body = std.fmt.allocPrint(req.allocator,
        \\<div class="card">
        \\  <h1>Live data</h1>
        \\  <p>Rendered at: {d}</p>
        \\</div>
    , .{ts}) catch return mer.internalError("alloc failed");
    return mer.html(body);
}
```

For large pages, split static sections into file-level string constants:

```zig
const html_top =
    \\<section>
    \\  <h1>Result for:
;
const html_bottom =
    \\  </h1>
    \\</section>
;

pub fn render(req: mer.Request) mer.Response {
    const slug = req.params.get("q") orelse "";
    const body = std.fmt.allocPrint(req.allocator, "{s} {s}{s}", .{ html_top, slug, html_bottom })
        catch return mer.internalError("alloc");
    return mer.html(body);
}
```

## SEO / Meta Tags (Framework Primitive)

Pages can export `pub const meta: mer.Meta` to get automatic SEO tags injected by the layout:

```zig
pub const meta: mer.Meta = .{
    .title = "Weather",
    .description = "Live weather dashboard.",
    .og_title = "merjs Weather — Live Forecasts",
    .og_description = "Real-time weather from a Zig web framework.",
    .og_image = "https://example.com/og-weather.png",
    .og_type = "website",
    .twitter_card = "summary_large_image",
    .twitter_site = "@merjs",
    .canonical = "https://example.com/weather",
    .robots = "index, follow",
    .extra_head = "<style>.custom { color: red; }</style>",
};
```

All fields are optional. Use `extra_head` for page-specific CSS or scripts.

## Layout & 404 (Framework Primitives)

These files are auto-detected — no manual wiring needed:

| File | Purpose |
|------|---------|
| `app/layout.zig` | Wraps all HTML page responses with shared head/nav/footer + SEO tags |
| `app/404.zig` | Custom 404 error page for unmatched routes |

**Layout convention**: Pages returning content fragments (no `<!DOCTYPE>`) are auto-wrapped by `layout.zig`. Pages returning full HTML documents (starting with `<!`) bypass layout.

### Design System

Use these CSS variables (defined in layout/global CSS) for consistency:

```css
--bg        /* page background */
--bg2       /* card/surface background */
--bg3       /* subtle surface */
--text       /* primary text */
--muted      /* secondary text */
--border     /* borders/dividers */
--red        /* accent/error color */
```

Fonts: **DM Serif Display** (headings) + **DM Sans** (body). Both loaded from CDN via layout.

## Creating an API Route

1. Create `api/<name>.zig`
2. Return JSON using `mer.typedJson`:

```zig
const mer = @import("mer");

const MyResponse = struct {
    status: []const u8,
    count: u32,
};

pub fn render(req: mer.Request) mer.Response {
    return mer.typedJson(req.allocator, MyResponse{ .status = "ok", .count = 42 });
}
```

3. Run `zig build codegen`
4. Route is available at `/api/name`

### Handling HTTP methods

```zig
pub fn render(req: mer.Request) mer.Response {
    if (std.mem.eql(u8, req.method, "POST")) {
        // handle POST
    }
    return mer.typedJson(req.allocator, .{ .method = req.method });
}
```

## Using dhi Validation

dhi provides Pydantic-style comptime validation for API input:

```zig
const UserModel = mer.dhi.Model("User", .{
    .name  = mer.dhi.Str(.{ .min_length = 1, .max_length = 100 }),
    .email = mer.dhi.EmailStr,
    .age   = mer.dhi.Int(i32, .{ .gt = 0, .le = 150 }),
    .score = mer.dhi.Float(f64, .{ .ge = 0.0, .le = 100.0 }),
});

pub fn render(req: mer.Request) mer.Response {
    const user = UserModel.parse(.{
        .name = "Alice",
        .email = "alice@example.com",
        .age = 30,
        .score = 95.5,
    }) catch |err| {
        return mer.internalError(@errorName(err));
    };
    return mer.typedJson(req.allocator, user);
}
```

Available constraint types: `Str`, `Int`, `Float`, `Bool`, `EmailStr`, `HttpUrl`, `Uuid`, `IPv4`, `IPv6`, `IsoDate`, `IsoDatetime`, `Base64Str`, `PositiveInt`, `NegativeInt`, `PositiveFloat`, `NegativeFloat`, `FiniteFloat`

## Session Cookies (Signed)

merjs supports signed session cookies via HMAC-SHA256:

```zig
// Read session
const session = req.session() catch null;
const user_id = if (session) |s| s.get("user_id") else null;

// Write session (returns Set-Cookie header value)
var resp = mer.html(body);
resp.set_cookie = try req.setSession(.{ .user_id = "123", .role = "admin" });
return resp;

// Clear session
var resp = mer.html(body);
resp.set_cookie = mer.clearSession();
return resp;
```

Session data is base64-encoded JSON, signed with `SESSION_SECRET` env var (required in production).

## Pre-rendering (SSG)

Pages can opt into Static Site Generation — HTML rendered at build time, written to `dist/`.

### Opt in

```zig
pub const prerender = true;

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html("<h1>Static page</h1>");
}
```

### Build & serve

```bash
zig build codegen              # regenerate routes with prerender flags
zig build prerender            # render opted-in pages → dist/
zig build serve -- --no-dev   # production: serves dist/ files first, fallback to SSR
```

### When to pre-render
- ✅ Static content (about, docs, marketing pages)
- ✅ Pages with no request-time data dependencies
- ❌ Pages using `req.path`, `req.params`, or live data
- ❌ API routes

## WASM Modules

1. Create `wasm/<name>.zig`
2. Export functions with `export`
3. Build with `zig build wasm`
4. Output goes to `public/<name>.wasm`
5. Load in browser:

```js
const { instance } = await WebAssembly.instantiateStreaming(fetch("/name.wasm"));
const result = instance.exports.myFunction(arg);
```

### WASM Compatibility

Pages and API routes may also compile for wasm32-freestanding (Cloudflare Workers target). Guard platform APIs:

```zig
const builtin = @import("builtin");

const ts: i64 = if (builtin.target.cpu.arch != .wasm32)
    std.time.timestamp()
else
    0;
```

**NOT available on wasm32-freestanding**: `std.time`, `std.fs`, `std.net`, `std.posix`

## Cloudflare Workers Deployment

merjs compiles to a single WASM binary that runs on the Cloudflare edge:

```bash
zig build worker          # compile → worker/merjs.wasm
cd worker && npx wrangler deploy   # deploy to Cloudflare
```

### Worker structure

```
worker/
  worker.js       → JS fetch handler shim (wraps the WASM module)
  wrangler.toml   → deployment config (account_id, routes, compatibility_date)
```

### CSP / Security Headers

`worker.js` sets `Content-Security-Policy`. When adding external resources (fonts, scripts, APIs) update the CSP directives:

```js
"Content-Security-Policy": [
    "default-src 'self'",
    "script-src 'self' 'unsafe-inline' cdn.jsdelivr.net unpkg.com",
    "connect-src 'self' api.openweathermap.org",
    "style-src 'self' 'unsafe-inline' fonts.googleapis.com",
    "font-src fonts.gstatic.com",
].join("; ")
```

## Build Commands

```bash
zig build codegen    # REQUIRED after adding/removing files in app/ or api/
zig build            # build the server binary
zig build serve      # start dev server on :3000 with hot reload
zig build prerender  # pre-render SSG pages → dist/
zig build css        # compile Tailwind v4 → public/styles.css
zig build wasm       # compile wasm/ → public/*.wasm
zig build worker     # compile to WASM for Cloudflare Workers → worker/merjs.wasm
zig build test       # run tests
```

**Always run from the merjs root directory** (where `build.zig` lives).

## Zig 0.15 API Notes

- `std.ArrayList(T)` is unmanaged: init with `.{}`, pass alloc to `deinit(alloc)`, `append(alloc, item)`
- `std.io.Writer.Allocating` — use for growing writers
- Multiline strings use `\\` prefix — escape sequences like `\u{...}` do NOT work; use actual UTF-8
- `std.Thread.sleep` (not `std.time.sleep` — removed)
- Build: `b.createModule(.{ .root_source_file = ... })` then `exe.root_module.addImport("name", mod)`

## Critical Rules

1. **Always run `zig build codegen`** after adding or removing files in `app/` or `api/`
2. **Never edit `src/generated/routes.zig` by hand** — it is regenerated by codegen
3. **Import as `@import("mer")`** — not a file path
4. **dhi is a package dependency** (in build.zig.zon), not vendored source
5. **HTML builder is comptime-only** — never call `h.*` functions at runtime; dangling pointers will crash
6. **For wasm32 targets**, guard `std.time`, `std.fs`, `std.net` with `builtin.target.cpu.arch != .wasm32`
7. **Tailwind CSS** uses the standalone CLI at `tools/tailwindcss` — no npm needed
8. **Zig version is 0.15.1** — do not use 0.14 APIs
9. **Design system**: always use CSS vars (`--bg`, `--text`, etc.) and DM Serif/DM Sans fonts for new pages
10. **Server**: std.Thread.Pool with 128 workers and kernel backlog 512 — no global mutable state in handlers

## Examples

See `examples/` for reference projects:

```
examples/
  starter/                     → minimal hello-world app
  singapore-data-dashboard/    → data dashboard with API routes + live charts
```

These are **not built by `zig build serve`**. They are standalone examples.
