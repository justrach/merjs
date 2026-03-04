const mer = @import("mer");
const h = mer.h;

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
        h.div(.{ .class = "count", .id = "count-value" }, "0"),
        h.div(.{ .class = "buttons" }, .{
            h.button(.{ .id = "btn-dec", .class = "btn", .@"type" = "button" }, .{h.raw("&minus;")}),
            h.button(.{ .id = "btn-reset", .class = "btn btn-reset", .@"type" = "button" }, "reset"),
            h.button(.{ .id = "btn-inc", .class = "btn btn-inc", .@"type" = "button" }, "+"),
        }),
        h.span(.{ .class = "badge" }, "wasm32-freestanding"),
        h.a(.{ .href = "/", .class = "back" }, .{h.raw("&larr; home")}),
        h.script(.{}, counter_js),
    });
}

const counter_js =
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
;
