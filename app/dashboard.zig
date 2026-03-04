const std = @import("std");
const mer = @import("mer");

const html_top =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <title>Dashboard — merjs</title>
    \\  <meta name="description" content="SSR dashboard with live API polling. Server-side rendered at request time, client polls /api/time every second.">
    \\  <meta property="og:type" content="website">
    \\  <meta property="og:site_name" content="merjs">
    \\  <meta property="og:title" content="Dashboard — merjs">
    \\  <meta property="og:description" content="SSR + live API polling. Rendered by Zig, zero Node.js.">
    \\  <meta name="twitter:card" content="summary">
    \\  <meta name="twitter:title" content="Dashboard — merjs">
    \\  <meta name="twitter:description" content="SSR dashboard with live API polling.">
    \\  <link rel="preconnect" href="https://fonts.googleapis.com">
    \\  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    \\  <link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet" media="print" onload="this.media='all'">
    \\  <noscript><link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet"></noscript>
    \\  <style>
    \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    \\    :root { --bg:#f0ebe3; --bg2:#e8e2d9; --bg3:#ddd5cc; --text:#252530; --muted:#8a7f78; --border:#d5cdc4; --red:#e8251f; }
    \\    body { background:var(--bg); color:var(--text); font-family:'DM Sans',system-ui,sans-serif; min-height:100vh; }
    \\    a { color:inherit; text-decoration:none; }
    \\    .page { max-width:680px; margin:0 auto; padding:48px 32px 96px; }
    \\    .header { display:flex; align-items:center; justify-content:space-between; margin-bottom:48px; }
    \\    .wordmark { font-family:'DM Serif Display',Georgia,serif; font-size:18px; letter-spacing:-0.02em; }
    \\    .wordmark span { color:var(--red); }
    \\    .back { font-size:13px; color:var(--muted); transition:color 0.15s; }
    \\    .back:hover { color:var(--text); }
    \\    h1 { font-family:'DM Serif Display',Georgia,serif; font-size:32px; letter-spacing:-0.02em; margin-bottom:32px; }
    \\    .card {
    \\      background:var(--bg2); border:1px solid var(--border);
    \\      border-radius:12px; padding:24px;
    \\      margin-bottom:16px;
    \\    }
    \\    .card-label {
    \\      display:flex; align-items:center; gap:8px;
    \\      font-size:11px; color:var(--muted);
    \\      text-transform:uppercase; letter-spacing:0.08em;
    \\      margin-bottom:20px;
    \\    }
    \\    .dot { width:7px; height:7px; border-radius:50%; background:var(--muted); flex-shrink:0; }
    \\    .dot-red { background:var(--red); }
    \\    .dot-pulse { background:var(--red); animation:pulse 2s infinite; }
    \\    @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }
    \\    .grid2 { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
    \\    .stat { background:var(--bg3); border-radius:8px; padding:16px; }
    \\    .stat-label { font-size:11px; color:var(--muted); margin-bottom:6px; }
    \\    .stat-value { font-family:'SF Mono','Fira Code',monospace; font-size:15px; color:var(--text); }
    \\    .stat-value.red { color:var(--red); }
    \\    .stat-value.big { font-size:28px; }
    \\    .footer-note { font-size:12px; color:var(--muted); text-align:center; margin-top:24px; }
    \\    .footer-note code { font-family:'SF Mono',monospace; font-size:11px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
    \\  </style>
    \\</head>
    \\<body>
    \\<div class="page">
    \\  <header class="header">
    \\    <a href="/" class="wordmark">mer<span>js</span></a>
    \\    <a href="/" class="back">← home</a>
    \\  </header>
    \\  <h1>Dashboard</h1>
    \\  <!-- SSR card -->
    \\  <div class="card">
    \\    <div class="card-label">
    \\      <span class="dot dot-red"></span>
    \\      Server-side rendered
    \\    </div>
    \\    <div class="grid2">
    \\      <div class="stat">
    \\        <div class="stat-label">framework</div>
    \\        <div class="stat-value red">zig</div>
    \\      </div>
    \\      <div class="stat">
    \\        <div class="stat-label">node_modules</div>
    \\        <div class="stat-value red">0</div>
    \\      </div>
    \\      <div class="stat" style="grid-column:1/-1">
    \\        <div class="stat-label">rendered at (unix)</div>
    \\        <div class="stat-value" id="ssr-ts">
;

const html_bottom =
    \\        </div>
    \\      </div>
    \\    </div>
    \\  </div>
    \\  <!-- Live card -->
    \\  <div class="card">
    \\    <div class="card-label">
    \\      <span class="dot dot-pulse"></span>
    \\      Live &mdash; /api/time
    \\    </div>
    \\    <div class="grid2">
    \\      <div class="stat" style="grid-column:1/-1">
    \\        <div class="stat-label">current unix timestamp</div>
    \\        <div class="stat-value big" id="live-ts">—</div>
    \\      </div>
    \\      <div class="stat">
    \\        <div class="stat-label">human time</div>
    \\        <div class="stat-value red" id="live-human">—</div>
    \\      </div>
    \\      <div class="stat">
    \\        <div class="stat-label">iso string</div>
    \\        <div class="stat-value" id="live-iso" style="font-size:12px">—</div>
    \\      </div>
    \\    </div>
    \\  </div>
    \\  <p class="footer-note">
    \\    Top card baked by Zig at request time &middot;
    \\    bottom polls <code>/api/time</code> every second
    \\  </p>
    \\</div>
    \\<script>
    \\  async function tick() {
    \\    const d = await fetch('/api/time').then(r => r.json());
    \\    document.getElementById('live-ts').textContent = d.timestamp;
    \\    document.getElementById('live-human').textContent = new Date(d.timestamp * 1000).toLocaleTimeString();
    \\    document.getElementById('live-iso').textContent = d.iso;
    \\  }
    \\  tick(); setInterval(tick, 1000);
    \\  // Fill SSR timestamp client-side if server couldn't (wasm32)
    \\  const ssrEl = document.getElementById('ssr-ts');
    \\  if (ssrEl && ssrEl.textContent.trim() === '0') {
    \\    ssrEl.textContent = Math.floor(Date.now() / 1000);
    \\  }
    \\</script>
    \\</body>
    \\</html>
;

pub fn render(req: mer.Request) mer.Response {
    const builtin = @import("builtin");
    const ts: i64 = if (builtin.target.cpu.arch != .wasm32)
        std.time.timestamp()
    else
        0;
    const body = std.fmt.allocPrint(
        req.allocator,
        "{s}{d}{s}",
        .{ html_top, ts, html_bottom },
    ) catch return mer.internalError("alloc failed");
    return mer.html(body);
}
