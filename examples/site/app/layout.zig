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
        \\  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        \\  <link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet" media="print" onload="this.media='all'">
        \\  <noscript><link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet"></noscript>
        \\  <link rel="preload" as="image" href="/merlion.png" fetchpriority="high">
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
        \\    @media (max-width:600px) {
        \\      .layout { padding:24px 16px 64px; }
        \\      .layout-header { flex-direction:column; align-items:flex-start; gap:8px; margin-bottom:24px; }
        \\      .nav { gap:10px; flex-wrap:wrap; }
        \\      .nav a { font-size:12px; }
        \\    }
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
        \\    <a href="/" class="wordmark"><img src="/merlion.png" alt="merjs logo" class="logo" width="24" height="24" fetchpriority="high">mer<span>js</span></a>
        \\    <nav class="nav">
        \\      <a href="/blog">Blog</a>
        \\      <a href="/stream-demo">Stream</a>
        \\      <a href="/synth">Synth</a>
        \\      <a href="/dashboard">Dashboard</a>
        \\      <a href="/counter">Counter</a>
        \\      <a href="/about">About</a>
        \\      <a href="/docs">Docs</a>
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

/// Streaming-friendly layout split. Returns the shell (head + header) and tail
/// (footer + closing tags) as separate slices. The server flushes head immediately
/// via chunked transfer, then the page body, then the tail.
pub fn streamWrap(allocator: std.mem.Allocator, path: []const u8, meta: mer.Meta) mer.StreamParts {
    const title = if (meta.title.len > 0) meta.title else if (std.mem.eql(u8, path, "/")) "Home" else if (path.len > 1) path[1..] else "merjs";
    const desc = if (meta.description.len > 0) meta.description else "A Zig-native web framework. No Node. No npm. Just WASM.";

    var head_buf: std.ArrayList(u8) = .{};
    const hw = head_buf.writer(allocator);

    hw.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\
    ) catch return .{ .head = "", .tail = "" };

    hw.print("  <title>{s} — merjs</title>\n", .{title}) catch {};
    hw.print("  <meta name=\"description\" content=\"{s}\">\n", .{desc}) catch {};

    if (meta.canonical) |c| hw.print("  <link rel=\"canonical\" href=\"{s}\">\n", .{c}) catch {};
    if (meta.robots) |r| hw.print("  <meta name=\"robots\" content=\"{s}\">\n", .{r}) catch {};

    hw.print("  <meta property=\"og:type\" content=\"{s}\">\n", .{meta.og_type}) catch {};
    hw.print("  <meta property=\"og:site_name\" content=\"{s}\">\n", .{meta.og_site_name}) catch {};
    hw.print("  <meta property=\"og:title\" content=\"{s}\">\n", .{if (meta.og_title) |t| t else title}) catch {};
    hw.print("  <meta property=\"og:description\" content=\"{s}\">\n", .{if (meta.og_description) |d| d else desc}) catch {};
    if (meta.og_image) |img| hw.print("  <meta property=\"og:image\" content=\"{s}\">\n", .{img}) catch {};
    if (meta.og_url) |url| hw.print("  <meta property=\"og:url\" content=\"{s}\">\n", .{url}) catch {};

    hw.print("  <meta name=\"twitter:card\" content=\"{s}\">\n", .{meta.twitter_card}) catch {};
    hw.print("  <meta name=\"twitter:title\" content=\"{s}\">\n", .{if (meta.twitter_title) |t| t else title}) catch {};
    hw.print("  <meta name=\"twitter:description\" content=\"{s}\">\n", .{if (meta.twitter_description) |d| d else desc}) catch {};
    if (meta.twitter_image) |img| hw.print("  <meta name=\"twitter:image\" content=\"{s}\">\n", .{img}) catch {};
    if (meta.twitter_site) |site| hw.print("  <meta name=\"twitter:site\" content=\"{s}\">\n", .{site}) catch {};

    hw.writeAll(
        \\  <link rel="preconnect" href="https://fonts.googleapis.com">
        \\  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        \\  <link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet" media="print" onload="this.media='all'">
        \\  <noscript><link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet"></noscript>
        \\  <link rel="preload" as="image" href="/merlion.png" fetchpriority="high">
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
        \\    @media (max-width:600px) {
        \\      .layout { padding:24px 16px 64px; }
        \\      .layout-header { flex-direction:column; align-items:flex-start; gap:8px; margin-bottom:24px; }
        \\      .nav { gap:10px; flex-wrap:wrap; }
        \\      .nav a { font-size:12px; }
        \\    }
        \\  </style>
        \\
    ) catch {};

    if (meta.extra_head) |extra| {
        hw.writeAll(extra) catch {};
        hw.writeAll("\n") catch {};
    }

    hw.writeAll(
        \\</head>
        \\<body>
        \\<div class="layout">
        \\  <header class="layout-header">
        \\    <a href="/" class="wordmark"><img src="/merlion.png" alt="merjs logo" class="logo" width="24" height="24" fetchpriority="high">mer<span>js</span></a>
        \\    <nav class="nav">
        \\      <a href="/stream-demo">Stream</a>
        \\      <a href="/synth">Synth</a>
        \\      <a href="/stream-demo">Stream</a>
        \\      <a href="/dashboard">Dashboard</a>
        \\      <a href="/counter">Counter</a>
        \\      <a href="/about">About</a>
        \\      <a href="/docs">Docs</a>
        \\    </nav>
        \\  </header>
        \\
    ) catch {};

    const tail =
        \\
        \\  <footer class="layout-footer">
        \\    Built with <a href="https://github.com/justrach/merjs">merjs</a> &middot; Zig 0.15 &middot; zero node_modules
        \\  </footer>
        \\</div>
        \\</body>
        \\</html>
    ;

    return .{ .head = head_buf.items, .tail = tail };
}
