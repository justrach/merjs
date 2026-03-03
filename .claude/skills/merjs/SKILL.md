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
  mer.zig     → public API (Request, Response, typedJson, dhi)
  server.zig  → HTTP server (std.http.Server)
  router.zig  → static dispatch table
  ssr.zig     → wires router to generated routes
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

## Creating a Page

1. Create `app/<name>.zig`
2. Import mer and export a `render` function:

```zig
const mer = @import("mer");

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html("<h1>Hello</h1>");
}
```

3. Run `zig build codegen` to register the route
4. The route is automatically `/name`

### Page conventions
- `app/index.zig` → `/`
- `app/about.zig` → `/about`
- Nested dirs work: `app/blog/post.zig` → `/blog/post`
- Every page must export `pub fn render(req: mer.Request) mer.Response`
- Use `mer.html(body)` to return HTML responses
- HTML is written as Zig multiline string literals (`\\` syntax)
- Follow the existing design system: DM Serif Display + DM Sans fonts, CSS vars `--bg`, `--bg2`, `--bg3`, `--text`, `--muted`, `--border`, `--red`
- Client-side JS can be embedded inline in `<script>` tags within the HTML
- For external APIs, fetch client-side (the SSR just renders the shell HTML)

## SEO / Meta Tags (Framework Primitive)

Pages can export `pub const meta: mer.Meta` to get automatic SEO tags injected by the layout:

```zig
pub const meta: mer.Meta = .{
    .title = "Weather",
    .description = "Live weather dashboard powered by Open-Meteo.",
    .og_title = "merjs Weather — Live Forecasts",
    .og_description = "Real-time weather from a Zig web framework.",
    .og_image = "https://example.com/og-weather.png",
    .og_type = "website",
    .twitter_card = "summary_large_image",
    .twitter_site = "@merjs",
    .canonical = "https://example.com/weather",
    .robots = "index, follow",
};
```

All fields are optional with sensible defaults. The layout automatically injects:
- `<title>`, `<meta name="description">`
- `og:title`, `og:description`, `og:image`, `og:url`, `og:type`, `og:site_name`
- `twitter:card`, `twitter:title`, `twitter:description`, `twitter:image`, `twitter:site`
- `<link rel="canonical">`, `<meta name="robots">`
- `extra_head` for arbitrary `<link>`/`<script>` tags

## Framework Primitives

These files are auto-detected by the framework — no manual wiring needed:

| File | Purpose |
|------|---------|
| `app/layout.zig` | Wraps all HTML page responses with shared head/nav/footer + SEO tags |
| `app/404.zig` | Custom 404 error page for unmatched routes |

**Layout convention**: Pages returning content fragments (no `<!DOCTYPE>`) are auto-wrapped. Pages returning full HTML documents (starting with `<!`) bypass layout.

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
zig build codegen   # Regenerate routes (after adding/removing pages or API routes)
zig build css       # Compile Tailwind v4 → public/styles.css
zig build wasm      # Compile wasm/ → public/*.wasm
zig build serve     # Start dev server on :3000 with hot reload
zig build worker    # Compile to WASM for Cloudflare Workers → worker/merjs.wasm
zig build           # Build the server binary
zig build test      # Run tests
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
