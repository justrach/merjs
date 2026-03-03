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
    \\  <title>About — merjs</title>
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
    \\    h1 { font-family:'DM Serif Display',Georgia,serif; font-size:38px; letter-spacing:-0.02em; line-height:1.1; margin-bottom:40px; }
    \\    h2 { font-family:'DM Serif Display',Georgia,serif; font-size:22px; letter-spacing:-0.01em; color:var(--text); margin:40px 0 14px; }
    \\    p { font-size:15px; color:var(--muted); line-height:1.75; margin-bottom:16px; }
    \\    p strong { color:var(--text); font-weight:500; }
    \\    code { font-family:'SF Mono','Fira Code',monospace; font-size:13px; background:var(--bg3); border-radius:4px; padding:1px 6px; color:var(--text); }
    \\    .rule { border:none; border-top:1px solid var(--border); margin:40px 0; }
    \\    .stack { display:flex; flex-direction:column; gap:12px; margin:16px 0; }
    \\    .stack-item {
    \\      display:flex; align-items:center; gap:16px;
    \\      background:var(--bg2); border:1px solid var(--border);
    \\      border-radius:8px; padding:14px 16px;
    \\    }
    \\    .stack-num { font-size:11px; color:var(--red); font-weight:600; letter-spacing:0.06em; width:20px; flex-shrink:0; }
    \\    .stack-text { font-size:14px; color:var(--text); }
    \\    .stack-text span { color:var(--muted); font-size:13px; }
    \\    .links { display:flex; gap:12px; margin-top:40px; flex-wrap:wrap; }
    \\    .btn { display:inline-flex; align-items:center; font-size:14px; font-weight:500; padding:11px 22px; border-radius:6px; transition:opacity 0.15s; }
    \\    .btn-red { background:var(--red); color:var(--bg); }
    \\    .btn-red:hover { opacity:0.88; }
    \\    .btn-outline { border:1px solid var(--border); color:var(--muted); }
    \\    .btn-outline:hover { color:var(--text); border-color:var(--text); }
    \\  </style>
    \\</head>
    \\<body>
    \\<div class="page">
    \\  <header class="header">
    \\    <div class="wordmark">mer<span>js</span></div>
    \\    <a href="/" class="back">← home</a>
    \\  </header>
    \\  <h1>Philosophy</h1>
    \\  <p>
    \\    merjs is a bet that the web framework space has been solving the wrong problem.
    \\    The question was never "which language should run on the server."
    \\    It was: <strong>why do we need a runtime at all?</strong>
    \\  </p>
    \\  <p>
    \\    Node.js unified the language across client and server, and that was genuinely useful.
    \\    But it came with a cost — a sprawling runtime, tens of thousands of dependencies,
    \\    cold starts measured in seconds, and build pipelines that have become entire careers.
    \\  </p>
    \\  <hr class="rule">
    \\  <h2>The WASM argument</h2>
    \\  <p>
    \\    The original justification for JS on the server was simple: it already ran in the browser.
    \\    WebAssembly makes that argument obsolete. Any language that compiles to WASM can now
    \\    ship logic to the browser. Zig does this in a single build step — <code>wasm32-freestanding</code>,
    \\    no emscripten, no glue code. The browser runs it natively.
    \\  </p>
    \\  <p>
    \\    So now you can write your <strong>server</strong> in Zig (native binary, microsecond cold start),
    \\    write your <strong>client logic</strong> in Zig (compiled to .wasm, shipped directly),
    \\    and skip the JavaScript runtime entirely for anything that doesn't need it.
    \\  </p>
    \\  <hr class="rule">
    \\  <h2>What merjs does</h2>
    \\  <div class="stack">
    \\    <div class="stack-item">
    \\      <div class="stack-num">01</div>
    \\      <div class="stack-text">File-based routing <span>— drop a .zig file, get a route</span></div>
    \\    </div>
    \\    <div class="stack-item">
    \\      <div class="stack-num">02</div>
    \\      <div class="stack-text">Server-side rendering <span>— render() runs at request time</span></div>
    \\    </div>
    \\    <div class="stack-item">
    \\      <div class="stack-num">03</div>
    \\      <div class="stack-text">Type-safe APIs via dhi <span>— comptime validation, std.json output</span></div>
    \\    </div>
    \\    <div class="stack-item">
    \\      <div class="stack-num">04</div>
    \\      <div class="stack-text">WASM client logic <span>— interactive state without a JS framework</span></div>
    \\    </div>
    \\    <div class="stack-item">
    \\      <div class="stack-num">05</div>
    \\      <div class="stack-text">Hot reload <span>— SSE + file watcher, no daemon required</span></div>
    \\    </div>
    \\  </div>
    \\  <div class="links">
    \\    <a href="/dashboard" class="btn btn-red">See the dashboard</a>
    \\    <a href="/users"     class="btn btn-outline">Users + dhi</a>
    \\    <a href="/counter"   class="btn btn-outline">Counter (WASM)</a>
    \\  </div>
    \\</div>
    \\</body>
    \\</html>
;
