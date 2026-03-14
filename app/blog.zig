const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "Blog — How we hit 115K req/s",
    .description = "From 2,400 to 115,093 requests per second. A deep dive into optimizing a Zig web framework in one afternoon.",
    .og_title = "How merjs went from 2.4K to 115K req/s in one afternoon",
    .og_description = "Six changes. No architectural rewrite. 48x throughput improvement.",
    .twitter_card = "summary_large_image",
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
    return h.div(.{ .class = "blog" }, .{
        // Header
        h.div(.{ .class = "blog-header" }, .{
            h.div(.{ .class = "blog-date" }, "March 14, 2026"),
            h.h1(.{ .class = "blog-title" }, .{
                h.text("From 2,400 to "),
                h.span(.{ .class = "red" }, "115,000"),
                h.text(" req/s"),
            }),
            h.p(.{ .class = "blog-subtitle" }, "Six changes. No rewrite. One afternoon."),
        }),

        // Intro
        h.div(.{ .class = "blog-body" }, .{
            h.p(.{}, .{
                h.text("People told us our benchmarks were weak. "),
                h.em(.{}, "They were right."),
                h.text(" merjs was doing 2,400 req/s on CI and shipping a 1.9 MB binary. For a compiled framework, that's embarrassing."),
            }),
            h.p(.{}, "We profiled the hot path, found 6 bottlenecks, and fixed them all in a single session. Here's exactly what we changed and why."),
            // Before/After
            h.div(.{ .class = "stats-grid" }, .{
                statCard("Throughput", "2,400", "115,093", "req/s", "48x"),
                statCard("Latency", "41 ms", "0.39 ms", "avg", "105x"),
                statCard("Binary", "1.9 MB", "260 KB", "stripped", "-86%"),
                statCard("LCP", "5.4 s", "0.8 s", "Lighthouse", "99/100"),
            }),
            // Fix 1
            section("01", "Static file cache",
                \\Every request to /style.css or /merlion.png was opening the file,
                \\reading it into memory, sending it, then freeing it. On the next
                \\request — same thing. The fix: a global hash map that caches file
                \\contents on first access. Disk I/O once, memory forever after.
            ),
            // Fix 2
            section("02", "Hash map router",
                \\Route matching was O(N) — iterate all routes, compare strings. With
                \\10 routes that's fine, with 50 it's not. We replaced the linear scan
                \\with a StringHashMap for exact matches (O(1)) and only fall back to
                \\linear scan for dynamic :param routes.
            ),
            // Fix 3
            section("03", "Write buffer 4 KB \xe2\x86\x92 64 KB",
                \\The HTTP write buffer was 4 KB. A typical HTML response is 13 KB.
                \\That's 3-4 flush syscalls per response instead of 1. We also bumped
                \\the read buffer from 8 KB to 16 KB. Fewer syscalls = fewer context
                \\switches = more throughput.
            ),
            // Fix 4
            section("04", "Arena reset for keep-alive",
                \\Each request allocated a new arena, used it, and freed everything.
                \\On HTTP keep-alive connections (which is most connections), this
                \\means allocate-free-allocate-free for every request on the same
                \\connection. We now call arena.reset(.retain_capacity) between
                \\requests — the memory is reused, not freed and reallocated.
            ),
            // Fix 5
            section("05", "CPU-based thread pool",
                \\The thread pool was hardcoded to 128 workers. On an 8-core machine,
                \\that's 120 threads fighting for CPU time. Context switching kills
                \\throughput. We switched to CPU count \xc3\x97 2, which on Apple Silicon
                \\gives ~20 threads — enough for I/O concurrency without the overhead.
            ),
            // Fix 6
            section("06", "Batch HTML escaping",
                \\The HTML escaper was calling writeByte() for every character and
                \\writeAll() for every escape sequence. For a 10 KB page with 5 escaped
                \\characters, that's ~10,000 function calls instead of ~6. We switched
                \\to a find-next-escape pattern: scan for the next special character,
                \\write everything up to it in one call, write the escape, repeat.
            ),
            // LCP section
            h.div(.{ .class = "section" }, .{
                h.div(.{ .class = "section-num" }, "07"),
                h.div(.{ .class = "section-body" }, .{
                    h.div(.{ .class = "section-heading" }, .{h.raw("The LCP <span class=\"red\">mystery</span>")}),
                    h.p(.{ .class = "section-text" }, .{
                        h.text("Our Singapore data dashboard had a 5.4 second LCP. We assumed it was SSR data fetching. "),
                        h.strong(.{}, "It wasn't."),
                    }),
                    h.p(.{ .class = "section-text" }, .{
                        h.text("The real culprit: two "),
                        h.code(.{}, "<script>"),
                        h.text(" tags in the "),
                        h.code(.{}, "<head>"),
                        h.text(" loading Leaflet (170 KB) and Chart.js (200 KB). These are render-blocking \u{2014} the browser won't paint a single pixel until both finish downloading. Adding "),
                        h.code(.{}, "<link rel=\"preload\">"),
                        h.text(" hints dropped LCP from 5.4s to 0.8s. Lighthouse went from 72 to 99."),
                    }),
                }),
            }),
            // CLI section
            h.div(.{ .class = "section" }, .{
                h.div(.{ .class = "section-num" }, "08"),
                h.div(.{ .class = "section-body" }, .{
                    h.div(.{ .class = "section-heading" }, .{h.raw("The <code>mer</code> CLI")}),
                    h.p(.{ .class = "section-text" }, .{
                        h.text("While we were at it, we built a CLI. 131 KB binary with the starter template embedded at compile time via "),
                        h.code(.{}, "@embedFile"),
                        h.text(". Cross-compiled for 4 platforms in CI."),
                    }),
                    h.pre(.{ .class = "code-block" }, .{h.code(.{},
                        \\mer init my-app
                        \\cd my-app
                        \\mer dev
                    )}),
                }),
            }),
            // Takeaway
            h.div(.{ .class = "takeaway" }, .{
                h.p(.{ .class = "takeaway-text" }, .{
                    h.text("The lesson: "),
                    h.strong(.{}, "measure before you rewrite."),
                    h.text(" We didn't change the architecture. We didn't add async I/O or io_uring. We just stopped doing obviously wasteful things on the hot path. The biggest win (static file cache) was 3 lines of code."),
                }),
            }),
            // Footer links
            h.div(.{ .class = "blog-links" }, .{
                h.a(.{ .href = "/", .class = "btn-ghost" }, "Back to home"),
                h.a(.{ .href = "https://github.com/justrach/merjs", .class = "btn-primary" }, "View on GitHub"),
            }),
        }),
    });
}

fn section(num: []const u8, heading: []const u8, body_text: []const u8) h.Node {
    return h.div(.{ .class = "section" }, .{
        h.div(.{ .class = "section-num" }, num),
        h.div(.{ .class = "section-body" }, .{
            h.div(.{ .class = "section-heading" }, heading),
            h.p(.{ .class = "section-text" }, body_text),
        }),
    });
}

fn statCard(label: []const u8, before: []const u8, after: []const u8, unit: []const u8, badge: []const u8) h.Node {
    return h.div(.{ .class = "stat-card" }, .{
        h.div(.{ .class = "stat-label" }, label),
        h.div(.{ .class = "stat-before" }, .{ h.text(before), h.span(.{ .class = "stat-unit" }, .{ h.text(" "), h.text(unit) }) }),
        h.div(.{ .class = "stat-arrow" }, "\xe2\x86\x93"),
        h.div(.{ .class = "stat-after" }, after),
        h.div(.{ .class = "stat-badge" }, badge),
    });
}

const page_css =
    \\.blog { max-width: 680px; margin: 0 auto; padding: 40px 24px 120px; }
    \\.blog-header { margin-bottom: 48px; }
    \\.blog-date { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.08em; margin-bottom: 16px; }
    \\.blog-title {
    \\  font-family: 'DM Serif Display', Georgia, serif;
    \\  font-size: clamp(32px, 5vw, 48px);
    \\  line-height: 1.1; letter-spacing: -0.03em;
    \\  margin-bottom: 12px;
    \\}
    \\.blog-title .red { color: var(--red); }
    \\.blog-subtitle { font-size: 18px; color: var(--muted); line-height: 1.5; }
    \\.blog-body p { font-size: 16px; line-height: 1.8; color: var(--text); margin-bottom: 20px; max-width: 100%; }
    \\.blog-body p em { font-style: italic; }
    \\.blog-body p code {
    \\  font-family: 'SF Mono', 'Fira Code', monospace;
    \\  font-size: 14px; background: var(--bg3); border-radius: 4px;
    \\  padding: 2px 6px;
    \\}
    \\.stats-grid {
    \\  display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
    \\  gap: 12px; margin: 36px 0 48px;
    \\}
    \\.stat-card {
    \\  background: var(--bg2); border-radius: 8px; padding: 20px;
    \\  text-align: center; position: relative;
    \\}
    \\.stat-label { font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); margin-bottom: 8px; font-weight: 600; }
    \\.stat-before { font-size: 14px; color: var(--muted); text-decoration: line-through; }
    \\.stat-unit { font-size: 11px; }
    \\.stat-arrow { font-size: 14px; color: var(--red); margin: 4px 0; }
    \\.stat-after { font-size: 22px; font-weight: 600; color: var(--text); font-family: 'DM Serif Display', Georgia, serif; }
    \\.stat-badge {
    \\  position: absolute; top: 8px; right: 8px;
    \\  font-size: 10px; font-weight: 700; color: #fff;
    \\  background: var(--red); border-radius: 4px;
    \\  padding: 2px 6px;
    \\}
    \\.section {
    \\  display: grid; grid-template-columns: 36px 1fr;
    \\  gap: 16px; padding: 32px 0;
    \\  border-top: 1px solid var(--border);
    \\}
    \\.section-num { font-size: 11px; color: var(--red); font-weight: 600; letter-spacing: 0.08em; padding-top: 4px; }
    \\.section-heading {
    \\  font-family: 'DM Serif Display', Georgia, serif;
    \\  font-size: clamp(18px, 2.5vw, 24px);
    \\  line-height: 1.2; letter-spacing: -0.02em;
    \\  margin-bottom: 12px;
    \\}
    \\.section-heading .red { color: var(--red); }
    \\.section-heading code {
    \\  font-family: 'SF Mono', 'Fira Code', monospace;
    \\  font-size: 0.85em; background: var(--bg3); border-radius: 4px;
    \\  padding: 2px 6px;
    \\}
    \\.section-text { font-size: 15px; color: var(--muted); line-height: 1.75; white-space: pre-line; }
    \\.code-block {
    \\  background: var(--text); color: var(--bg); border-radius: 6px;
    \\  padding: 16px 20px; font-size: 14px; line-height: 1.6;
    \\  font-family: 'SF Mono', 'Fira Code', monospace;
    \\  overflow-x: auto; margin-top: 16px;
    \\}
    \\.takeaway {
    \\  margin: 48px 0; padding: 28px 24px;
    \\  background: var(--bg2); border-radius: 8px;
    \\  border-left: 3px solid var(--red);
    \\}
    \\.takeaway-text { font-size: 16px; line-height: 1.7; color: var(--text); margin: 0 !important; }
    \\.takeaway-text strong { color: var(--red); }
    \\.blog-links { display: flex; gap: 12px; margin-top: 48px; flex-wrap: wrap; }
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
    \\@media (max-width: 600px) {
    \\  .blog { padding: 20px 16px 64px; }
    \\  .blog-title { font-size: 28px; }
    \\  .stats-grid { grid-template-columns: 1fr 1fr; }
    \\  .section { grid-template-columns: 1fr; gap: 8px; }
    \\  .section-num { padding-top: 0; }
    \\}
;
