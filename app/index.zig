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
    \\  <title>merjs — A Zig-native web framework</title>
    \\  <meta name="description" content="A Next.js competitor written in Zig. Zero Node.js, zero node_modules. SSR, file-based routing, type-safe APIs, and WASM for client interactivity.">
    \\  <meta property="og:type" content="website">
    \\  <meta property="og:site_name" content="merjs">
    \\  <meta property="og:title" content="merjs — A Zig-native web framework. No Node. No npm. Just WASM.">
    \\  <meta property="og:description" content="A Next.js competitor written in Zig. Zero Node.js, zero node_modules. SSR, file-based routing, type-safe APIs, and WASM for client interactivity.">
    \\  <meta property="og:url" content="https://merlionjs.com">
    \\  <meta name="twitter:card" content="summary_large_image">
    \\  <meta name="twitter:title" content="merjs — A Zig-native web framework">
    \\  <meta name="twitter:description" content="Zero Node.js. Zero node_modules. Pure Zig all the way down.">
    \\  <link rel="preconnect" href="https://fonts.googleapis.com">
    \\  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    \\  <link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet">
    \\  <style>
    \\    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    \\    :root {
    \\      --bg:     #f0ebe3;
    \\      --bg2:    #e8e2d9;
    \\      --bg3:    #ddd5cc;
    \\      --text:   #252530;
    \\      --muted:  #8a7f78;
    \\      --border: #d5cdc4;
    \\      --red:    #e8251f;
    \\    }
    \\    html { scroll-behavior: smooth; }
    \\    body {
    \\      background: var(--bg);
    \\      color: var(--text);
    \\      font-family: 'DM Sans', system-ui, sans-serif;
    \\      min-height: 100vh;
    \\      line-height: 1.6;
    \\      overflow-x: hidden;
    \\      -webkit-text-size-adjust: 100%;
    \\    }
    \\    a { color: inherit; text-decoration: none; }
    \\    .page { max-width: 800px; margin: 0 auto; padding: 56px 40px 120px; }
    \\    .header {
    \\      display: flex; align-items: center; justify-content: space-between;
    \\      margin-bottom: 88px; flex-wrap: wrap; gap: 16px;
    \\    }
    \\    .wordmark {
    \\      font-family: 'DM Serif Display', Georgia, serif;
    \\      font-size: 20px; letter-spacing: -0.02em;
    \\      color: var(--text);
    \\    }
    \\    .wordmark span { color: var(--red); }
    \\    .nav { display: flex; gap: 16px; flex-wrap: wrap; }
    \\    .nav a { font-size: 13px; color: var(--muted); transition: color 0.15s; }
    \\    .nav a:hover { color: var(--text); }
    \\    .lede {
    \\      font-family: 'DM Serif Display', Georgia, serif;
    \\      font-size: clamp(36px, 5vw, 58px);
    \\      line-height: 1.08;
    \\      letter-spacing: -0.03em;
    \\      color: var(--text);
    \\      margin-bottom: 56px;
    \\    }
    \\    .lede .red { color: var(--red); }
    \\    .lede em { font-style: italic; }
    \\    .rule { border: none; border-top: 1px solid var(--border); margin: 48px 0; }
    \\    .items { display: flex; flex-direction: column; }
    \\    .item {
    \\      display: grid;
    \\      grid-template-columns: 40px 1fr;
    \\      gap: 16px;
    \\      padding: 36px 0;
    \\      border-bottom: 1px solid var(--border);
    \\    }
    \\    .item:first-child { border-top: 1px solid var(--border); }
    \\    .item-num { font-size: 11px; color: var(--red); font-weight: 600; letter-spacing: 0.08em; padding-top: 6px; }
    \\    .item-heading {
    \\      font-family: 'DM Serif Display', Georgia, serif;
    \\      font-size: clamp(20px, 2.6vw, 28px);
    \\      line-height: 1.15; letter-spacing: -0.02em;
    \\      color: var(--text); margin-bottom: 12px;
    \\    }
    \\    .item-heading .red { color: var(--red); }
    \\    .item-heading em { font-style: italic; }
    \\    .item-text { font-size: 15px; color: var(--muted); line-height: 1.75; max-width: 580px; }
    \\    .item-text strong { color: var(--text); font-weight: 500; }
    \\    .item-text code {
    \\      font-family: 'SF Mono', 'Fira Code', monospace;
    \\      font-size: 13px; background: var(--bg3);
    \\      border-radius: 4px; padding: 1px 6px; color: var(--text);
    \\    }
    \\    .bench { margin-top: 0; }
    \\    .bench-title {
    \\      font-family: 'DM Serif Display', Georgia, serif;
    \\      font-size: clamp(22px, 3vw, 32px);
    \\      letter-spacing: -0.02em; color: var(--text); margin-bottom: 8px;
    \\    }
    \\    .bench-title .red { color: var(--red); }
    \\    .bench-sub { font-size: 13px; color: var(--muted); margin-bottom: 32px; line-height: 1.5; }
    \\    .bench-legend { display: flex; gap: 20px; margin-bottom: 24px; }
    \\    .bench-legend-item { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }
    \\    .bench-legend-dot { width: 10px; height: 10px; border-radius: 2px; }
    \\    .bench-legend-dot.mer { background: var(--red); }
    \\    .bench-legend-dot.next { background: var(--border); }
    \\    .bench-row { margin-bottom: 28px; }
    \\    .bench-label { font-size: 12px; font-weight: 600; color: var(--text); letter-spacing: 0.04em; text-transform: uppercase; margin-bottom: 10px; }
    \\    .bench-bars { display: flex; flex-direction: column; gap: 6px; }
    \\    .bench-bar-wrap { display: flex; align-items: center; gap: 10px; }
    \\    .bench-bar {
    \\      height: 32px; border-radius: 4px;
    \\      display: flex; align-items: center; padding: 0 12px;
    \\      font-size: 12px; font-weight: 600; color: #fff;
    \\      white-space: nowrap; min-width: max-content;
    \\    }
    \\    .bench-bar.mer { background: var(--red); }
    \\    .bench-bar.next { background: var(--border); color: var(--muted); }
    \\    .bench-bar-tag { font-size: 11px; color: var(--muted); white-space: nowrap; flex-shrink: 0; min-width: 40px; }
    \\    .bench-note { font-size: 11px; color: var(--muted); margin-top: 32px; line-height: 1.6; font-style: italic; }
    \\    .footer { margin-top: 72px; display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    \\    .btn-primary {
    \\      display: inline-flex; align-items: center;
    \\      background: var(--red); color: var(--bg);
    \\      font-size: 14px; font-weight: 600;
    \\      padding: 12px 26px; border-radius: 6px;
    \\      transition: opacity 0.15s;
    \\    }
    \\    .btn-primary:hover { opacity: 0.88; }
    \\    .btn-ghost {
    \\      display: inline-flex; align-items: center;
    \\      color: var(--muted); font-size: 14px;
    \\      border: 1px solid var(--border);
    \\      padding: 12px 26px; border-radius: 6px;
    \\      transition: color 0.15s, border-color 0.15s;
    \\    }
    \\    .btn-ghost:hover { color: var(--text); border-color: var(--text); }
    \\    .footer-note { width: 100%; margin-top: 28px; font-size: 12px; color: var(--muted); }
    \\    .footer-note a { border-bottom: 1px solid var(--border); padding-bottom: 1px; }
    \\    .footer-note a:hover { color: var(--text); }
    \\    @media (max-width: 600px) {
    \\      .page { padding: 24px 16px 64px; }
    \\      .header { margin-bottom: 40px; flex-direction: column; align-items: flex-start; gap: 12px; }
    \\      .nav { gap: 14px; }
    \\      .nav a { font-size: 14px; }
    \\      .lede { font-size: 28px; margin-bottom: 32px; }
    \\      .lede br { display: none; }
    \\      .rule { margin: 28px 0; }
    \\      .item { grid-template-columns: 1fr; gap: 8px; padding: 20px 0; }
    \\      .item-num { padding-top: 0; }
    \\      .item-heading { font-size: 18px; }
    \\      .item-text { font-size: 14px; max-width: 100%; }
    \\      .footer { flex-direction: column; align-items: stretch; gap: 10px; margin-top: 40px; }
    \\      .btn-primary, .btn-ghost { justify-content: center; text-align: center; padding: 14px 20px; }
    \\      .footer-note { text-align: center; }
    \\      .bench-legend { gap: 14px; }
    \\      .bench-bar { height: 24px; font-size: 11px; }
    \\      .bench-row { margin-bottom: 22px; }
    \\    }
    \\  </style>
    \\</head>
    \\<body>
    \\<div class="page">
    \\  <header class="header">
    \\    <div class="wordmark">mer<span>js</span></div>
    \\    <nav class="nav">
    \\      <a href="/dashboard">Dashboard</a>
    \\      <a href="/weather">Weather</a>
    \\      <a href="/users">Users</a>
    \\      <a href="/counter">Counter</a>
    \\      <a href="/about">About</a>
    \\    </nav>
    \\  </header>
    \\  <h1 class="lede">
    \\    The web doesn't need<br>
    \\    <em>another</em> JavaScript<br>
    \\    framework. It needs<br>
    \\    <span class="red">no runtime at all.</span>
    \\  </h1>
    \\  <div class="bench">
    \\    <div class="bench-title">vs Next.js — <span class="red">at a glance</span></div>
    \\    <p class="bench-sub">Head-to-head on the metrics that matter.</p>
    \\    <div class="bench-legend">
    \\      <div class="bench-legend-item"><div class="bench-legend-dot mer"></div> merjs</div>
    \\      <div class="bench-legend-item"><div class="bench-legend-dot next"></div> Next.js</div>
    \\    </div>
    \\    <div class="bench-row">
    \\      <div class="bench-label">Cold Start</div>
    \\      <div class="bench-bars">
    \\        <div class="bench-bar-wrap">
    \\          <div class="bench-bar mer" style="width: 8%;">< 5 ms</div>
    \\          <div class="bench-bar-tag">merjs</div>
    \\        </div>
    \\        <div class="bench-bar-wrap">
    \\          <div class="bench-bar next" style="width: 80%;">~1-3 s</div>
    \\          <div class="bench-bar-tag">Next.js</div>
    \\        </div>
    \\      </div>
    \\    </div>
    \\    <div class="bench-row">
    \\      <div class="bench-label">Requests / sec</div>
    \\      <div class="bench-bars">
    \\        <div class="bench-bar-wrap">
    \\          <div class="bench-bar mer" style="width: 90%;">2446.97 req/s</div>
    \\          <div class="bench-bar-tag">merjs</div>
    \\        </div>
    \\        <div class="bench-bar-wrap">
    \\          <div class="bench-bar next" style="width: 67%;">1842.68 req/s</div>
    \\          <div class="bench-bar-tag">Next.js</div>
    \\        </div>
    \\      </div>
    \\    </div>
    \\    <div class="bench-row">
    \\      <div class="bench-label">Avg Latency</div>
    \\      <div class="bench-bars">
    \\        <div class="bench-bar-wrap">
    \\          <div class="bench-bar mer" style="width: 42%;">40.65 ms</div>
    \\          <div class="bench-bar-tag">merjs</div>
    \\        </div>
    \\        <div class="bench-bar-wrap">
    \\          <div class="bench-bar next" style="width: 80%;">76.04 ms</div>
    \\          <div class="bench-bar-tag">Next.js</div>
    \\        </div>
    \\      </div>
    \\    </div>
    \\    <div class="bench-row">
    \\      <div class="bench-label">Build Time</div>
    \\      <div class="bench-bars">
    \\        <div class="bench-bar-wrap">
    \\          <div class="bench-bar mer" style="width: 8%;">~1.7 s</div>
    \\          <div class="bench-bar-tag">merjs</div>
    \\        </div>
    \\        <div class="bench-bar-wrap">
    \\          <div class="bench-bar next" style="width: 80%;">~43 s</div>
    \\          <div class="bench-bar-tag">Next.js</div>
    \\        </div>
    \\      </div>
    \\    </div>
    \\    <div class="bench-row">
    \\      <div class="bench-label">node_modules</div>
    \\      <div class="bench-bars">
    \\        <div class="bench-bar-wrap">
    \\          <div class="bench-bar mer" style="width: 8%;">0 files</div>
    \\          <div class="bench-bar-tag">merjs</div>
    \\        </div>
    \\        <div class="bench-bar-wrap">
    \\          <div class="bench-bar next" style="width: 85%;">~300 MB / 85k files</div>
    \\          <div class="bench-bar-tag">Next.js</div>
    \\        </div>
    \\      </div>
    \\    </div>
    \\    <p class="bench-note">
    \\      Next.js is a mature, production-grade framework — merjs is an early
    \\      experiment exploring whether the same DX is possible without the runtime weight.
    \\      Benchmarks auto-updated by CI on each push to main.
    \\    </p>
    \\  </div>
    \\  <hr class="rule">
    \\  <div class="items">
    \\    <div class="item">
    \\      <div class="item-num">01</div>
    \\      <div class="item-body">
    \\        <div class="item-heading">Node.js solved the wrong problem.</div>
    \\        <p class="item-text">
    \\          It unified the language, not the stack. You still ship a 400MB runtime
    \\          to run a <code>hello world</code>. You still wait 30 seconds for
    \\          <strong>npm install</strong>. You still debug dependency conflicts
    \\          that have nothing to do with your product. The problem was never
    \\          "which language" — it was "why do we need a runtime at all."
    \\        </p>
    \\      </div>
    \\    </div>
    \\    <div class="item">
    \\      <div class="item-num">02</div>
    \\      <div class="item-body">
    \\        <div class="item-heading"><span class="red">WASM</span> closes the last gap.</div>
    \\        <p class="item-text">
    \\          The real reason JS won the server: it already ran in the browser.
    \\          That moat is gone. WebAssembly is a compile target for <em>any</em> language.
    \\          Zig compiles to <code>wasm32-freestanding</code> in a single step.
    \\          Write client logic in Zig, compile to <strong>.wasm</strong>,
    \\          ship it directly. No transpiler. No bundler. The browser runs it natively.
    \\        </p>
    \\      </div>
    \\    </div>
    \\    <div class="item">
    \\      <div class="item-num">03</div>
    \\      <div class="item-body">
    \\        <div class="item-heading">One language. <em>Two targets.</em></div>
    \\        <p class="item-text">
    \\          The server compiles to a <strong>native binary</strong>.
    \\          The client compiles to <strong>.wasm</strong>.
    \\          File-based routing, SSR, type-safe APIs, hot reload — everything
    \\          Next.js does, in Zig. Zero node_modules. A single <code>zig build serve</code>.
    \\        </p>
    \\      </div>
    \\    </div>
    \\    <div class="item">
    \\      <div class="item-num">04</div>
    \\      <div class="item-body">
    \\        <div class="item-heading">Type safety without a <span class="red">build step.</span></div>
    \\        <p class="item-text">
    \\          Validation constraints are comptime. API schemas are Zig structs.
    \\          JSON serialization is <code>std.json</code>. No codegen. No schema files.
    \\          No runtime overhead. The compiler catches it, or it doesn't compile.
    \\        </p>
    \\      </div>
    \\    </div>
    \\    <div class="item">
    \\      <div class="item-num">05</div>
    \\      <div class="item-body">
    \\        <div class="item-heading">This is <em>early proof.</em></div>
    \\        <p class="item-text">
    \\          merjs is a bet — that systems languages, WASM, and file-based routing
    \\          can meet in one place and produce something better than what we have today.
    \\          The node_modules folder had a good run.
    \\          <strong>It's time to move on.</strong>
    \\        </p>
    \\      </div>
    \\    </div>
    \\  </div>
    \\  <div class="footer">
    \\    <a href="/dashboard" class="btn-primary">See it in action</a>
    \\    <a href="/about"     class="btn-ghost">Read the philosophy</a>
    \\    <p class="footer-note">
    \\      Built in <a href="https://ziglang.org">Zig 0.15</a> &middot;
    \\      Validation by <a href="https://github.com/justrach/dhi">dhi</a> &middot;
    \\      Zero node_modules
    \\    </p>
    \\  </div>
    \\</div>
    \\</body>
    \\</html>
;
