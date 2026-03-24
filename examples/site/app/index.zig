const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "merjs \u{2014} A Zig-native web framework",
    .description = "A Next.js competitor written in Zig. Zero Node.js, zero node_modules. SSR, file-based routing, type-safe APIs, and WASM for client interactivity.",
    .og_title = "merjs \u{2014} A Zig-native web framework. No Node. No npm. Just WASM.",
    .og_description = "A Next.js competitor written in Zig. Zero Node.js, zero node_modules. SSR, file-based routing, type-safe APIs, and WASM for client interactivity.",
    .og_url = "https://merlionjs.com",
    .twitter_card = "summary_large_image",
    .twitter_title = "merjs \u{2014} A Zig-native web framework",
    .twitter_description = "Zero Node.js. Zero node_modules. Pure Zig all the way down.",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

const page_node = page();
comptime {
    mer.lint.check(page_node);
}

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn page() h.Node {
    return h.div(.{ .class = "page" }, .{
        // Hero
        h.h1(.{ .class = "lede" }, .{
            h.text("The web doesn't need"),
            h.br(),
            h.em(.{}, "another"),
            h.text(" JavaScript"),
            h.br(),
            h.text("framework. It needs"),
            h.br(),
            h.span(.{ .class = "red" }, "no runtime at all."),
        }),

        // Benchmark comparison
        // Benchmark comparison
        h.div(.{ .class = "bench" }, .{
            h.div(.{ .class = "bench-title" }, .{h.raw("vs Next.js &mdash; <span class=\"red\">at a glance</span>")}),
            h.p(.{ .class = "bench-sub" }, "Head-to-head on the metrics that matter."),
            h.div(.{ .class = "bench-legend" }, .{
                h.div(.{ .class = "bench-legend-item" }, .{ h.div(.{ .class = "bench-legend-dot mer" }, ""), h.text(" merjs") }),
                h.div(.{ .class = "bench-legend-item" }, .{ h.div(.{ .class = "bench-legend-dot next" }, ""), h.text(" Next.js") }),
            }),
            benchRow("Cold Start", "8%", "< 5 ms", "80%", "~1-3 s"),
            benchRow("Throughput", "95%", "115,093 req/s", "8%", "2,060 req/s"),
            benchRow("Avg Latency", "49%", "40.86 ms", "90%", "74.39 ms"),
            benchRow("Binary Size", "8%", "260 KB", "85%", "~300 MB node_modules"),
            benchRow("Build Time", "12%", "~4.7 s", "90%", "~33 s"),
            h.p(.{ .class = "bench-note" }, .{
                h.text("Throughput and latency measured locally on Apple M-series with "),
                h.code(.{}, "wrk -t4 -c50"),
                h.text(". Next.js numbers from CI (GitHub Actions). merjs is an early experiment \u{2014} Next.js is mature and production-grade. Binary size is the release-stripped native binary ("),
                h.code(.{}, "-Doptimize=ReleaseSmall"),
                h.text(")."),
            }),
        }),

        h.hr(.{ .class = "rule" }),

        // Items
        h.div(.{ .class = "items" }, .{
            item("01", "Node.js solved the wrong problem.", .{
                h.text("It unified the language, not the stack. You still ship a 400MB runtime to run a "),
                h.code(.{}, "hello world"),
                h.text(". You still wait 30 seconds for "),
                h.strong(.{}, "npm install"),
                h.text(". You still debug dependency conflicts that have nothing to do with your product. The problem was never \"which language\" \u{2014} it was \"why do we need a runtime at all.\""),
            }),
            item("02",
                \\<span class="red">WASM</span> closes the last gap.
            , .{
                h.text("The real reason JS won the server: it already ran in the browser. That moat is gone. WebAssembly is a compile target for "),
                h.em(.{}, "any"),
                h.text(" language. Zig compiles to "),
                h.code(.{}, "wasm32-freestanding"),
                h.text(" in a single step. Write client logic in Zig, compile to "),
                h.strong(.{}, ".wasm"),
                h.text(", ship it directly. No transpiler. No bundler. The browser runs it natively."),
            }),
            item("03",
                \\One language. <em>Two targets.</em>
            , .{
                h.text("The server compiles to a "),
                h.strong(.{}, "native binary"),
                h.text(". The client compiles to "),
                h.strong(.{}, ".wasm"),
                h.text(". File-based routing, SSR, type-safe APIs, hot reload \u{2014} everything Next.js does, in Zig. Zero node_modules. A single "),
                h.code(.{}, "zig build serve"),
                h.text("."),
            }),
            item("04",
                \\Type safety without a <span class="red">build step.</span>
            , .{
                h.text("Validation constraints are comptime. API schemas are Zig structs. JSON serialization is "),
                h.code(.{}, "std.json"),
                h.text(". No codegen. No schema files. No runtime overhead. The compiler catches it, or it doesn't compile."),
            }),
            item("05",
                \\This is <em>early proof.</em>
            , .{
                h.text("merjs is a bet \u{2014} that systems languages, WASM, and file-based routing can meet in one place and produce something better than what we have today. The node_modules folder had a good run. "),
                h.strong(.{}, "It's time to move on."),
            }),
        }),

        // Footer
        h.div(.{ .class = "footer" }, .{
            h.a(.{ .href = "/dashboard", .class = "btn-primary" }, "See it in action"),
            h.a(.{ .href = "/about", .class = "btn-ghost" }, "Read the philosophy"),
            h.p(.{ .class = "footer-note" }, .{
                h.text("Built in "),
                h.a(.{ .href = "https://ziglang.org" }, "Zig 0.15"),
                h.raw(" &middot; Validation by "),
                h.a(.{ .href = "https://github.com/justrach/dhi" }, "dhi"),
                h.raw(" &middot; Zero node_modules"),
            }),
        }),
    });
}

fn benchRow(label: []const u8, mer_width: []const u8, mer_val: []const u8, next_width: []const u8, next_val: []const u8) h.Node {
    return h.div(.{ .class = "bench-row" }, .{
        h.div(.{ .class = "bench-label" }, label),
        h.div(.{ .class = "bench-bars" }, .{
            h.div(.{ .class = "bench-bar-wrap" }, .{
                h.div(.{ .class = "bench-bar mer", .style = "width: " ++ mer_width ++ ";" }, mer_val),
                h.div(.{ .class = "bench-bar-tag" }, "merjs"),
            }),
            h.div(.{ .class = "bench-bar-wrap" }, .{
                h.div(.{ .class = "bench-bar next", .style = "width: " ++ next_width ++ ";" }, next_val),
                h.div(.{ .class = "bench-bar-tag" }, "Next.js"),
            }),
        }),
    });
}

fn item(num: []const u8, heading: []const u8, body_children: anytype) h.Node {
    return h.div(.{ .class = "item" }, .{
        h.div(.{ .class = "item-num" }, num),
        h.div(.{ .class = "item-body" }, .{
            h.div(.{ .class = "item-heading" }, .{h.raw(heading)}),
            h.p(.{ .class = "item-text" }, body_children),
        }),
    });
}

const page_css =
    \\.page { max-width: 800px; margin: 0 auto; padding: 56px 40px 120px; }
    \\.lede {
    \\  font-family: 'DM Serif Display', Georgia, serif;
    \\  font-size: clamp(36px, 5vw, 58px);
    \\  line-height: 1.08;
    \\  letter-spacing: -0.03em;
    \\  color: var(--text);
    \\  margin-bottom: 56px;
    \\}
    \\.lede .red { color: var(--red); }
    \\.lede em { font-style: italic; }
    \\.rule { border: none; border-top: 1px solid var(--border); margin: 48px 0; }
    \\.items { display: flex; flex-direction: column; }
    \\.item {
    \\  display: grid;
    \\  grid-template-columns: 40px 1fr;
    \\  gap: 16px;
    \\  padding: 36px 0;
    \\  border-bottom: 1px solid var(--border);
    \\}
    \\.item:first-child { border-top: 1px solid var(--border); }
    \\.item-num { font-size: 11px; color: var(--red); font-weight: 600; letter-spacing: 0.08em; padding-top: 6px; }
    \\.item-heading {
    \\  font-family: 'DM Serif Display', Georgia, serif;
    \\  font-size: clamp(20px, 2.6vw, 28px);
    \\  line-height: 1.15; letter-spacing: -0.02em;
    \\  color: var(--text); margin-bottom: 12px;
    \\}
    \\.item-heading .red { color: var(--red); }
    \\.item-heading em { font-style: italic; }
    \\.item-text { font-size: 15px; color: var(--muted); line-height: 1.75; max-width: 580px; }
    \\.item-text strong { color: var(--text); font-weight: 500; }
    \\.item-text code {
    \\  font-family: 'SF Mono', 'Fira Code', monospace;
    \\  font-size: 13px; background: var(--bg3);
    \\  border-radius: 4px; padding: 1px 6px; color: var(--text);
    \\}
    \\.bench { margin-top: 0; }
    \\.bench-title {
    \\  font-family: 'DM Serif Display', Georgia, serif;
    \\  font-size: clamp(22px, 3vw, 32px);
    \\  letter-spacing: -0.02em; color: var(--text); margin-bottom: 8px;
    \\}
    \\.bench-title .red { color: var(--red); }
    \\.bench-sub { font-size: 13px; color: var(--muted); margin-bottom: 32px; line-height: 1.5; }
    \\.bench-legend { display: flex; gap: 20px; margin-bottom: 24px; }
    \\.bench-legend-item { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }
    \\.bench-legend-dot { width: 10px; height: 10px; border-radius: 2px; }
    \\.bench-legend-dot.mer { background: var(--red); }
    \\.bench-legend-dot.next { background: var(--border); }
    \\.bench-row { margin-bottom: 28px; }
    \\.bench-label { font-size: 12px; font-weight: 600; color: var(--text); letter-spacing: 0.04em; text-transform: uppercase; margin-bottom: 10px; }
    \\.bench-bars { display: flex; flex-direction: column; gap: 6px; }
    \\.bench-bar-wrap { display: flex; align-items: center; gap: 10px; }
    \\.bench-bar {
    \\  height: 32px; border-radius: 4px;
    \\  display: flex; align-items: center; padding: 0 12px;
    \\  font-size: 12px; font-weight: 600; color: #fff;
    \\  white-space: nowrap; min-width: max-content;
    \\}
    \\.bench-bar.mer { background: var(--red); }
    \\.bench-bar.next { background: var(--border); color: var(--muted); }
    \\.bench-bar-tag { font-size: 11px; color: var(--muted); white-space: nowrap; flex-shrink: 0; min-width: 40px; }
    \\.bench-note { font-size: 11px; color: var(--muted); margin-top: 32px; line-height: 1.6; font-style: italic; }
    \\.footer { margin-top: 72px; display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    \\.btn-primary {
    \\  display: inline-flex; align-items: center;
    \\  background: var(--red); color: var(--bg);
    \\  font-size: 14px; font-weight: 600;
    \\  padding: 12px 26px; border-radius: 6px;
    \\  transition: opacity 0.15s;
    \\}
    \\.btn-primary:hover { opacity: 0.88; }
    \\.btn-ghost {
    \\  display: inline-flex; align-items: center;
    \\  color: var(--muted); font-size: 14px;
    \\  border: 1px solid var(--border);
    \\  padding: 12px 26px; border-radius: 6px;
    \\  transition: color 0.15s, border-color 0.15s;
    \\}
    \\.btn-ghost:hover { color: var(--text); border-color: var(--text); }
    \\.footer-note { width: 100%; margin-top: 28px; font-size: 12px; color: var(--muted); }
    \\.footer-note a { border-bottom: 1px solid var(--border); padding-bottom: 1px; }
    \\.footer-note a:hover { color: var(--text); }
    \\@media (max-width: 600px) {
    \\  .page { padding: 24px 16px 64px; }
    \\  .lede { font-size: 28px; margin-bottom: 32px; }
    \\  .lede br { display: none; }
    \\  .rule { margin: 28px 0; }
    \\  .item { grid-template-columns: 1fr; gap: 8px; padding: 20px 0; }
    \\  .item-num { padding-top: 0; }
    \\  .item-heading { font-size: 18px; }
    \\  .item-text { font-size: 14px; max-width: 100%; }
    \\  .footer { flex-direction: column; align-items: stretch; gap: 10px; margin-top: 40px; }
    \\  .btn-primary, .btn-ghost { justify-content: center; text-align: center; padding: 14px 20px; }
    \\  .footer-note { text-align: center; }
    \\  .bench-legend { gap: 14px; }
    \\  .bench-bar { height: 24px; font-size: 11px; }
    \\  .bench-row { margin-bottom: 22px; }
    \\}
;
