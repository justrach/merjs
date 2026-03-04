const std = @import("std");
const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "Dashboard",
    .description = "SSR dashboard with live API polling. Server-side rendered at request time, client polls /api/time every second.",
    .og_title = "Dashboard \u{2014} merjs",
    .og_description = "SSR + live API polling. Rendered by Zig, zero Node.js.",
    .twitter_card = "summary",
    .twitter_title = "Dashboard \u{2014} merjs",
    .twitter_description = "SSR dashboard with live API polling.",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

const html_top =
    \\<h1>Dashboard</h1>
    \\<!-- SSR card -->
    \\<div class="card">
    \\  <div class="card-label">
    \\    <span class="dot dot-red"></span>
    \\    Server-side rendered
    \\  </div>
    \\  <div class="grid2">
    \\    <div class="stat">
    \\      <div class="stat-label">framework</div>
    \\      <div class="stat-value red">zig</div>
    \\    </div>
    \\    <div class="stat">
    \\      <div class="stat-label">node_modules</div>
    \\      <div class="stat-value red">0</div>
    \\    </div>
    \\    <div class="stat" style="grid-column:1/-1">
    \\      <div class="stat-label">rendered at (unix)</div>
    \\      <div class="stat-value big" id="ssr-ts">
;

const html_bottom =
    \\      </div>
    \\    </div>
    \\    <div class="stat">
    \\      <div class="stat-label">human time</div>
    \\      <div class="stat-value red" id="ssr-human">&mdash;</div>
    \\    </div>
    \\    <div class="stat">
    \\      <div class="stat-label">iso string</div>
    \\      <div class="stat-value" id="ssr-iso" style="font-size:12px">&mdash;</div>
    \\    </div>
    \\  </div>
    \\</div>
    \\<!-- Live card -->
    \\<div class="card">
    \\  <div class="card-label">
    \\    <span class="dot dot-pulse"></span>
    \\    Live &mdash; /api/time
    \\  </div>
    \\  <div class="grid2">
    \\    <div class="stat" style="grid-column:1/-1">
    \\      <div class="stat-label">current unix timestamp</div>
    \\      <div class="stat-value big" id="live-ts">&mdash;</div>
    \\    </div>
    \\    <div class="stat">
    \\      <div class="stat-label">human time</div>
    \\      <div class="stat-value red" id="live-human">&mdash;</div>
    \\    </div>
    \\    <div class="stat">
    \\      <div class="stat-label">iso string</div>
    \\      <div class="stat-value" id="live-iso" style="font-size:12px">&mdash;</div>
    \\    </div>
    \\  </div>
    \\</div>
    \\<p class="footer-note">
    \\  Top card baked by Zig at request time &middot;
    \\  bottom polls <code>/api/time</code> every second
    \\</p>
    \\<script>
    \\  async function tick() {
    \\    const d = await fetch('/api/time').then(r => r.json());
    \\    document.getElementById('live-ts').textContent = d.timestamp;
    \\    document.getElementById('live-human').textContent = new Date(d.timestamp * 1000).toLocaleTimeString();
    \\    document.getElementById('live-iso').textContent = d.iso;
    \\  }
    \\  tick(); setInterval(tick, 1000);
    \\  const ssrTs = parseInt(document.getElementById('ssr-ts').textContent, 10);
    \\  if (ssrTs > 0) {
    \\    const d = new Date(ssrTs * 1000);
    \\    document.getElementById('ssr-human').textContent = d.toLocaleTimeString();
    \\    document.getElementById('ssr-iso').textContent = d.toISOString();
    \\  }
    \\</script>
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

const page_css =
    \\h1 { font-family:'DM Serif Display',Georgia,serif; font-size:32px; letter-spacing:-0.02em; margin-bottom:32px; }
    \\.card {
    \\  background:var(--bg2); border:1px solid var(--border);
    \\  border-radius:12px; padding:24px; margin-bottom:16px;
    \\}
    \\.card-label {
    \\  display:flex; align-items:center; gap:8px;
    \\  font-size:11px; color:var(--muted);
    \\  text-transform:uppercase; letter-spacing:0.08em; margin-bottom:20px;
    \\}
    \\.dot { width:7px; height:7px; border-radius:50%; background:var(--muted); flex-shrink:0; }
    \\.dot-red { background:var(--red); }
    \\.dot-pulse { background:var(--red); animation:pulse 2s infinite; }
    \\@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }
    \\.grid2 { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
    \\.stat { background:var(--bg3); border-radius:8px; padding:16px; }
    \\.stat-label { font-size:11px; color:var(--muted); margin-bottom:6px; }
    \\.stat-value { font-family:'SF Mono','Fira Code',monospace; font-size:15px; color:var(--text); }
    \\.stat-value.red { color:var(--red); }
    \\.stat-value.big { font-size:28px; }
    \\.footer-note { font-size:12px; color:var(--muted); text-align:center; margin-top:24px; }
    \\.footer-note code { font-family:'SF Mono',monospace; font-size:11px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
;
