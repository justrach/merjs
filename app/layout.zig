const std = @import("std");
const mer = @import("mer");

/// Layout for Singapore Data Dashboard.
/// Wraps all pages with SG-themed chrome — red/white palette, data.gov.sg branding.
pub fn wrap(allocator: std.mem.Allocator, path: []const u8, body: []const u8, meta: mer.Meta) []const u8 {
    const title = if (meta.title.len > 0) meta.title else if (std.mem.eql(u8, path, "/")) "Home" else if (path.len > 1) path[1..] else "SG Data";
    const desc = if (meta.description.len > 0) meta.description else "Singapore government data dashboard — weather, air quality, datasets. Powered by merjs.";

    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);

    w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\
    ) catch return body;

    w.print("  <title>{s} — SG Data</title>\n", .{title}) catch return body;
    w.print("  <meta name=\"description\" content=\"{s}\">\n", .{desc}) catch return body;

    // Open Graph
    w.print("  <meta property=\"og:type\" content=\"{s}\">\n", .{meta.og_type}) catch {};
    w.print("  <meta property=\"og:site_name\" content=\"SG Data Dashboard\">\n", .{}) catch {};
    w.print("  <meta property=\"og:title\" content=\"{s}\">\n", .{if (meta.og_title) |t| t else title}) catch {};
    w.print("  <meta property=\"og:description\" content=\"{s}\">\n", .{if (meta.og_description) |d| d else desc}) catch {};

    // Twitter
    w.print("  <meta name=\"twitter:card\" content=\"{s}\">\n", .{meta.twitter_card}) catch {};
    w.print("  <meta name=\"twitter:title\" content=\"{s}\">\n", .{if (meta.twitter_title) |t| t else title}) catch {};

    // Fonts + styles
    w.writeAll(
        \\  <link rel="preconnect" href="https://fonts.googleapis.com">
        \\  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        \\  <link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet" media="print" onload="this.media='all'">
        \\  <noscript><link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet"></noscript>
        \\  <style>
        \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        \\    :root { --bg:#f0ebe3; --bg2:#e8e2d9; --bg3:#ddd5cc; --text:#252530; --muted:#8a7f78; --border:#d5cdc4; --red:#e8251f; }
        \\    body { background:var(--bg); color:var(--text); font-family:'DM Sans',system-ui,sans-serif; min-height:100vh; line-height:1.6; }
        \\    a { color:inherit; text-decoration:none; }
        \\    .layout { max-width:780px; margin:0 auto; padding:48px 32px 96px; }
        \\    .layout-header { display:flex; align-items:center; justify-content:space-between; margin-bottom:32px; }
        \\    .wordmark { font-family:'DM Serif Display',Georgia,serif; font-size:18px; letter-spacing:-0.02em; display:flex; align-items:center; gap:8px; }
        \\    .wordmark .flag { display:inline-flex; flex-direction:column; width:20px; height:14px; border-radius:2px; overflow:hidden; }
        \\    .wordmark .flag-r { background:#e8251f; flex:1; }
        \\    .wordmark .flag-w { background:#fff; flex:1; }
        \\    .wordmark span { color:var(--red); }
        \\    .nav { display:flex; gap:20px; }
        \\    .nav a { font-size:13px; color:var(--muted); transition:color 0.15s; }
        \\    .nav a:hover { color:var(--text); }
        \\    .layout-footer { margin-top:64px; padding-top:24px; border-top:1px solid var(--border); font-size:12px; color:var(--muted); text-align:center; }
        \\    .layout-footer a { text-decoration:underline; text-underline-offset:2px; }
        \\  </style>
        \\
    ) catch return body;

    // Extra head content (Chart.js, page CSS, etc.)
    if (meta.extra_head) |extra| {
        w.writeAll(extra) catch {};
        w.writeAll("\n") catch {};
    }

    w.writeAll(
        \\</head>
        \\<body>
        \\<div class="layout">
        \\  <header class="layout-header">
        \\    <a href="/" class="wordmark"><div class="flag"><div class="flag-r"></div><div class="flag-w"></div></div>SG <span>Data</span></a>
        \\    <nav class="nav">
        \\      <a href="/weather">Weather</a>
        \\      <a href="/environment">Environment</a>
        \\      <a href="/explore">Explore</a>
        \\      <a href="/ai">AI</a>
        \\    </nav>
        \\  </header>
        \\
    ) catch return body;

    w.writeAll(body) catch return body;

    w.writeAll(
        \\
        \\  <footer class="layout-footer">
        \\    Data from <a href="https://data.gov.sg">data.gov.sg</a> &middot;
        \\    Built with <a href="https://github.com/justrach/merjs">merjs</a> &middot;
        \\    Zig 0.15 &middot; zero node_modules
        \\  </footer>
        \\</div>
        \\</body>
        \\</html>
    ) catch return body;

    return buf.items;
}
