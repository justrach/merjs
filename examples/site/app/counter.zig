const std = @import("std");
const mer = @import("mer");
const h = mer.h;
const cfg = @import("counter_config").config;

pub const meta: mer.Meta = .{
    .title = "Counter",
    .description = "Interactive WASM counter. State lives in Zig, compiled to wasm32-freestanding. JS just applies patches.",
    .og_title = "WASM Counter \u{2014} merjs",
    .og_description = "State lives in Zig/WASM. JS just applies patches. Zero bundlers.",
    .twitter_card = "summary",
    .twitter_title = "WASM Counter \u{2014} merjs",
    .twitter_description = "Interactive counter with state in Zig WASM.",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

const page_node = page();
comptime {
    mer.lint.check(page_node);
}

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn page() h.Node {
    return h.div(.{ .class = "wrap" }, .{
        h.a(.{ .href = "/", .class = "wordmark" }, .{h.raw("mer<span>js</span>")}),
        h.div(.{}, .{
            h.h1(.{}, "Counter"),
            h.p(.{ .class = "sub", .style = "margin-top:8px" }, "State lives in Zig/WASM. JS just applies patches."),
        }),
        h.div(.{ .class = "count", .id = "count-value" }, comptimeIntStr(cfg.initial)),
        h.div(.{ .class = "bounds" }, .{
            h.span(.{ .class = "bound" }, .{h.raw("min: <strong>" ++ comptimeIntStr(cfg.min) ++ "</strong>")}),
            h.span(.{ .class = "bound-sep" }, .{h.raw("&middot;")}),
            h.span(.{ .class = "bound" }, .{h.raw("step: <strong>" ++ comptimeIntStr(cfg.step) ++ "</strong>")}),
            h.span(.{ .class = "bound-sep" }, .{h.raw("&middot;")}),
            h.span(.{ .class = "bound" }, .{h.raw("max: <strong>" ++ comptimeIntStr(cfg.max) ++ "</strong>")}),
        }),
        h.div(.{ .class = "buttons" }, .{
            h.button(.{ .id = "btn-dec", .class = "btn", .type = "button" }, .{h.raw("&minus;")}),
            h.button(.{ .id = "btn-reset", .class = "btn btn-reset", .type = "button" }, "reset"),
            h.button(.{ .id = "btn-inc", .class = "btn btn-inc", .type = "button" }, "+"),
        }),
        h.div(.{ .class = "runtime" }, .{
            h.span(.{ .class = "badge" }, "wasm32-freestanding"),
            h.span(.{ .id = "runtime-status", .class = "runtime-status runtime-pending" }, "Checking WASM..."),
        }),
        h.p(.{ .id = "runtime-note", .class = "runtime-note", .hidden = true }, ""),
        h.div(.{ .class = "config-note" }, .{
            h.raw("Bounds enforced at <strong>comptime</strong> via "),
            h.code(.{}, "counter_config.zig"),
            h.raw(" &mdash; change the values and the compiler validates them."),
        }),
        h.a(.{ .href = "/", .class = "back" }, .{h.raw("&larr; home")}),
        h.script(.{}, counter_js),
    });
}

fn comptimeIntStr(comptime val: i32) []const u8 {
    return std.fmt.comptimePrint("{d}", .{val});
}

const counter_js =
    \\(async function(){
    \\  const display = document.getElementById('count-value');
    \\  const status = document.getElementById('runtime-status');
    \\  const note = document.getElementById('runtime-note');
++ std.fmt.comptimePrint(
    \\  const MIN={d}, MAX={d}, STEP={d}, INIT={d};
, .{ cfg.min, cfg.max, cfg.step, cfg.initial }) ++
    \\  let count = INIT;
    \\  function clamp(v){ return Math.max(MIN, Math.min(MAX, v)); }
    \\  function sync(){ display.textContent = count; }
    \\  function setMode(label, cls, message){
    \\    status.textContent = label;
    \\    status.className = 'runtime-status ' + cls;
    \\    if(message){
    \\      note.hidden = false;
    \\      note.textContent = message;
    \\    } else {
    \\      note.hidden = true;
    \\      note.textContent = '';
    \\    }
    \\  }
    \\  try {
    \\    const {instance} = await WebAssembly.instantiateStreaming(fetch('/counter.wasm'),{});
    \\    const w = instance.exports;
    \\    document.getElementById('btn-inc').onclick = ()=>{ w.increment(); display.textContent = w.get_count(); };
    \\    document.getElementById('btn-dec').onclick = ()=>{ w.decrement(); display.textContent = w.get_count(); };
    \\    document.getElementById('btn-reset').onclick = ()=>{ w.reset(); display.textContent = w.get_count(); };
    \\    display.textContent = w.get_count();
    \\    setMode('WASM active', 'runtime-ok', '');
    \\  } catch(e) {
    \\    document.getElementById('btn-inc').onclick = ()=>{ count = clamp(count + STEP); sync(); };
    \\    document.getElementById('btn-dec').onclick = ()=>{ count = clamp(count - STEP); sync(); };
    \\    document.getElementById('btn-reset').onclick = ()=>{ count = INIT; sync(); };
    \\    sync();
    \\    const reason = (e && e.message) ? e.message : 'WASM failed to initialize.';
    \\    setMode('JS fallback', 'runtime-fallback', reason);
    \\    console.warn('counter.wasm fallback:', e);
    \\  }
    \\})();
;

const page_css =
    \\.wrap {
    \\  display:flex; flex-direction:column; align-items:center;
    \\  gap:32px; text-align:center; padding:40px 24px;
    \\}
    \\.wordmark {
    \\  font-family:'DM Serif Display',Georgia,serif;
    \\  font-size:18px; letter-spacing:-0.02em;
    \\}
    \\.wordmark span { color:var(--red); }
    \\h1 {
    \\  font-family:'DM Serif Display',Georgia,serif;
    \\  font-size:28px; letter-spacing:-0.02em;
    \\}
    \\.sub { font-size:13px; color:var(--muted); max-width:280px; }
    \\.count {
    \\  font-family:'SF Mono','Fira Code',monospace;
    \\  font-size:96px; font-weight:700; line-height:1;
    \\  color:var(--text); letter-spacing:-0.04em;
    \\  min-width:3ch; text-align:center;
    \\}
    \\.bounds {
    \\  display:flex; gap:12px; align-items:center;
    \\  font-size:12px; color:var(--muted);
    \\}
    \\.bounds strong { color:var(--text); font-weight:600; }
    \\.bound-sep { color:var(--border); }
    \\.buttons { display:flex; gap:12px; align-items:center; }
    \\.btn {
    \\  width:52px; height:52px; border-radius:8px;
    \\  border:1px solid var(--border); background:var(--bg2);
    \\  font-size:24px; font-weight:500; color:var(--text);
    \\  cursor:pointer; transition:background 0.12s, border-color 0.12s;
    \\  display:flex; align-items:center; justify-content:center;
    \\}
    \\.btn:hover { background:var(--bg3); border-color:var(--text); }
    \\.btn-inc {
    \\  background:var(--red); border-color:var(--red); color:var(--bg);
    \\}
    \\.btn-inc:hover { opacity:0.88; }
    \\.btn-reset {
    \\  width:auto; padding:0 18px; font-size:13px; font-weight:500;
    \\  color:var(--muted); font-family:'DM Sans',sans-serif;
    \\}
    \\.back { font-size:13px; color:var(--muted); transition:color 0.15s; }
    \\.back:hover { color:var(--text); }
    \\.badge {
    \\  font-size:11px; color:var(--muted); background:var(--bg2);
    \\  border:1px solid var(--border); border-radius:100px;
    \\  padding:4px 12px; letter-spacing:0.04em;
    \\}
    \\.runtime {
    \\  display:flex; align-items:center; gap:10px; flex-wrap:wrap; justify-content:center;
    \\}
    \\.runtime-status {
    \\  font-size:11px; border-radius:100px; padding:4px 12px; letter-spacing:0.04em;
    \\  border:1px solid var(--border);
    \\}
    \\.runtime-pending { color:var(--muted); background:var(--bg2); }
    \\.runtime-ok { color:#17603a; background:#e5f5ea; border-color:#b6ddc4; }
    \\.runtime-fallback { color:#8a3e12; background:#fff1e6; border-color:#f0c5a6; }
    \\.runtime-note {
    \\  max-width:420px; font-size:12px; line-height:1.5; color:var(--muted);
    \\}
    \\.config-note {
    \\  font-size:12px; color:var(--muted); max-width:360px; line-height:1.6;
    \\}
    \\.config-note strong { color:var(--text); }
    \\.config-note code {
    \\  font-family:'SF Mono','Fira Code',monospace;
    \\  font-size:11px; background:var(--bg3);
    \\  border-radius:4px; padding:1px 6px;
    \\}
;
