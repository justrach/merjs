const std = @import("std");
const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "Streaming SSR Demo",
    .description = "True streaming server-side rendering — watch placeholders resolve in real time.",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

/// Standard render fallback (used by non-streaming paths like prerender).
pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html(
        \\<h1>Streaming SSR Demo</h1>
        \\<p>This page requires streaming to work. Visit it in a browser with the dev server.</p>
    );
}

/// True streaming render — the server flushes the shell, then progressively
/// resolves placeholders as data arrives. Uses the Marko/React $RC pattern.
pub fn renderStream(req: mer.Request, stream: *mer.StreamWriter) void {
    // 1. Write the page shell with placeholders — flushes immediately.
    stream.write(
        \\<div class="stream-demo">
        \\  <h1 class="stream-title">Streaming SSR <span class="red">Demo</span></h1>
        \\  <p class="stream-subtitle">Watch the placeholders resolve as data arrives from the server.</p>
        \\  <div class="stream-grid">
    );

    // Write placeholders with skeleton loading states.
    stream.placeholder("weather",
        \\<div class="card skeleton"><div class="skeleton-title"></div><div class="skeleton-text"></div><div class="skeleton-text short"></div></div>
    );
    stream.placeholder("quote",
        \\<div class="card skeleton"><div class="skeleton-title"></div><div class="skeleton-text"></div></div>
    );
    stream.placeholder("stats",
        \\<div class="card skeleton"><div class="skeleton-title"></div><div class="skeleton-text"></div><div class="skeleton-text short"></div></div>
    );

    stream.write("</div>");
    stream.flush();
    // ^^^ At this point the browser has the full shell with 3 skeleton cards.

    // 2. Fetch data in parallel — all three resolve concurrently.
    const results = mer.fetchAll(req.allocator, &.{
        .{ .url = "https://api.open-meteo.com/v1/forecast?latitude=1.29&longitude=103.85&current=temperature_2m,wind_speed_10m" },
        .{ .url = "https://dummyjson.com/quotes/random" },
        .{ .url = "https://dummyjson.com/users?limit=3&select=firstName,age" },
    });
    defer for (results) |r| if (r) |ok| ok.deinit(req.allocator);

    // 3. Resolve each placeholder as its data arrives.
    if (results[0]) |weather_res| {
        const body = parseWeather(req.allocator, weather_res.body);
        stream.resolve("weather", body);
    } else {
        stream.resolve("weather", "<div class=\"card error\">Weather data unavailable</div>");
    }

    if (results[1]) |quote_res| {
        const body = parseQuote(req.allocator, quote_res.body);
        stream.resolve("quote", body);
    } else {
        stream.resolve("quote", "<div class=\"card error\">Quote unavailable</div>");
    }

    if (results[2]) |stats_res| {
        const body = parseStats(req.allocator, stats_res.body);
        stream.resolve("stats", body);
    } else {
        stream.resolve("stats", "<div class=\"card error\">Stats unavailable</div>");
    }

    // 4. Close the page.
    stream.write("</div>");
    stream.flush();
}

fn parseWeather(alloc: std.mem.Allocator, body: []u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return "<div class=\"card\"><h3>Weather</h3><p>Parse error</p></div>";
    const current = parsed.value.object.get("current") orelse
        return "<div class=\"card\"><h3>Weather</h3><p>No current data</p></div>";
    const temp = current.object.get("temperature_2m") orelse return "<div class=\"card\"><h3>Weather</h3><p>No temp</p></div>";
    const wind = current.object.get("wind_speed_10m") orelse return "<div class=\"card\"><h3>Weather</h3><p>No wind</p></div>";
    return std.fmt.allocPrint(alloc,
        \\<div class="card"><h3>Singapore Weather</h3><div class="card-stat">{d:.1}&deg;C</div><p>Wind: {d:.1} km/h</p></div>
    , .{ temp.float, wind.float }) catch "<div class=\"card\">Format error</div>";
}

fn parseQuote(alloc: std.mem.Allocator, body: []u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return "<div class=\"card\"><h3>Quote</h3><p>Parse error</p></div>";
    const quote_text = parsed.value.object.get("quote") orelse return "<div class=\"card\"><h3>Quote</h3><p>No quote</p></div>";
    const author = parsed.value.object.get("author") orelse return "<div class=\"card\"><h3>Quote</h3><p>No author</p></div>";
    return std.fmt.allocPrint(alloc,
        \\<div class="card"><h3>Random Quote</h3><p class="quote-text">&ldquo;{s}&rdquo;</p><p class="quote-author">&mdash; {s}</p></div>
    , .{ quote_text.string, author.string }) catch "<div class=\"card\">Format error</div>";
}

fn parseStats(alloc: std.mem.Allocator, body: []u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return "<div class=\"card\"><h3>Users</h3><p>Parse error</p></div>";
    const users = (parsed.value.object.get("users") orelse
        return "<div class=\"card\"><h3>Users</h3><p>No data</p></div>").array;
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(alloc);
    w.writeAll("<div class=\"card\"><h3>Random Users</h3><ul>") catch {};
    for (users.items) |user| {
        const name = (user.object.get("firstName") orelse continue).string;
        const age = (user.object.get("age") orelse continue).integer;
        w.print("<li>{s}, age {d}</li>", .{ name, age }) catch {};
    }
    w.writeAll("</ul></div>") catch {};
    return buf.items;
}

const page_css =
    \\.stream-demo { max-width: 680px; margin: 0 auto; }
    \\.stream-title { font-family:'DM Serif Display',Georgia,serif; font-size: clamp(28px,4vw,40px); letter-spacing:-0.02em; margin-bottom:8px; }
    \\.stream-title .red { color: var(--red); }
    \\.stream-subtitle { color: var(--muted); font-size:15px; margin-bottom:32px; }
    \\.stream-grid { display:grid; grid-template-columns:1fr; gap:16px; }
    \\.card { background:var(--bg2); border-radius:8px; padding:24px; }
    \\.card h3 { font-family:'DM Serif Display',Georgia,serif; font-size:18px; margin-bottom:12px; }
    \\.card p { font-size:14px; color:var(--muted); line-height:1.6; }
    \\.card ul { list-style:none; padding:0; }
    \\.card li { font-size:14px; color:var(--muted); padding:4px 0; border-bottom:1px solid var(--border); }
    \\.card li:last-child { border-bottom:none; }
    \\.card-stat { font-size:36px; font-weight:700; color:var(--text); font-family:'DM Serif Display',Georgia,serif; margin:8px 0; }
    \\.card.error { border-left:3px solid var(--red); }
    \\.quote-text { font-style:italic; font-size:16px !important; color:var(--text) !important; line-height:1.7 !important; }
    \\.quote-author { font-size:13px !important; margin-top:8px; }
    \\.skeleton { position:relative; overflow:hidden; }
    \\.skeleton::after { content:''; position:absolute; top:0; left:0; right:0; bottom:0; background:linear-gradient(90deg,transparent,rgba(255,255,255,0.3),transparent); animation:shimmer 1.5s infinite; }
    \\.skeleton-title { height:20px; width:40%; background:var(--bg3); border-radius:4px; margin-bottom:12px; }
    \\.skeleton-text { height:14px; width:80%; background:var(--bg3); border-radius:4px; margin-bottom:8px; }
    \\.skeleton-text.short { width:50%; }
    \\@keyframes shimmer { 0%{transform:translateX(-100%)} 100%{transform:translateX(100%)} }
    \\@media(min-width:600px) { .stream-grid { grid-template-columns:1fr 1fr; } }
;
