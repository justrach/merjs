const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "Desktop — merjs as a native macOS app",
    .description = "No Electron. No Tauri. One 5.3MB Zig binary. Native AppKit + WKWebView.",
    .og_title = "merjs Desktop — Native macOS App in Zig",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html(html);
}

const html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <title>Desktop — merjs</title>
    \\  <link rel="preconnect" href="https://fonts.googleapis.com">
    \\  <link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet">
    \\  <style>
    \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    \\    :root { --bg:#f0ebe3; --bg2:#e8e2d9; --bg3:#ddd5cc; --text:#252530; --muted:#8a7f78; --border:#d5cdc4; --red:#e8251f; }
    \\    body { background:var(--bg); color:var(--text); font-family:'DM Sans',system-ui,sans-serif; min-height:100vh; }
    \\    a { color:inherit; text-decoration:none; }
    \\    .page { max-width:680px; margin:0 auto; padding:48px 32px 96px; }
    \\    .header { display:flex; align-items:center; justify-content:space-between; margin-bottom:56px; }
    \\    .wordmark { font-family:'DM Serif Display',Georgia,serif; font-size:18px; letter-spacing:-0.02em; }
    \\    .wordmark span { color:var(--red); }
    \\    .back { font-size:13px; color:var(--muted); transition:color 0.15s; }
    \\    .back:hover { color:var(--text); }
    \\    h1 { font-family:'DM Serif Display',Georgia,serif; font-size:38px; letter-spacing:-0.02em; line-height:1.1; margin-bottom:16px; }
    \\    .subtitle { font-size:15px; color:var(--muted); line-height:1.6; margin-bottom:40px; }
    \\    h2 { font-family:'DM Serif Display',Georgia,serif; font-size:22px; letter-spacing:-0.01em; color:var(--text); margin:40px 0 14px; }
    \\    p { font-size:15px; color:var(--muted); line-height:1.75; margin-bottom:16px; }
    \\    p strong { color:var(--text); font-weight:500; }
    \\    code { font-family:'SF Mono','Fira Code',monospace; font-size:13px; background:var(--bg3); border-radius:4px; padding:1px 6px; color:var(--text); }
    \\    pre { background:var(--bg2); border:1px solid var(--border); border-radius:8px; padding:16px; overflow-x:auto; font-family:'SF Mono','Fira Code',monospace; font-size:13px; color:var(--text); margin:16px 0; line-height:1.6; }
    \\    .rule { border:none; border-top:1px solid var(--border); margin:40px 0; }
    \\    .stats { display:grid; grid-template-columns:repeat(3,1fr); gap:12px; margin:24px 0 40px; }
    \\    .stat { text-align:center; background:var(--bg2); border:1px solid var(--border); border-radius:8px; padding:20px 12px; }
    \\    .stat-num { font-family:'DM Serif Display',Georgia,serif; font-size:28px; color:var(--red); }
    \\    .stat-label { font-size:12px; color:var(--muted); margin-top:4px; }
    \\    .targets { display:flex; flex-direction:column; gap:8px; margin:16px 0; }
    \\    .target { display:flex; align-items:center; gap:16px; background:var(--bg2); border:1px solid var(--border); border-radius:8px; padding:12px 16px; }
    \\    .target-cmd { font-family:'SF Mono','Fira Code',monospace; font-size:13px; color:var(--red); min-width:160px; }
    \\    .target-desc { font-size:14px; color:var(--muted); }
    \\    .links { display:flex; gap:12px; margin-top:40px; flex-wrap:wrap; }
    \\    .btn { display:inline-flex; align-items:center; font-size:14px; font-weight:500; padding:11px 22px; border-radius:6px; transition:opacity 0.15s; }
    \\    .btn-red { background:var(--red); color:var(--bg); }
    \\    .btn-red:hover { opacity:0.88; }
    \\    .btn-outline { border:1px solid var(--border); color:var(--muted); }
    \\    .btn-outline:hover { color:var(--text); border-color:var(--text); }
    \\    .compare { display:flex; flex-direction:column; gap:8px; margin:16px 0; }
    \\    .compare-row { display:grid; grid-template-columns:140px 100px 1fr; gap:12px; align-items:center; padding:10px 0; border-bottom:1px solid var(--border); font-size:14px; }
    \\    .compare-row:last-child { border-bottom:none; }
    \\    .compare-name { font-weight:500; color:var(--text); }
    \\    .compare-size { font-family:'SF Mono',monospace; font-size:13px; }
    \\    .compare-note { color:var(--muted); font-size:13px; }
    \\    .highlight { color:var(--red); font-weight:600; }
    \\  </style>
    \\</head>
    \\<body>
    \\<div class="page">
    \\  <header class="header">
    \\    <a href="/" class="wordmark">mer<span>js</span></a>
    \\    <a href="/" class="back">&larr; home</a>
    \\  </header>
    \\
    \\  <h1>desktop.zig</h1>
    \\  <p class="subtitle">
    \\    Native macOS app. No Electron. No Tauri. No Node.js.<br>
    \\    One Zig binary. AppKit + WKWebView. Instant launch.
    \\  </p>
    \\
    \\  <div class="stats">
    \\    <div class="stat"><div class="stat-num">5.3MB</div><div class="stat-label">binary size</div></div>
    \\    <div class="stat"><div class="stat-num">0ms</div><div class="stat-label">startup overhead</div></div>
    \\    <div class="stat"><div class="stat-num">171</div><div class="stat-label">lines of Zig</div></div>
    \\  </div>
    \\
    \\  <hr class="rule">
    \\  <h2>How it works</h2>
    \\  <p>
    \\    The app spawns the merjs HTTP server on a <strong>background thread</strong>,
    \\    waits for it to bind a random port, then opens a native
    \\    <strong>NSWindow</strong> with <strong>WKWebView</strong> pointed at localhost.
    \\    Same server, same routes, same SSR &mdash; just wrapped in a native window.
    \\  </p>
    \\  <pre>main thread:  NSApplication + NSWindow + WKWebView
    \\bg thread:    merjs HTTP server (:random-port)
    \\protocol:     plain HTTP (no IPC, no bridge)</pre>
    \\
    \\  <hr class="rule">
    \\  <h2>The ObjC bridge</h2>
    \\  <p>
    \\    No <code>@cImport</code>. No headers. No binding generators.
    \\    Three <code>extern fn</code> declarations give Zig full access to AppKit and WebKit:
    \\  </p>
    \\  <pre>extern fn objc_getClass([*:0]const u8) ?*anyopaque;
    \\extern fn sel_registerName([*:0]const u8) *anyopaque;
    \\extern fn objc_msgSend() void;</pre>
    \\  <p>
    \\    Cast <code>objc_msgSend</code> per call site.
    \\    Zig's comptime handles the rest. No Swift. No Objective-C files.
    \\  </p>
    \\
    \\  <hr class="rule">
    \\  <h2>vs Electron</h2>
    \\  <div class="compare">
    \\    <div class="compare-row">
    \\      <div class="compare-name">Electron</div>
    \\      <div class="compare-size">~200MB</div>
    \\      <div class="compare-note">Chromium + Node.js, ~300ms launch</div>
    \\    </div>
    \\    <div class="compare-row">
    \\      <div class="compare-name">Tauri</div>
    \\      <div class="compare-size">~10MB</div>
    \\      <div class="compare-note">System webview, still needs JS runtime</div>
    \\    </div>
    \\    <div class="compare-row">
    \\      <div class="compare-name highlight">merjs</div>
    \\      <div class="compare-size highlight">5.3MB</div>
    \\      <div class="compare-note">Native binary, zero runtime, instant</div>
    \\    </div>
    \\  </div>
    \\
    \\  <hr class="rule">
    \\  <h2>One codebase, five targets</h2>
    \\  <div class="targets">
    \\    <div class="target"><div class="target-cmd">zig build serve</div><div class="target-desc">Native HTTP server</div></div>
    \\    <div class="target"><div class="target-cmd">zig build worker</div><div class="target-desc">Cloudflare Workers (233KB WASM)</div></div>
    \\    <div class="target"><div class="target-cmd">zig build worker</div><div class="target-desc">Vercel Edge (same WASM)</div></div>
    \\    <div class="target"><div class="target-cmd">docker build</div><div class="target-desc">Container (160MB image)</div></div>
    \\    <div class="target"><div class="target-cmd">zig build desktop</div><div class="target-desc">macOS app (5.3MB binary)</div></div>
    \\  </div>
    \\
    \\  <hr class="rule">
    \\  <h2>Try it</h2>
    \\  <pre>zig build desktop
    \\open zig-out/MerApp.app</pre>
    \\  <p>Two commands. Native app on your dock.</p>
    \\
    \\  <div class="links">
    \\    <a href="https://github.com/justrach/merjs" class="btn btn-red">GitHub</a>
    \\    <a href="/" class="btn btn-outline">Home</a>
    \\    <a href="/about" class="btn btn-outline">Philosophy</a>
    \\  </div>
    \\</div>
    \\</body>
    \\</html>
;
