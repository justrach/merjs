const std = @import("std");
const mer = @import("mer");

/// Framework primitive — automatically wraps all HTML page responses.
/// Pages return content fragments; the framework calls wrap() to produce
/// a full document with SEO meta tags injected from the page's `pub const meta`.
pub fn wrap(allocator: std.mem.Allocator, path: []const u8, body: []const u8, meta: mer.Meta) []const u8 {
    const title = if (meta.title.len > 0) meta.title else if (std.mem.eql(u8, path, "/")) "Home" else if (path.len > 1) path[1..] else "merjs";
    const desc = if (meta.description.len > 0) meta.description else "A Zig-native web framework. No Node. No npm. Just WASM.";

    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);

    // Head open
    w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\
    ) catch return body;

    // Title + description
    w.print("  <title>{s} — merjs</title>\n", .{title}) catch return body;
    w.print("  <meta name=\"description\" content=\"{s}\">\n", .{desc}) catch return body;

    // Canonical
    if (meta.canonical) |c| {
        w.print("  <link rel=\"canonical\" href=\"{s}\">\n", .{c}) catch {};
    }

    // Robots
    if (meta.robots) |r| {
        w.print("  <meta name=\"robots\" content=\"{s}\">\n", .{r}) catch {};
    }

    // Open Graph
    w.print("  <meta property=\"og:type\" content=\"{s}\">\n", .{meta.og_type}) catch {};
    w.print("  <meta property=\"og:site_name\" content=\"{s}\">\n", .{meta.og_site_name}) catch {};
    w.print("  <meta property=\"og:title\" content=\"{s}\">\n", .{if (meta.og_title) |t| t else title}) catch {};
    w.print("  <meta property=\"og:description\" content=\"{s}\">\n", .{if (meta.og_description) |d| d else desc}) catch {};
    if (meta.og_image) |img| {
        w.print("  <meta property=\"og:image\" content=\"{s}\">\n", .{img}) catch {};
    }
    if (meta.og_url) |url| {
        w.print("  <meta property=\"og:url\" content=\"{s}\">\n", .{url}) catch {};
    }

    // Twitter Card
    w.print("  <meta name=\"twitter:card\" content=\"{s}\">\n", .{meta.twitter_card}) catch {};
    w.print("  <meta name=\"twitter:title\" content=\"{s}\">\n", .{if (meta.twitter_title) |t| t else title}) catch {};
    w.print("  <meta name=\"twitter:description\" content=\"{s}\">\n", .{if (meta.twitter_description) |d| d else desc}) catch {};
    if (meta.twitter_image) |img| {
        w.print("  <meta name=\"twitter:image\" content=\"{s}\">\n", .{img}) catch {};
    }
    if (meta.twitter_site) |site| {
        w.print("  <meta name=\"twitter:site\" content=\"{s}\">\n", .{site}) catch {};
    }

    // Fonts + styles
    w.writeAll(
        \\  <link rel="preconnect" href="https://fonts.googleapis.com">
        \\  <link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet">
        \\  <style>
        \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        \\    :root { --bg:#f0ebe3; --bg2:#e8e2d9; --bg3:#ddd5cc; --text:#252530; --muted:#8a7f78; --border:#d5cdc4; --red:#e8251f; }
        \\    body { background:var(--bg); color:var(--text); font-family:'DM Sans',system-ui,sans-serif; min-height:100vh; line-height:1.6; }
        \\    a { color:inherit; text-decoration:none; }
        \\    .layout { max-width:780px; margin:0 auto; padding:48px 32px 96px; }
        \\    .layout-header { display:flex; align-items:center; justify-content:space-between; margin-bottom:48px; }
        \\    .wordmark { font-family:'DM Serif Display',Georgia,serif; font-size:18px; letter-spacing:-0.02em; display:flex; align-items:center; gap:6px; }
        \\    .wordmark span { color:var(--red); }
        \\    .wordmark .logo { width:24px; height:24px; object-fit:contain; }
        \\    .nav { display:flex; gap:20px; }
        \\    .nav a { font-size:13px; color:var(--muted); transition:color 0.15s; }
        \\    .nav a:hover { color:var(--text); }
        \\    .layout-footer { margin-top:64px; padding-top:24px; border-top:1px solid var(--border); font-size:12px; color:var(--muted); text-align:center; }
        \\    .layout-footer a { text-decoration:underline; text-underline-offset:2px; }
        \\  </style>
        \\
    ) catch return body;

    // Extra head content
    if (meta.extra_head) |extra| {
        w.writeAll(extra) catch {};
        w.writeAll("\n") catch {};
    }

    // Body
    w.writeAll(
        \\</head>
        \\<body>
        \\<div class="layout">
        \\  <header class="layout-header">
        \\    <a href="/" class="wordmark"><img src="/merlion.png" alt="merjs logo" class="logo">mer<span>js</span></a>
        \\    <nav class="nav">
        \\      <a href="/dashboard">Dashboard</a>
        \\      <a href="/weather">Weather</a>
        \\      <a href="/users">Users</a>
        \\      <a href="/counter">Counter</a>
        \\      <a href="/about">About</a>
        \\    </nav>
        \\  </header>
        \\
    ) catch return body;

    w.writeAll(body) catch return body;

    w.writeAll(
        \\
        \\  <footer class="layout-footer">
        \\    Built with <a href="https://github.com/justrach/merjs">merjs</a> &middot; Zig 0.15 &middot; zero node_modules
        \\  </footer>
        \\</div>
        \\</body>
        \\</html>
    ) catch return body;

    return buf.items;
}
