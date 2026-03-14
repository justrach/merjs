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
        // Header
        h.div(.{ .class = "blog-header" }, .{
            h.div(.{ .class = "blog-date" }, "March 14, 2026"),
            h.h1(.{ .class = "blog-title" }, .{
                h.text("We shipped a web"),
                h.br(),
                h.text("framework that does"),
                h.br(),
                h.span(.{ .class = "red" }, "115,000 req/s."),
                h.br(),
                h.text("Here's how."),
            }),
            h.p(.{ .class = "blog-subtitle" }, "It started at 2,400. Six fixes later, we had a 48x improvement. No rewrite. No async runtime. Just Zig."),
        }),

        // Intro
        h.div(.{ .class = "blog-body" }, .{
            h.p(.{ .class = "blog-lede" }, .{
                h.text("Last week we posted merjs on Twitter. The response was mostly positive \u{2014} people liked the idea of a Zig web framework with zero node_modules. But the benchmarks? "),
                h.em(.{}, "\"2,437 req/s? I expected ~1M RPS for a compiled framework.\""),
            }),
            h.p(.{}, .{
                h.text("They had a point. We were leaving performance on the table everywhere. So we sat down, profiled the hot path, and found six things that were obviously wrong. We fixed all of them in one afternoon. This is the story of each fix, why it mattered, and what we learned."),
            }),
            // Before/After
            h.div(.{ .class = "stats-grid" }, .{
                statCard("Throughput", "2,400", "115,093", "req/s", "48x"),
                statCard("Latency", "41 ms", "0.39 ms", "avg", "105x"),
                statCard("Binary", "1.9 MB", "260 KB", "stripped", "-86%"),
                statCard("LCP", "5.4 s", "0.8 s", "Lighthouse", "99/100"),
            }),
            // Divider
            h.div(.{ .class = "blog-divider" }, .{
                h.div(.{ .class = "blog-divider-label" }, "THE SIX FIXES"),
            }),
            // Fix 1
            section("01", "We were reading files from disk on every request",
                \\Every request to /style.css or /merlion.png opened the file,
                \\read it into a buffer, sent it over the socket, and freed the
                \\buffer. Next request? Same file, same dance.
                \\
                \\The fix was embarrassingly simple: a hash map that caches file
                \\contents on first access. One disk read, then memory forever.
                \\Three lines of code. Biggest single win.
            ),
            // Fix 2
            section("02", "Route matching was a linear scan",
                \\To match a URL to a handler, we iterated every route and
                \\compared strings. With 10 routes that's 10 comparisons per
                \\request. With 50 routes, 50. For something that happens on
                \\every single request, O(N) is unacceptable.
                \\
                \\We replaced it with a StringHashMap for exact matches \u{2014} O(1)
                \\lookup. Dynamic :param routes still do a linear scan, but
                \\those are a small subset.
            ),
            // Fix 3
            section("03", "Our write buffer was comically small",
                \\The HTTP write buffer was 4 KB. A typical HTML response is
                \\13 KB. That means 3-4 flush syscalls per response \u{2014} each one
                \\a context switch to the kernel and back.
                \\
                \\We bumped it to 64 KB. Now most responses flush once. We also
                \\bumped the read buffer from 8 KB to 16 KB. Fewer syscalls,
                \\more throughput.
            ),
            // Fix 4
            section("04", "We were allocating fresh memory per request",
                \\Each request created a new arena allocator, used it for the
                \\entire request lifecycle, then freed everything. On HTTP
                \\keep-alive connections (most connections), this means
                \\allocate-free-allocate-free on every single request.
                \\
                \\The fix: call arena.reset(.retain_capacity) between requests
                \\on the same connection. The memory pages stay allocated \u{2014}
                \\we just reset the bump pointer. Reuse, don't realloc.
            ),
            // Fix 5
            section("05", "128 threads on an 8-core machine",
                \\The thread pool was hardcoded to 128 workers. On an 8-core
                \\chip, that's 120 threads fighting for CPU time. The OS spends
                \\more time context-switching between threads than doing actual
                \\work.
                \\
                \\We switched to CPU count \u{00d7} 2 \u{2014} enough concurrency for I/O
                \\without the overhead. On Apple Silicon that gives ~20 threads.
            ),
            // Fix 6
            section("06", "HTML escaping was byte-by-byte",
                \\Our HTML escaper called writeByte() for every single character
                \\and writeAll() for each escape sequence. For a 10 KB page with
                \\5 escaped characters, that's ~10,000 function calls instead
                \\of ~6.
                \\
                \\The fix: scan ahead for the next special character, write
                \\everything up to it in one writeAll() call, write the escape,
                \\repeat. Batch writes, not character-by-character.
            ),
            // Divider
            h.div(.{ .class = "blog-divider" }, .{
                h.div(.{ .class = "blog-divider-label" }, "BEYOND THROUGHPUT"),
            }),
            // LCP section
            h.div(.{ .class = "section" }, .{
                h.div(.{ .class = "section-num" }, "07"),
                h.div(.{ .class = "section-body" }, .{
                    h.div(.{ .class = "section-heading" }, .{h.raw("The 5-second LCP that wasn't <span class=\"red\">what we thought</span>")}),
                    h.p(.{ .class = "section-text" }, .{
                        h.text("Our Singapore data dashboard had a 5.4 second Largest Contentful Paint. We assumed it was SSR \u{2014} the pages fetch live weather data from government APIs during render, so obviously that's the bottleneck, right?"),
                    }),
                    h.p(.{ .class = "section-text" }, .{
                        h.strong(.{}, "Wrong."),
                        h.text(" The pages return static HTML. The data fetching happens client-side. The real culprit was two "),
                        h.code(.{}, "<script>"),
                        h.text(" tags in the "),
                        h.code(.{}, "<head>"),
                        h.text(" \u{2014} Leaflet (170 KB) and Chart.js (200 KB). Both are render-blocking: the browser won't paint a single pixel until they finish downloading."),
                    }),
                    h.p(.{ .class = "section-text" }, .{
                        h.text("Adding "),
                        h.code(.{}, "<link rel=\"preload\">"),
                        h.text(" hints dropped LCP from 5.4s to 0.8s. Lighthouse went from 72 to 99. The lesson: always check "),
                        h.em(.{}, "what's actually slow"),
                        h.text(" before assuming."),
                    }),
                }),
            }),
            // Shell-first SSR section
            h.div(.{ .class = "section" }, .{
                h.div(.{ .class = "section-num" }, "08"),
                h.div(.{ .class = "section-body" }, .{
                    h.div(.{ .class = "section-heading" }, .{h.raw("Shell-first rendering <span class=\"red\">(not Suspense)</span>")}),
                    h.p(.{ .class = "section-text" }, .{
                        h.text("We split the layout into two parts: the "),
                        h.strong(.{}, "head"),
                        h.text(" (everything up to the header \u{2014} CSS, meta tags, preload hints, navigation) and the "),
                        h.strong(.{}, "tail"),
                        h.text(" (footer, closing tags). The server flushes the head as a chunk immediately via "),
                        h.code(.{}, "transfer-encoding: chunked"),
                        h.text(", before the page's render() function even runs."),
                    }),
                    h.pre(.{ .class = "code-block" }, .{h.code(.{},
                        \\Browser timeline:
                        \\  0ms  - request sent
                        \\  1ms  - head chunk arrives (CSS, nav)
                        \\  1ms  - browser starts painting layout
                        \\  2ms  - body chunk arrives (page content)
                        \\  2ms  - tail chunk arrives (footer)
                    )}),
                    h.p(.{ .class = "section-text" }, .{
                        h.text("To be clear: this is "),
                        h.strong(.{}, "not"),
                        h.text(" React Suspense. The render function still blocks \u{2014} if it calls mer.fetch(), nothing streams until it returns. It's early shell flushing, not async streaming. But for pages where the shell is the LCP element (most pages), this means FCP happens before any page logic runs."),
                    }),
                }),
            }),
            // fetchAll section
            h.div(.{ .class = "section" }, .{
                h.div(.{ .class = "section-num" }, "09"),
                h.div(.{ .class = "section-body" }, .{
                    h.div(.{ .class = "section-heading" }, .{h.raw("<code>mer.fetchAll()</code> \u{2014} parallel data fetching")}),
                    h.p(.{ .class = "section-text" }, .{
                        h.text("For pages that need data from multiple APIs, sequential fetching is a killer. If weather takes 800ms and air quality takes 1.2s, that's 2 seconds of waiting. We added "),
                        h.code(.{}, "mer.fetchAll()"),
                        h.text(" which spawns a thread per request and joins them all:"),
                    }),
                    h.pre(.{ .class = "code-block" }, .{h.code(.{},
                        \\const results = mer.fetchAll(alloc, &.{
                        \\    .{ .url = "https://api.weather.gov/..." },
                        \\    .{ .url = "https://api.air-quality/..." },
                        \\});
                        \\// Both resolve in ~1.2s (slowest), not 2.0s
                    )}),
                }),
            }),
            // CLI section
            h.div(.{ .class = "section" }, .{
                h.div(.{ .class = "section-num" }, "10"),
                h.div(.{ .class = "section-body" }, .{
                    h.div(.{ .class = "section-heading" }, .{h.raw("The <code>mer</code> CLI in 131 KB")}),
                    h.p(.{ .class = "section-text" }, .{
                        h.text("We also built a CLI that scaffolds new projects. The entire starter template is embedded at compile time via "),
                        h.code(.{}, "@embedFile"),
                        h.text(" \u{2014} no runtime file access, no network calls, no package registry. Cross-compiled for macOS and Linux in CI."),
                    }),
                    h.pre(.{ .class = "code-block" }, .{h.code(.{},
                        \\$ mer init my-app
                        \\
                        \\  mer project created in ./my-app
                        \\
                        \\  next steps:
                        \\    cd my-app
                        \\    mer dev
                    )}),
                }),
            }),
            // Takeaway
            h.div(.{ .class = "takeaway" }, .{
                h.p(.{ .class = "takeaway-text" }, .{
                    h.strong(.{}, "The takeaway:"),
                    h.text(" we didn't change the architecture. We didn't add io_uring or rewrite in Rust. We just stopped doing six obviously wasteful things. The static file cache was 3 lines. The buffer resize was changing a number. The total diff was ~130 lines across 4 files."),
                }),
                h.p(.{ .class = "takeaway-text", .style = "margin-top: 12px;" }, .{
                    h.text("If your compiled web framework does fewer than 10,000 req/s, you probably have a bug. "),
                    h.strong(.{}, "Measure before you rewrite."),
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
    \\.blog-lede { font-size: 18px; line-height: 1.7; color: var(--text); }
    \\.blog-lede em { font-style: italic; color: var(--muted); }
    \\.blog-divider { text-align: center; margin: 48px 0 8px; }
    \\.blog-divider-label { font-size: 10px; letter-spacing: 0.15em; color: var(--red); font-weight: 700; }
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
