const mer = @import("mer");

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
    \\  <title>Counter — merjs</title>
    \\  <meta name="description" content="Interactive WASM counter. State lives in Zig, compiled to wasm32-freestanding. JS just applies patches.">
    \\  <meta property="og:type" content="website">
    \\  <meta property="og:site_name" content="merjs">
    \\  <meta property="og:title" content="WASM Counter — merjs">
    \\  <meta property="og:description" content="State lives in Zig/WASM. JS just applies patches. Zero bundlers.">
    \\  <meta name="twitter:card" content="summary">
    \\  <meta name="twitter:title" content="WASM Counter — merjs">
    \\  <meta name="twitter:description" content="Interactive counter with state in Zig WASM.">
    \\  <link rel="preconnect" href="https://fonts.googleapis.com">
    \\  <link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet">
    \\  <style>
    \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    \\    :root { --bg:#f0ebe3; --bg2:#e8e2d9; --bg3:#ddd5cc; --text:#252530; --muted:#8a7f78; --border:#d5cdc4; --red:#e8251f; }
    \\    body { background:var(--bg); color:var(--text); font-family:'DM Sans',system-ui,sans-serif; min-height:100vh; display:flex; align-items:center; justify-content:center; }
    \\    a { color:inherit; text-decoration:none; }
    \\    .wrap { display:flex; flex-direction:column; align-items:center; gap:32px; text-align:center; padding:40px 24px; }
    \\    .wordmark { font-family:'DM Serif Display',Georgia,serif; font-size:18px; letter-spacing:-0.02em; }
    \\    .wordmark span { color:var(--red); }
    \\    h1 { font-family:'DM Serif Display',Georgia,serif; font-size:28px; letter-spacing:-0.02em; }
    \\    .sub { font-size:13px; color:var(--muted); max-width:280px; }
    \\    .count {
    \\      font-family:'SF Mono','Fira Code',monospace;
    \\      font-size:96px; font-weight:700; line-height:1;
    \\      color:var(--text); letter-spacing:-0.04em;
    \\      min-width:3ch; text-align:center;
    \\    }
    \\    .buttons { display:flex; gap:12px; align-items:center; }
    \\    .btn {
    \\      width:52px; height:52px; border-radius:8px;
    \\      border:1px solid var(--border); background:var(--bg2);
    \\      font-size:24px; font-weight:500; color:var(--text);
    \\      cursor:pointer; transition:background 0.12s, border-color 0.12s;
    \\      display:flex; align-items:center; justify-content:center;
    \\    }
    \\    .btn:hover { background:var(--bg3); border-color:var(--text); }
    \\    .btn-inc {
    \\      background:var(--red); border-color:var(--red); color:var(--bg);
    \\    }
    \\    .btn-inc:hover { opacity:0.88; }
    \\    .btn-reset {
    \\      width:auto; padding:0 18px; font-size:13px; font-weight:500;
    \\      color:var(--muted); font-family:'DM Sans',sans-serif;
    \\    }
    \\    .back { font-size:13px; color:var(--muted); transition:color 0.15s; }
    \\    .back:hover { color:var(--text); }
    \\    .badge {
    \\      font-size:11px; color:var(--muted); background:var(--bg2);
    \\      border:1px solid var(--border); border-radius:100px;
    \\      padding:4px 12px; letter-spacing:0.04em;
    \\    }
    \\  </style>
    \\</head>
    \\<body>
    \\<div class="wrap">
    \\  <div class="wordmark">mer<span>js</span></div>
    \\  <div>
    \\    <h1>Counter</h1>
    \\    <p class="sub" style="margin-top:8px">State lives in Zig/WASM. JS just applies patches.</p>
    \\  </div>
    \\  <div class="count" id="count-value">0</div>
    \\  <div class="buttons">
    \\    <button id="btn-dec"   class="btn">−</button>
    \\    <button id="btn-reset" class="btn btn-reset">reset</button>
    \\    <button id="btn-inc"   class="btn btn-inc">+</button>
    \\  </div>
    \\  <span class="badge">wasm32-freestanding</span>
    \\  <a href="/" class="back">← home</a>
    \\</div>
    \\<script>
    \\(async function(){
    \\  const display = document.getElementById('count-value');
    \\  let count = 0;
    \\  function sync(){ display.textContent = count; }
    \\  try {
    \\    const {instance} = await WebAssembly.instantiateStreaming(fetch('/counter.wasm'),{});
    \\    const w = instance.exports;
    \\    document.getElementById('btn-inc').onclick = ()=>{ w.increment(); display.textContent = w.get_count(); };
    \\    document.getElementById('btn-dec').onclick = ()=>{ w.decrement(); display.textContent = w.get_count(); };
    \\    document.getElementById('btn-reset').onclick = ()=>{ w.reset(); display.textContent = w.get_count(); };
    \\    display.textContent = w.get_count();
    \\  } catch(e) {
    \\    document.getElementById('btn-inc').onclick = ()=>{ count++; sync(); };
    \\    document.getElementById('btn-dec').onclick = ()=>{ count--; sync(); };
    \\    document.getElementById('btn-reset').onclick = ()=>{ count=0; sync(); };
    \\  }
    \\})();
    \\</script>
    \\</body>
    \\</html>
;
