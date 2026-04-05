const mer = @import("mer");

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return .{
        .status = .not_found,
        .content_type = .html,
        .body = html,
    };
}

const html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <title>404 — merjs</title>
    \\  <link rel="preconnect" href="https://fonts.googleapis.com">
    \\  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    \\  <link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet" media="print" onload="this.media='all'">
    \\  <noscript><link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet"></noscript>
    \\  <style>
    \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    \\    :root { --bg:#f0ebe3; --bg2:#e8e2d9; --bg3:#ddd5cc; --text:#252530; --muted:#8a7f78; --border:#d5cdc4; --red:#e8251f; }
    \\    body { background:var(--bg); color:var(--text); font-family:'DM Sans',system-ui,sans-serif; min-height:100vh; display:flex; align-items:center; justify-content:center; overflow:hidden; }
    \\    a { color:inherit; text-decoration:none; }
    \\    .scene { position:relative; display:flex; flex-direction:column; align-items:center; gap:32px; text-align:center; padding:40px 24px; z-index:1; }
    \\    .bg-num { position:fixed; top:50%; left:50%; transform:translate(-50%,-50%); font-family:'DM Serif Display',Georgia,serif; font-size:min(60vw, 500px); font-weight:700; color:var(--red); opacity:0.06; line-height:0.85; letter-spacing:-0.04em; pointer-events:none; z-index:0; user-select:none; }
    \\    .wordmark { font-family:'DM Serif Display',Georgia,serif; font-size:18px; letter-spacing:-0.02em; }
    \\    .wordmark span { color:var(--red); }
    \\    .code-wrap { position:relative; }
    \\    .code { font-family:'DM Serif Display',Georgia,serif; font-size:clamp(100px, 20vw, 180px); font-weight:700; line-height:1; color:var(--red); letter-spacing:-0.04em; position:relative; }
    \\    .code::after { content:'404'; position:absolute; top:0; left:0; color:var(--bg3); clip-path:inset(0 0 50% 0); animation:glitch 3s ease-in-out infinite; }
    \\    @keyframes glitch {
    \\      0%,90%,100% { transform:translate(0); }
    \\      92% { transform:translate(-3px, 2px); }
    \\      94% { transform:translate(3px, -1px); }
    \\      96% { transform:translate(-2px, 1px); }
    \\    }
    \\    .divider { width:40px; height:3px; background:var(--red); border-radius:2px; }
    \\    h1 { font-family:'DM Serif Display',Georgia,serif; font-size:clamp(24px, 4vw, 36px); letter-spacing:-0.02em; line-height:1.2; }
    \\    .sub { font-size:15px; color:var(--muted); max-width:380px; line-height:1.7; }
    \\    .path { font-family:'SF Mono','Fira Code',monospace; font-size:13px; color:var(--red); background:rgba(232,37,31,0.06); border:1px solid rgba(232,37,31,0.15); border-radius:8px; padding:10px 20px; letter-spacing:0.02em; }
    \\    .actions { display:flex; gap:12px; flex-wrap:wrap; justify-content:center; }
    \\    .btn { display:inline-flex; align-items:center; gap:6px; font-size:14px; font-weight:500; padding:12px 24px; border-radius:8px; transition:all 0.2s; }
    \\    .btn-red { background:var(--red); color:#fff; }
    \\    .btn-red:hover { opacity:0.9; transform:translateY(-1px); box-shadow:0 4px 12px rgba(232,37,31,0.25); }
    \\    .btn-ghost { border:1px solid var(--border); color:var(--muted); }
    \\    .btn-ghost:hover { color:var(--text); border-color:var(--text); }
    \\    .hint { font-size:12px; color:var(--muted); opacity:0.7; }
    \\    .hint code { font-family:'SF Mono',monospace; font-size:11px; background:var(--bg2); padding:2px 6px; border-radius:3px; }
    \\  </style>
    \\</head>
    \\<body>
    \\<div class="bg-num">404</div>
    \\<div class="scene">
    \\  <a href="/" class="wordmark">mer<span>js</span></a>
    \\  <div class="code-wrap">
    \\    <div class="code">404</div>
    \\  </div>
    \\  <div class="divider"></div>
    \\  <h1>This route doesn't exist yet.</h1>
    \\  <p class="sub">You're looking for a page that hasn't been built. Drop a <code>.zig</code> file in <code>app/</code> and it becomes a route automatically.</p>
    \\  <div class="path" id="path"></div>
    \\  <div class="actions">
    \\    <a href="/" class="btn btn-red">Back to home</a>
    \\    <a href="/about" class="btn btn-ghost">About merjs</a>
    \\  </div>
    \\  <p class="hint">Create <code>app/your-page.zig</code> → route appears at <code>/your-page</code></p>
    \\</div>
    \\<script>document.getElementById('path').textContent = location.pathname;</script>
    \\</body>
    \\</html>
;
