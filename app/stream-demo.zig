const std = @import("std");
const mer = @import("mer");

pub const meta: mer.Meta = .{
    .title = "Streaming SSR Demo",
    .description = "Watch data resolve in real time — true streaming server-side rendering in Zig.",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html("<h1>Streaming Demo</h1><p>Requires the dev server.</p>");
}

pub fn renderStream(req: mer.Request, stream: *mer.StreamWriter) void {
    const alloc = req.allocator;

    // ── Shell: renders instantly ────────────────────────────────────
    stream.write(
        \\<div class="demo">
        \\  <h1 class="demo-title">Streaming SSR <span class="red">Demo</span></h1>
        \\  <p class="demo-sub">Each card below is a Suspense boundary. The shell you see arrived <em>before</em> any data was fetched. Watch the skeletons resolve.</p>
        \\  <div class="cards">
    );

    // ── Placeholders with skeleton fallbacks ────────────────────────
    stream.placeholder("singapore",
        \\<div class="card skeleton"><div class="card-head"><div class="skel-dot"></div><div class="skel-line"></div></div><div class="skel-big"></div><div class="skel-line short"></div></div>
    );
    stream.placeholder("tokyo",
        \\<div class="card skeleton"><div class="card-head"><div class="skel-dot"></div><div class="skel-line"></div></div><div class="skel-big"></div><div class="skel-line short"></div></div>
    );
    stream.placeholder("london",
        \\<div class="card skeleton"><div class="card-head"><div class="skel-dot"></div><div class="skel-line"></div></div><div class="skel-big"></div><div class="skel-line short"></div></div>
    );

    stream.write("</div>");

    // Loading indicator — visible while fetching, removed when all cards resolve.
    stream.write(
        \\<div class="loading" id="loading-bar">
        \\  <div class="loading-dot"></div>
        \\  <span>Fetching live weather data from 3 cities...</span>
        \\</div>
    );

    // Explainer — this is already visible while data loads.
    stream.write(
        \\<div class="explainer">
        \\  <h3>How it works</h3>
        \\  <p>The server sent this entire page shell immediately via <code>transfer-encoding: chunked</code>. The skeleton cards above are real DOM elements with shimmer animations. Right now the server is fetching weather data from 3 different API endpoints in parallel. As each resolves, an inline <code>&lt;script&gt;</code> swaps the skeleton with real content. No React. No hydration. Just HTML.</p>
        \\</div>
    );

    // ── Comparison timeline — visible in shell, before any data ─────
    stream.write(
        \\<div class="compare">
        \\  <h3>Streaming vs Traditional SSR</h3>
        \\  <p class="compare-desc">Traditional SSR waits for every fetch before sending a single byte. merjs streams the shell immediately — skeletons resolve as each fetch completes.</p>
        \\  <div class="tl">
        \\    <div class="tl-label">merjs</div>
        \\    <div class="tl-track">
        \\      <div class="tl-shell">shell</div>
        \\      <div class="tl-card tl-c1">card 1</div>
        \\      <div class="tl-card tl-c2">card 2</div>
        \\      <div class="tl-card tl-c3">card 3</div>
        \\    </div>
        \\    <div class="tl-label gray">Next.js</div>
        \\    <div class="tl-track">
        \\      <div class="tl-wait">waiting for all 3 fetches...</div>
        \\      <div class="tl-full">page</div>
        \\    </div>
        \\  </div>
        \\  <div class="tl-axis"><span>0ms</span><span>200ms</span><span>400ms</span><span>600ms</span></div>
        \\  <p class="tl-note">* Timeline simulates 3 parallel 200ms API calls. Animation plays on load.</p>
        \\</div>
    );
    // ^^^ Everything above is in the browser NOW, before any fetch.

    // ── Fetch weather for 3 cities in parallel ─────────────────────
    const results = mer.fetchAll(alloc, &.{
        .{ .url = "https://api.open-meteo.com/v1/forecast?latitude=1.35&longitude=103.82&current=temperature_2m,relative_humidity_2m,wind_speed_10m&timezone=Asia/Singapore" },
        .{ .url = "https://api.open-meteo.com/v1/forecast?latitude=35.68&longitude=139.69&current=temperature_2m,relative_humidity_2m,wind_speed_10m&timezone=Asia/Tokyo" },
        .{ .url = "https://api.open-meteo.com/v1/forecast?latitude=51.51&longitude=-0.13&current=temperature_2m,relative_humidity_2m,wind_speed_10m&timezone=Europe/London" },
    });
    defer for (results) |r| if (r) |ok| ok.deinit(alloc);

    // ── Resolve each card as data arrives ───────────────────────────
    const names = [_][]const u8{ "Singapore", "Tokyo", "London" };
    const flags = [_][]const u8{ "\xf0\x9f\x87\xb8\xf0\x9f\x87\xac", "\xf0\x9f\x87\xaf\xf0\x9f\x87\xb5", "\xf0\x9f\x87\xac\xf0\x9f\x87\xa7" };
    const ids = [_][]const u8{ "singapore", "tokyo", "london" };

    for (ids, 0..) |id, i| {
        if (results[i]) |res| {
            stream.resolve(id, weatherCard(alloc, names[i], flags[i], res.body));
        } else {
            stream.resolve(id, errorCard(names[i]));
        }
    }

    // Remove loading indicator after all cards resolved.
    stream.write("<script>document.getElementById('loading-bar').remove()</script>");
    stream.write("</div>");
    stream.flush();
}

fn weatherCard(alloc: std.mem.Allocator, city: []const u8, flag: []const u8, body: []u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return errorCard(city);
    const cur = parsed.value.object.get("current") orelse return errorCard(city);
    const temp = numVal(cur.object.get("temperature_2m"));
    const humidity = numVal(cur.object.get("relative_humidity_2m"));
    const wind = numVal(cur.object.get("wind_speed_10m"));
    return std.fmt.allocPrint(
        alloc,
        "<div class=\"card\"><div class=\"card-head\"><span class=\"card-flag\">{s}</span><span class=\"card-city\">{s}</span></div><div class=\"card-temp\">{d:.0}\xc2\xb0C</div><div class=\"card-details\">Humidity {d:.0}% \xc2\xb7 Wind {d:.1} km/h</div></div>",
        .{ flag, city, temp, humidity, wind },
    ) catch errorCard(city);
}

fn errorCard(city: []const u8) []const u8 {
    _ = city;
    return "<div class=\"card card-err\"><p>Failed to load</p></div>";
}

fn numVal(v: ?std.json.Value) f64 {
    const val = v orelse return 0;
    return switch (val) {
        .float => val.float,
        .integer => @floatFromInt(val.integer),
        else => 0,
    };
}

const page_css =
    \\.demo { max-width:620px; margin:0 auto; }
    \\.demo-title { font-family:'DM Serif Display',Georgia,serif; font-size:clamp(28px,4vw,40px); letter-spacing:-0.02em; margin-bottom:8px; }
    \\.demo-title .red { color:var(--red); }
    \\.demo-sub { color:var(--muted); font-size:15px; line-height:1.6; margin-bottom:28px; }
    \\.demo-sub em { font-style:italic; color:var(--text); }
    \\.demo-sub code { font-family:'SF Mono','Fira Code',monospace; font-size:13px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
    \\.cards { display:grid; grid-template-columns:repeat(3,1fr); gap:14px; margin-bottom:32px; }
    \\.card { background:var(--bg2); border-radius:10px; padding:20px; transition:transform 0.15s; }
    \\.card:hover { transform:translateY(-3px); }
    \\.card-head { display:flex; align-items:center; gap:8px; margin-bottom:12px; }
    \\.card-flag { font-size:20px; }
    \\.card-city { font-family:'DM Serif Display',Georgia,serif; font-size:16px; }
    \\.card-temp { font-size:42px; font-weight:700; font-family:'DM Serif Display',Georgia,serif; color:var(--text); line-height:1; margin-bottom:8px; }
    \\.card-details { font-size:12px; color:var(--muted); }
    \\.card-err { border-left:3px solid var(--red); }
    \\.skeleton .card-head,.skeleton .skel-big,.skeleton .skel-line { background:var(--bg3); border-radius:4px; }
    \\.skeleton .skel-dot { width:24px; height:24px; border-radius:50%; background:var(--bg3); }
    \\.skeleton .skel-line { height:14px; width:60%; background:var(--bg3); }
    \\.skeleton .skel-line.short { width:40%; margin-top:8px; }
    \\.skeleton .skel-big { height:36px; width:50%; background:var(--bg3); margin:12px 0 8px; }
    \\.skeleton { position:relative; overflow:hidden; }
    \\.skeleton::after { content:''; position:absolute; inset:0; background:linear-gradient(90deg,transparent,rgba(255,255,255,0.25),transparent); animation:shimmer 1.5s infinite; }
    \\@keyframes shimmer { 0%{transform:translateX(-100%)} 100%{transform:translateX(100%)} }
    \\.loading { display:flex; align-items:center; gap:10px; padding:14px 20px; background:var(--bg2); border-radius:8px; margin-bottom:20px; font-size:13px; color:var(--muted); animation:fadeIn 0.3s; }
    \\.loading-dot { width:8px; height:8px; border-radius:50%; background:var(--red); animation:pulse 1s infinite; }
    \\@keyframes pulse { 0%,100%{opacity:1;transform:scale(1)} 50%{opacity:0.4;transform:scale(0.8)} }
    \\@keyframes fadeIn { from{opacity:0;transform:translateY(-8px)} to{opacity:1;transform:translateY(0)} }
    \\.explainer { background:var(--bg2); border-radius:8px; padding:20px 24px; border-left:3px solid var(--red); }
    \\.explainer h3 { font-family:'DM Serif Display',Georgia,serif; font-size:16px; margin-bottom:8px; }
    \\.explainer p { font-size:14px; color:var(--muted); line-height:1.7; }
    \\.explainer code { font-family:'SF Mono','Fira Code',monospace; font-size:12px; background:var(--bg3); padding:1px 5px; border-radius:3px; }
    \\@media(max-width:600px) { .cards { grid-template-columns:1fr; } .card-temp { font-size:32px; } }
    \\.compare { margin-top:28px; background:var(--bg2); border-radius:10px; padding:22px 24px; }
    \\.compare h3 { font-family:'DM Serif Display',Georgia,serif; font-size:16px; margin-bottom:6px; }
    \\.compare-desc { font-size:13px; color:var(--muted); line-height:1.6; margin-bottom:18px; }
    \\.tl { display:grid; grid-template-columns:64px 1fr; gap:6px 10px; align-items:center; }
    \\.tl-label { font-size:11px; font-weight:700; color:var(--text); text-align:right; letter-spacing:0.03em; }
    \\.tl-label.gray { color:var(--muted); font-weight:400; }
    \\.tl-track { position:relative; height:30px; background:var(--bg3); border-radius:4px; overflow:hidden; }
    \\.tl-shell { position:absolute; left:1%; top:4px; height:22px; width:5%; min-width:36px; background:#22c55e; border-radius:3px; display:flex; align-items:center; justify-content:center; font-size:9px; font-weight:600; color:#fff; white-space:nowrap; opacity:0; animation:tlPop 0.25s 0.1s forwards; }
    \\.tl-card { position:absolute; top:4px; height:22px; background:var(--red); border-radius:3px; display:flex; align-items:center; justify-content:center; padding:0 5px; font-size:9px; font-weight:600; color:#fff; white-space:nowrap; opacity:0; }
    \\.tl-c1 { left:33%; width:9%; animation:tlPop 0.25s 0.6s forwards; }
    \\.tl-c2 { left:55%; width:9%; animation:tlPop 0.25s 1.0s forwards; }
    \\.tl-c3 { left:78%; width:9%; animation:tlPop 0.25s 1.4s forwards; }
    \\.tl-wait { position:absolute; left:0; top:4px; height:22px; width:0; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.12); border-radius:3px; display:flex; align-items:center; padding:0 8px; font-size:9px; color:var(--muted); overflow:hidden; white-space:nowrap; animation:tlGrow 1.7s 0.1s forwards; }
    \\.tl-full { position:absolute; left:87%; top:4px; height:22px; width:10%; background:#3b82f6; border-radius:3px; display:flex; align-items:center; justify-content:center; font-size:9px; font-weight:600; color:#fff; opacity:0; animation:tlPop 0.25s 1.8s forwards; }
    \\@keyframes tlPop { from{opacity:0;transform:scale(0.8)} to{opacity:1;transform:scale(1)} }
    \\@keyframes tlGrow { to{width:87%} }
    \\.tl-axis { display:grid; grid-template-columns:64px 1fr; gap:0 10px; margin-top:4px; }
    \\.tl-axis span { display:inline-block; }
    \\.tl-axis > span:first-child { display:block; }
    \\.tl-ruler { display:flex; justify-content:space-between; font-size:10px; color:var(--muted); padding:0 1px; }
    \\.tl-note { font-size:11px; color:var(--muted); margin-top:10px; opacity:0.7; }
;
