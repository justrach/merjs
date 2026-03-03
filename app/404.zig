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
    \\  <link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet">
    \\  <style>
    \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    \\    :root { --bg:#f0ebe3; --bg2:#e8e2d9; --bg3:#ddd5cc; --text:#252530; --muted:#8a7f78; --border:#d5cdc4; --red:#e8251f; }
    \\    body { background:var(--bg); color:var(--text); font-family:'DM Sans',system-ui,sans-serif; min-height:100vh; display:flex; align-items:center; justify-content:center; }
    \\    a { color:inherit; text-decoration:none; }
    \\    .wrap { display:flex; flex-direction:column; align-items:center; gap:24px; text-align:center; padding:40px 24px; }
    \\    .wordmark { font-family:'DM Serif Display',Georgia,serif; font-size:18px; letter-spacing:-0.02em; }
    \\    .wordmark span { color:var(--red); }
    \\    .code { font-family:'SF Mono','Fira Code',monospace; font-size:120px; font-weight:700; line-height:1; color:var(--bg3); letter-spacing:-0.04em; }
    \\    h1 { font-family:'DM Serif Display',Georgia,serif; font-size:28px; letter-spacing:-0.02em; }
    \\    .sub { font-size:14px; color:var(--muted); max-width:320px; line-height:1.6; }
    \\    .back-btn { display:inline-flex; align-items:center; gap:6px; font-size:13px; color:var(--bg); background:var(--text); padding:10px 20px; border-radius:8px; transition:opacity 0.15s; }
    \\    .back-btn:hover { opacity:0.85; }
    \\    .path { font-family:'SF Mono',monospace; font-size:12px; color:var(--muted); background:var(--bg2); border:1px solid var(--border); border-radius:6px; padding:6px 14px; }
    \\  </style>
    \\</head>
    \\<body>
    \\<div class="wrap">
    \\  <a href="/" class="wordmark">mer<span>js</span></a>
    \\  <div class="code">404</div>
    \\  <h1>Page not found</h1>
    \\  <p class="sub">The route you're looking for doesn't exist. Maybe it was never here, or maybe it just hasn't been built yet.</p>
    \\  <div class="path" id="path"></div>
    \\  <a href="/" class="back-btn">← back to home</a>
    \\</div>
    \\<script>document.getElementById('path').textContent = location.pathname;</script>
    \\</body>
    \\</html>
;
