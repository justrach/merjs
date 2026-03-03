const std = @import("std");
const mer = @import("mer");
const h = mer.h;

const static_top = topNode();
const static_bottom = bottomNode();

pub fn render(req: mer.Request) mer.Response {
    const builtin = @import("builtin");
    const ts: i64 = if (builtin.target.cpu.arch != .wasm32)
        std.time.timestamp()
    else
        0;

    const top_html = h.render(req.allocator, static_top) catch return mer.internalError("html render failed");
    const bottom_html = h.render(req.allocator, static_bottom) catch return mer.internalError("html render failed");

    const body = std.fmt.allocPrint(
        req.allocator,
        "{s}{d}{s}",
        .{ top_html, ts, bottom_html },
    ) catch return mer.internalError("alloc failed");
    return mer.html(body);
}

fn topNode() h.Node {
    return h.raw(
        \\<!DOCTYPE html>
        \\<html lang="en">
    ++ renderStatic(h.head(.{}, .{
        h.charset("UTF-8"),
        h.viewport("width=device-width, initial-scale=1.0"),
        h.title("Dashboard \u{2014} merjs"),
        h.description("SSR dashboard with live API polling. Server-side rendered at request time, client polls /api/time every second."),
        h.og("og:type", "website"),
        h.og("og:site_name", "merjs"),
        h.og("og:title", "Dashboard \u{2014} merjs"),
        h.og("og:description", "SSR + live API polling. Rendered by Zig, zero Node.js."),
        h.meta(.{ .name = "twitter:card", .content = "summary" }),
        h.meta(.{ .name = "twitter:title", .content = "Dashboard \u{2014} merjs" }),
        h.meta(.{ .name = "twitter:description", .content = "SSR dashboard with live API polling." }),
        h.link(.{ .rel = "preconnect", .href = "https://fonts.googleapis.com" }),
        h.link(.{ .href = "https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap", .rel = "stylesheet" }),
        h.style(css),
    })) ++
        \\<body>
    ++ comptime renderStatic(h.div(.{ .class = "page" }, .{
        // Header
        h.header(.{ .class = "header" }, .{
            h.div(.{ .class = "wordmark" }, .{ h.text("mer"), h.span(.{}, .{h.raw("js")}) }),
            h.a(.{ .href = "/", .class = "back" }, .{h.raw("&larr; home")}),
        }),
        h.h1(.{}, "Dashboard"),

        // SSR card
        h.div(.{ .class = "card" }, .{
            h.div(.{ .class = "card-label" }, .{
                h.span(.{ .class = "dot dot-red" }, ""),
                h.raw(" Server-side rendered"),
            }),
            h.div(.{ .class = "grid2" }, .{
                h.div(.{ .class = "stat" }, .{
                    h.div(.{ .class = "stat-label" }, "framework"),
                    h.div(.{ .class = "stat-value red" }, "zig"),
                }),
                h.div(.{ .class = "stat" }, .{
                    h.div(.{ .class = "stat-label" }, "node_modules"),
                    h.div(.{ .class = "stat-value red" }, "0"),
                }),
                h.div(.{ .class = "stat", .style = "grid-column:1/-1" }, .{
                    h.div(.{ .class = "stat-label" }, "rendered at (unix)"),
                    h.raw("<div class=\"stat-value\" id=\"ssr-ts\">"),
                }),
            }),
        }),
    })));
}

fn bottomNode() h.Node {
    return h.raw(
        \\</div>
        \\</div>
        \\</div>
    ++ renderStatic(
        h.div(.{ .class = "card" }, .{
            h.div(.{ .class = "card-label" }, .{
                h.span(.{ .class = "dot dot-pulse" }, ""),
                h.raw(" Live &mdash; /api/time"),
            }),
            h.div(.{ .class = "grid2" }, .{
                h.div(.{ .class = "stat", .style = "grid-column:1/-1" }, .{
                    h.div(.{ .class = "stat-label" }, "current unix timestamp"),
                    h.div(.{ .class = "stat-value big", .id = "live-ts" }, .{h.raw("&mdash;")}),
                }),
                h.div(.{ .class = "stat" }, .{
                    h.div(.{ .class = "stat-label" }, "human time"),
                    h.div(.{ .class = "stat-value red", .id = "live-human" }, .{h.raw("&mdash;")}),
                }),
                h.div(.{ .class = "stat" }, .{
                    h.div(.{ .class = "stat-label" }, "iso string"),
                    h.div(.{ .class = "stat-value", .id = "live-iso", .style = "font-size:12px" }, .{h.raw("&mdash;")}),
                }),
            }),
        }),
    ) ++ renderStatic(
        h.p(.{ .class = "footer-note" }, .{
            h.raw("Top card baked by Zig at request time &middot; bottom polls "),
            h.code(.{}, "/api/time"),
            h.text(" every second"),
        }),
    ) ++
        \\</div>
    ++ renderStatic(
        h.script(.{}, js),
    ) ++
        \\</body>
        \\</html>
    );
}

fn renderStatic(node: h.Node) []const u8 {
    @setEvalBranchQuota(100_000);
    var out: [64 * 1024]u8 = undefined;
    var pos: usize = 0;
    renderNodeComptime(&out, &pos, node);
    const final = out[0..pos];
    return final;
}

fn writeAll(buf: *[64 * 1024]u8, pos: *usize, s: []const u8) void {
    @memcpy(buf[pos.*..][0..s.len], s);
    pos.* += s.len;
}

fn renderNodeComptime(buf: *[64 * 1024]u8, pos: *usize, node: h.Node) void {
    switch (node) {
        .text => |txt| {
            for (txt) |c| {
                switch (c) {
                    '&' => writeAll(buf, pos, "&amp;"),
                    '<' => writeAll(buf, pos, "&lt;"),
                    '>' => writeAll(buf, pos, "&gt;"),
                    else => {
                        buf[pos.*] = c;
                        pos.* += 1;
                    },
                }
            }
        },
        .raw => |r| writeAll(buf, pos, r),
        .element => |elem| {
            writeAll(buf, pos, "<");
            writeAll(buf, pos, elem.tag);
            for (elem.attrs) |at| {
                writeAll(buf, pos, " ");
                writeAll(buf, pos, at.name);
                writeAll(buf, pos, "=\"");
                for (at.value) |c| {
                    switch (c) {
                        '&' => writeAll(buf, pos, "&amp;"),
                        '"' => writeAll(buf, pos, "&quot;"),
                        '<' => writeAll(buf, pos, "&lt;"),
                        '>' => writeAll(buf, pos, "&gt;"),
                        else => {
                            buf[pos.*] = c;
                            pos.* += 1;
                        },
                    }
                }
                writeAll(buf, pos, "\"");
            }
            if (elem.self_closing) {
                writeAll(buf, pos, ">");
                return;
            }
            writeAll(buf, pos, ">");
            for (elem.children) |child| {
                renderNodeComptime(buf, pos, child);
            }
            writeAll(buf, pos, "</");
            writeAll(buf, pos, elem.tag);
            writeAll(buf, pos, ">");
        },
    }
}

const css =
    \\*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    \\:root { --bg:#f0ebe3; --bg2:#e8e2d9; --bg3:#ddd5cc; --text:#252530; --muted:#8a7f78; --border:#d5cdc4; --red:#e8251f; }
    \\body { background:var(--bg); color:var(--text); font-family:'DM Sans',system-ui,sans-serif; min-height:100vh; }
    \\a { color:inherit; text-decoration:none; }
    \\.page { max-width:680px; margin:0 auto; padding:48px 32px 96px; }
    \\.header { display:flex; align-items:center; justify-content:space-between; margin-bottom:48px; }
    \\.wordmark { font-family:'DM Serif Display',Georgia,serif; font-size:18px; letter-spacing:-0.02em; }
    \\.wordmark span { color:var(--red); }
    \\.back { font-size:13px; color:var(--muted); transition:color 0.15s; }
    \\.back:hover { color:var(--text); }
    \\h1 { font-family:'DM Serif Display',Georgia,serif; font-size:32px; letter-spacing:-0.02em; margin-bottom:32px; }
    \\.card {
    \\  background:var(--bg2); border:1px solid var(--border);
    \\  border-radius:12px; padding:24px;
    \\  margin-bottom:16px;
    \\}
    \\.card-label {
    \\  display:flex; align-items:center; gap:8px;
    \\  font-size:11px; color:var(--muted);
    \\  text-transform:uppercase; letter-spacing:0.08em;
    \\  margin-bottom:20px;
    \\}
    \\.dot { width:7px; height:7px; border-radius:50%; background:var(--muted); flex-shrink:0; }
    \\.dot-red { background:var(--red); }
    \\.dot-pulse { background:var(--red); animation:pulse 2s infinite; }
    \\@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }
    \\.grid2 { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
    \\.stat { background:var(--bg3); border-radius:8px; padding:16px; }
    \\.stat-label { font-size:11px; color:var(--muted); margin-bottom:6px; }
    \\.stat-value { font-family:'SF Mono','Fira Code',monospace; font-size:15px; color:var(--text); }
    \\.stat-value.red { color:var(--red); }
    \\.stat-value.big { font-size:28px; }
    \\.footer-note { font-size:12px; color:var(--muted); text-align:center; margin-top:24px; }
    \\.footer-note code { font-family:'SF Mono',monospace; font-size:11px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
;

const js =
    \\  async function tick() {
    \\    const d = await fetch('/api/time').then(r => r.json());
    \\    document.getElementById('live-ts').textContent = d.timestamp;
    \\    document.getElementById('live-human').textContent = new Date(d.timestamp * 1000).toLocaleTimeString();
    \\    document.getElementById('live-iso').textContent = d.iso;
    \\  }
    \\  tick(); setInterval(tick, 1000);
;
