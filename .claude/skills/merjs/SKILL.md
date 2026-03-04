---
name: merjs
description: Work with the merjs Zig web framework. Use when creating pages, API routes, WASM modules, or modifying the merjs build system. Provides conventions for file-based routing, SSR, type-safe APIs via dhi, and Cloudflare Workers deployment.
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
  router.zig  → static dispatch table
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
tools/        → build tooling
  codegen.zig → scans app/ + api/, writes routes.zig
```

## Creating a Page (HTML Builder — preferred)

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

For pages with runtime-dynamic data (e.g., timestamps, database results), use raw HTML strings:

```zig
const mer = @import("mer");

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html(html);
}

const html =
    \\<h1>Hello</h1>
;
```

For dynamic data, split into top/bottom strings and use `allocPrint`:

```zig
const html_top = \\<div>Rendered at: ;
const html_bottom = \\</div>;

pub fn render(req: mer.Request) mer.Response {
    const ts = std.time.timestamp();
    const body = std.fmt.allocPrint(req.allocator, "{s}{d}{s}", .{html_top, ts, html_bottom})
        catch return mer.internalError("alloc failed");
    return mer.html(body);
}
```

### Page conventions
- `app/index.zig` → `/`
- `app/about.zig` → `/about`
- Nested dirs work: `app/blog/post.zig` → `/blog/post`
- Every page must export `pub fn render(req: mer.Request) mer.Response`
- Follow the existing design system: DM Serif Display + DM Sans fonts, CSS vars `--bg`, `--bg2`, `--bg3`, `--text`, `--muted`, `--border`, `--red`
- Client-side JS can be embedded inline in `<script>` tags or via `h.script(.{}, "...")`

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

All fields are optional with sensible defaults. Use `extra_head` for page-specific CSS or scripts.

## Framework Primitives

These files are auto-detected by the framework — no manual wiring needed:

| File | Purpose |
|------|---------|
| `app/layout.zig` | Wraps all HTML page responses with shared head/nav/footer + SEO tags + logo |
| `app/404.zig` | Custom 404 error page for unmatched routes |

**Layout convention**: Pages returning content fragments (no `<!DOCTYPE>`) are auto-wrapped by `layout.zig`. Pages returning full HTML documents (starting with `<!`) bypass layout.

**Logo**: The layout includes `/merlion.png` in the wordmark. The wordmark links to `/` on all pages.

## Creating an API Route

1. Create `api/<name>.zig`
2. Return JSON using `mer.typedJson`:

```zig
const mer = @import("mer");

const MyResponse = struct { status: []const u8 };

pub fn render(req: mer.Request) mer.Response {
    return mer.typedJson(req.allocator, MyResponse{ .status = "ok" });
}
```

3. Run `zig build codegen`
4. Route is `/api/name`

### API conventions
- Define response structs for type safety
- Use `mer.typedJson(allocator, value)` for JSON serialization
- For validated input, use `mer.dhi.Model(...)` with dhi constraints

## Using dhi Validation

dhi provides Pydantic-style comptime validation:

```zig
const UserModel = mer.dhi.Model("User", .{
    .name  = mer.dhi.Str(.{ .min_length = 1, .max_length = 100 }),
    .email = mer.dhi.EmailStr,
    .age   = mer.dhi.Int(i32, .{ .gt = 0, .le = 150 }),
    .score = mer.dhi.Float(f64, .{ .ge = 0.0, .le = 100.0 }),
});
const user = try UserModel.parse(.{ ... });
```

Available types: `Str`, `Int`, `Float`, `Bool`, `EmailStr`, `HttpUrl`, `Uuid`, `IPv4`, `IPv6`, `IsoDate`, `IsoDatetime`, `Base64Str`, `PositiveInt`, `NegativeInt`, `PositiveFloat`, `NegativeFloat`, `FiniteFloat`

## Pre-rendering (SSG)

Pages can opt into **Static Site Generation** — their HTML is rendered at build time and written to `dist/`. Inspired by Next.js `getStaticProps` / `export const dynamic = 'force-static'`.

### Opt in

Export `pub const prerender = true` from any page:

```zig
const mer = @import("mer");

pub const prerender = true;

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html("<h1>Static page</h1>");
}
```

### Build & serve

```bash
zig build codegen    # regenerate routes with prerender flags
zig build prerender  # render opted-in pages → dist/
zig build serve -- --no-dev  # production: serves dist/ files first, falls back to SSR
```

### How it works

1. `codegen` detects `pub const prerender` and sets `Route.prerender = true`
2. `zig build prerender` runs the server binary with `--prerender`, which:
   - Calls `render()` + layout wrapping for each pre-rendered route
   - Writes HTML to `dist/` (e.g., `/about` → `dist/about.html`)
   - Copies `public/` assets into `dist/` for a self-contained static export
3. In production (`--no-dev`), the server checks `dist/` before SSR dispatch

### When to pre-render

- ✅ Static content (about, docs, marketing pages)
- ✅ Pages with no request-time data dependencies
- ❌ Pages that use `req.path` for dynamic behavior (weather, dashboard)
- ❌ API routes (JSON responses, not pre-rendered)

## WASM Modules

1. Create `wasm/<name>.zig`
2. Export functions with `export`
3. Build with `zig build wasm`
4. Output goes to `public/<name>.wasm`
5. Load in browser with `WebAssembly.instantiateStreaming`

## WASM Compatibility

When writing page/API code that must compile for both native AND wasm32-freestanding (for the Cloudflare Worker target), guard platform-specific APIs:

```zig
const builtin = @import("builtin");
const ts: i64 = if (builtin.target.cpu.arch != .wasm32)
    std.time.timestamp()
else
    0;
```

Key constraint: `std.time`, `std.fs`, `std.net`, `std.posix` are NOT available on wasm32-freestanding.

## Build Commands

```bash
zig build codegen    # Regenerate routes (after adding/removing pages or API routes)
zig build prerender  # Pre-render SSG pages → dist/
zig build css        # Compile Tailwind v4 → public/styles.css
zig build wasm       # Compile wasm/ → public/*.wasm
zig build serve      # Start dev server on :3000 with hot reload
zig build worker     # Compile to WASM for Cloudflare Workers → worker/merjs.wasm
zig build            # Build the server binary
zig build test       # Run tests
```

## Important Rules

1. **Always run `zig build codegen` after adding or removing files in `app/` or `api/`**
2. **Never edit `src/generated/routes.zig` by hand** — it's regenerated by codegen
3. **The `mer` module is imported as `@import("mer")`** — not a file path
4. **dhi is a package dependency** (in build.zig.zon), not vendored source
5. **Multiline strings in Zig use `\\` prefix** — escape sequences like `\u{...}` do NOT work in them; use actual UTF-8 characters
6. **For wasm32 targets**, avoid `std.time`, `std.fs`, `std.net` — use comptime arch checks to guard
7. **Tailwind CSS uses the standalone CLI** at `tools/tailwindcss` — no npm needed
8. **Zig version: 0.15.1** — use 0.15 std library APIs (e.g., `std.io.Writer.Allocating`, unmanaged ArrayList)
9. **HTML builder is comptime-only** — never construct `h.*` nodes at runtime; use raw HTML strings for dynamic pages
10. **Server uses std.Thread.Pool** with 128 workers and kernel backlog 512
