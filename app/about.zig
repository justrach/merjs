const mer = @import("mer");
const h = mer.h;

/// Pre-render this page at build time (SSG). The HTML is written to dist/
/// and served directly without calling render() on each request.
pub const prerender = true;

pub const meta: mer.Meta = .{
    .title = "About",
    .description = "merjs is a Zig-native web framework exploring whether systems languages and WASM can replace Node.js for web development.",
    .og_title = "About merjs — The Zig Web Framework",
    .robots = "index, follow",
    .extra_head =
    \\<style>
    \\  .page { max-width:680px; margin:0 auto; padding:48px 32px 96px; }
    \\  h1 { font-family:'DM Serif Display',Georgia,serif; font-size:38px; letter-spacing:-0.02em; line-height:1.1; margin-bottom:40px; }
    \\  h2 { font-family:'DM Serif Display',Georgia,serif; font-size:22px; letter-spacing:-0.01em; color:var(--text); margin:40px 0 14px; }
    \\  p { font-size:15px; color:var(--muted); line-height:1.75; margin-bottom:16px; }
    \\  p strong { color:var(--text); font-weight:500; }
    \\  code { font-family:'SF Mono','Fira Code',monospace; font-size:13px; background:var(--bg3); border-radius:4px; padding:1px 6px; color:var(--text); }
    \\  .rule { border:none; border-top:1px solid var(--border); margin:40px 0; }
    \\  .stack { display:flex; flex-direction:column; gap:12px; margin:16px 0; }
    \\  .stack-item {
    \\    display:flex; align-items:center; gap:16px;
    \\    background:var(--bg2); border:1px solid var(--border);
    \\    border-radius:8px; padding:14px 16px;
    \\  }
    \\  .stack-num { font-size:11px; color:var(--red); font-weight:600; letter-spacing:0.06em; width:20px; flex-shrink:0; }
    \\  .stack-text { font-size:14px; color:var(--text); }
    \\  .stack-text span { color:var(--muted); font-size:13px; }
    \\  .links { display:flex; gap:12px; margin-top:40px; flex-wrap:wrap; }
    \\  .btn { display:inline-flex; align-items:center; font-size:14px; font-weight:500; padding:11px 22px; border-radius:6px; transition:opacity 0.15s; }
    \\  .btn-red { background:var(--red); color:var(--bg); }
    \\  .btn-red:hover { opacity:0.88; }
    \\  .btn-outline { border:1px solid var(--border); color:var(--muted); }
    \\  .btn-outline:hover { color:var(--text); border-color:var(--text); }
    \\</style>
    ,
};

const page_node = page();

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn page() h.Node {
    return h.div(.{ .class = "page" }, .{
        h.h1(.{}, "Philosophy"),
        h.p(.{}, .{
            h.text("merjs is a bet that the web framework space has been solving the wrong problem. The question was never \"which language should run on the server.\" It was: "),
            h.strong(.{}, "why do we need a runtime at all?"),
        }),
        h.p(.{}, "Node.js unified the language across client and server, and that was genuinely useful. But it came with a cost \u{2014} a sprawling runtime, tens of thousands of dependencies, cold starts measured in seconds, and build pipelines that have become entire careers."),

        h.hr(.{ .class = "rule" }),

        h.h2(.{}, "The WASM argument"),
        h.p(.{}, .{
            h.text("The original justification for JS on the server was simple: it already ran in the browser. WebAssembly makes that argument obsolete. Any language that compiles to WASM can now ship logic to the browser. Zig does this in a single build step \u{2014} "),
            h.code(.{}, "wasm32-freestanding"),
            h.text(", no emscripten, no glue code. The browser runs it natively."),
        }),
        h.p(.{}, .{
            h.text("So now you can write your "),
            h.strong(.{}, "server"),
            h.text(" in Zig (native binary, microsecond cold start), write your "),
            h.strong(.{}, "client logic"),
            h.text(" in Zig (compiled to .wasm, shipped directly), and skip the JavaScript runtime entirely for anything that doesn't need it."),
        }),

        h.hr(.{ .class = "rule" }),

        h.h2(.{}, "What merjs does"),
        h.div(.{ .class = "stack" }, .{
            stackItem("01", "File-based routing", "\u{2014} drop a .zig file, get a route"),
            stackItem("02", "Server-side rendering", "\u{2014} render() runs at request time"),
            stackItem("03", "Type-safe APIs via dhi", "\u{2014} comptime validation, std.json output"),
            stackItem("04", "WASM client logic", "\u{2014} interactive state without a JS framework"),
            stackItem("05", "Hot reload", "\u{2014} SSE + file watcher, no daemon required"),
        }),
        h.div(.{ .class = "links" }, .{
            h.a(.{ .href = "/dashboard", .class = "btn btn-red" }, "See the dashboard"),
            h.a(.{ .href = "/users", .class = "btn btn-outline" }, "Users + dhi"),
            h.a(.{ .href = "/counter", .class = "btn btn-outline" }, "Counter (WASM)"),
        }),
    });
}

fn stackItem(num: []const u8, label: []const u8, detail: []const u8) h.Node {
    return h.div(.{ .class = "stack-item" }, .{
        h.div(.{ .class = "stack-num" }, num),
        h.div(.{ .class = "stack-text" }, .{
            h.text(label),
            h.raw(" "),
            h.span(.{}, detail),
        }),
    });
}
