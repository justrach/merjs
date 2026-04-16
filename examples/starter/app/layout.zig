const std = @import("std");
const mer = @import("mer");

/// Framework primitive — automatically wraps all HTML page responses.
pub fn wrap(allocator: std.mem.Allocator, path: []const u8, body: []const u8, meta: mer.Meta) []const u8 {
    const title = if (meta.title.len > 0) meta.title else if (std.mem.eql(u8, path, "/")) "Home" else if (path.len > 1) path[1..] else "merjs";
    const desc = if (meta.description.len > 0) meta.description else "A Zig-native web framework.";

    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;

    w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\
    ) catch return body;

    w.print("  <title>{s} — merjs</title>\n", .{title}) catch return body;
    w.print("  <meta name=\"description\" content=\"{s}\">\n", .{desc}) catch return body;

    w.writeAll(
        \\  <style>
        \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        \\    :root { --bg:#fafafa; --text:#1a1a2e; --muted:#6b7280; --border:#e5e7eb; --accent:#2563eb; }
        \\    body { background:var(--bg); color:var(--text); font-family:system-ui,-apple-system,sans-serif; min-height:100vh; line-height:1.6; }
        \\    a { color:inherit; text-decoration:none; }
        \\    code { font-size:0.9em; background:#f3f4f6; border-radius:4px; padding:2px 6px; }
        \\    .layout { max-width:680px; margin:0 auto; padding:48px 24px 96px; }
        \\    .layout-header { display:flex; align-items:center; justify-content:space-between; margin-bottom:48px; padding-bottom:16px; border-bottom:1px solid var(--border); }
        \\    .wordmark { font-size:18px; font-weight:700; letter-spacing:-0.02em; }
        \\    .wordmark span { color:var(--accent); }
        \\    .nav { display:flex; gap:20px; }
        \\    .nav a { font-size:14px; color:var(--muted); transition:color 0.15s; }
        \\    .nav a:hover { color:var(--text); }
        \\    .page { }
        \\    .title { font-size:32px; font-weight:700; letter-spacing:-0.02em; margin-bottom:16px; }
        \\    .sub { color:var(--muted); margin-bottom:24px; }
        \\    .links { display:flex; gap:12px; margin-top:24px; flex-wrap:wrap; }
        \\    .btn { display:inline-flex; align-items:center; font-size:14px; font-weight:500; padding:10px 20px; border-radius:6px; background:var(--accent); color:#fff; transition:opacity 0.15s; }
        \\    .btn:hover { opacity:0.9; }
        \\    .btn-outline { background:transparent; border:1px solid var(--border); color:var(--muted); }
        \\    .btn-outline:hover { color:var(--text); border-color:var(--text); }
        \\    .features { display:flex; flex-direction:column; gap:16px; margin:32px 0; }
        \\    .feature { padding:16px; border:1px solid var(--border); border-radius:8px; }
        \\    .feature-title { font-weight:600; margin-bottom:4px; }
        \\    .feature-desc { font-size:14px; color:var(--muted); }
        \\    .layout-footer { margin-top:64px; padding-top:16px; border-top:1px solid var(--border); font-size:12px; color:var(--muted); text-align:center; }
        \\    .layout-footer a { text-decoration:underline; text-underline-offset:2px; }
        \\  </style>
        \\
    ) catch return body;

    if (meta.extra_head) |extra| {
        w.writeAll(extra) catch {};
        w.writeAll("\n") catch {};
    }

    w.writeAll(
        \\</head>
        \\<body>
        \\<div class="layout">
        \\  <header class="layout-header">
        \\    <a href="/" class="wordmark">mer<span>js</span></a>
        \\    <nav class="nav">
        \\      <a href="/about">About</a>
        \\      <a href="/api/hello">API</a>
        \\    </nav>
        \\  </header>
        \\
    ) catch return body;

    w.writeAll(body) catch return body;

    w.writeAll(
        \\
        \\  <footer class="layout-footer">
        \\    Built with <a href="https://github.com/justrach/merjs">merjs</a> &middot; Zig 0.15
        \\  </footer>
        \\</div>
        \\</body>
        \\</html>
    ) catch return body;

    return buf.written();
}
