---
name: streaming-ssr
description: Add streaming SSR to a merjs page. Use when the user wants shell-first rendering, skeleton placeholders, or parallel data fetching that resolves inline.
argument-hint: "[page-name]"
disable-model-invocation: true
---

# Add Streaming SSR to a merjs page

Scaffold or upgrade `app/$ARGUMENTS.zig` to use `renderStream` — shell-first streaming with skeleton placeholders that resolve as data arrives.

## How it works

1. `renderStream` is called instead of `render` when the route is hit
2. `stream.write(html)` flushes bytes to the browser immediately (chunked transfer encoding)
3. `stream.placeholder(id, skeleton_html)` writes a shimmer skeleton + `<div id="P:id">` into the live DOM
4. `mer.fetchAll()` fetches multiple URLs in parallel (threads on dev server, two-phase WASM bridge on Cloudflare Workers)
5. `stream.resolve(id, real_html)` injects a hidden div + inline `<script>` that swaps the skeleton with real content
6. `stream.flush()` ends the response

On Cloudflare Workers, `mer.fetchAll()` uses a two-phase JS bridge:
- Phase 1: WASM dry-run collects URLs (`collect_fetch_urls`)
- Phase 2: JS fetches all in parallel via Workers native `fetch()`
- Phase 3: results injected into WASM cache, full render proceeds

## Steps

1. Create or update `app/$ARGUMENTS.zig`:

```zig
const std = @import("std");
const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "PAGE_TITLE",
    .description = "PAGE_DESCRIPTION",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

// Fallback for non-streaming clients (required)
pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html("<p>Requires streaming.</p>");
}

pub fn renderStream(req: mer.Request, stream: *mer.StreamWriter) void {
    const alloc = req.allocator;

    // Shell hits browser immediately — before any fetch
    stream.write(
        \\<div class="page">
        \\  <h1>PAGE_TITLE</h1>
    );

    // Skeleton placeholders — visible in DOM while fetching
    stream.placeholder("section-a",
        \\<div class="skeleton">Loading...</div>
    );

    // Fetch multiple URLs in parallel
    const results = mer.fetchAll(alloc, &.{
        .{ .url = "https://api.example.com/data-a" },
        .{ .url = "https://api.example.com/data-b" },
    });
    defer for (results) |r| if (r) |ok| ok.deinit(alloc);

    // Resolve skeleton → real content inline
    if (results[0]) |res| {
        stream.resolve("section-a", buildCard(alloc, res.body));
    } else {
        stream.resolve("section-a", "<p>Failed to load.</p>");
    }

    stream.write("</div>");
    stream.flush();
}

fn buildCard(alloc: std.mem.Allocator, body: []u8) []const u8 {
    _ = body;
    return std.fmt.allocPrint(alloc, "<div class=\"card\">data</div>", .{}) catch "error";
}

const page_css =
    \\.page { max-width: 640px; margin: 0 auto; }
    \\.card { background: var(--bg2); border-radius: 10px; padding: 20px; }
    \\.skeleton { background: var(--bg3); border-radius: 10px; padding: 20px; height: 80px;
    \\  position: relative; overflow: hidden; }
    \\.skeleton::after { content:''; position:absolute; inset:0;
    \\  background:linear-gradient(90deg,transparent,rgba(255,255,255,0.25),transparent);
    \\  animation:shimmer 1.5s infinite; }
    \\@keyframes shimmer { 0%{transform:translateX(-100%)} 100%{transform:translateX(100%)} }
;
```

2. Run `zig build codegen` to register the route
3. Run `zig build serve` and visit the route — watch skeletons resolve

## Key rules

- MUST export both `render` (fallback) and `renderStream`
- MUST export `pub const meta: mer.Meta`
- `stream.placeholder(id, skeleton)` must come BEFORE `mer.fetchAll`
- `stream.resolve(id, html)` must come AFTER results are ready
- `stream.flush()` must be called at the end
- `mer.fetchAll` returns `[]?mer.FetchResult` — always handle the null case
- Always `defer` deinit on results to free memory
- The `id` passed to `placeholder` and `resolve` must match exactly

## Live example

- Page: `app/stream-demo.zig`
- URL: https://merlionjs.com/stream-demo
- GitHub: https://github.com/justrach/merjs/blob/main/app/stream-demo.zig

## See also

- `src/mer.zig` — `StreamWriter`, `fetchAll`, `placeholder`, `resolve`
- `src/ssr.zig` — streaming engine
- `src/router.zig` — `dispatchStream` / `dispatchBuffered`
- `src/worker.zig` — two-phase fetch exports (`collect_fetch_urls`, `provide_fetch_result`)
- `PRIMITIVES.md` — full API reference
