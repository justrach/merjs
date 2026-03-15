const std = @import("std");
const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "City Map Posters — Rendered in Zig",
    .description = "Map posters rendered server-side in Zig from live OpenStreetMap road data, streamed to your browser.",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html("<h1>Map Poster Demo</h1><p>Requires streaming SSR.</p>");
}

const Theme = struct { name: []const u8, bg: []const u8, tc: []const u8, r1: []const u8, r2: []const u8, r3: []const u8 };
const City = struct { name: []const u8, country: []const u8, lat: f64, lon: f64, ti: usize };

const themes = [_]Theme{
    .{ .name = "Neon Cyberpunk", .bg = "#0D0D1A", .tc = "#00FFFF", .r1 = "#FF00FF", .r2 = "#00FFFF", .r3 = "#006870" },
    .{ .name = "Midnight Blue", .bg = "#0A1628", .tc = "#C0D0E0", .r1 = "#4A90D9", .r2 = "#2E6DB4", .r3 = "#1A4070" },
    .{ .name = "Warm Beige", .bg = "#F5E6D3", .tc = "#2C1810", .r1 = "#8B4513", .r2 = "#A0522D", .r3 = "#D2B48C" },
    .{ .name = "Blueprint", .bg = "#1B3A5C", .tc = "#FFFFFF", .r1 = "#FFFFFF", .r2 = "#89B4D4", .r3 = "#456B8A" },
};

const demo_cities = [_]City{
    .{ .name = "Singapore", .country = "Singapore", .lat = 1.3521, .lon = 103.8198, .ti = 0 },
    .{ .name = "Tokyo", .country = "Japan", .lat = 35.6762, .lon = 139.6503, .ti = 1 },
    .{ .name = "Barcelona", .country = "Spain", .lat = 41.3874, .lon = 2.1686, .ti = 2 },
    .{ .name = "Venice", .country = "Italy", .lat = 45.4408, .lon = 12.3155, .ti = 3 },
};

pub fn renderStream(req: mer.Request, stream: *mer.StreamWriter) void {
    stream.write(
        \\<div class="poster-page">
        \\  <div class="poster-header">
        \\    <h1 class="poster-title">City Map <span class="red">Posters</span></h1>
        \\    <p class="poster-sub">Rendered on-the-fly in Zig from live OpenStreetMap road data. Each poster streams in as the Overpass API responds.</p>
        \\  </div>
        \\  <div class="poster-grid">
    );

    for (0..demo_cities.len) |i| {
        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "city-{d}", .{i}) catch "city";
        stream.placeholder(id,
            \\<div class="poster-card skeleton"><div class="poster-svg-skeleton"></div><div class="poster-info-skeleton"><div class="skeleton-title"></div><div class="skeleton-text"></div></div></div>
        );
    }
    stream.write("</div>");
    stream.flush();

    // Fetch road data via POST (avoids URL encoding issues).
    var fetch_reqs: [demo_cities.len]mer.FetchRequest = undefined;
    for (demo_cities, 0..) |city, i| {
        const r = 0.018;
        const query = std.fmt.allocPrint(
            req.allocator,
            "[out:json][timeout:15];way[\"highway\"~\"^(motorway|primary|secondary|tertiary|residential)$\"]({d:.4},{d:.4},{d:.4},{d:.4});out geom;",
            .{ city.lat - r, city.lon - r, city.lat + r, city.lon + r },
        ) catch "";
        const body = std.fmt.allocPrint(req.allocator, "data={s}", .{query}) catch "";
        fetch_reqs[i] = .{
            .url = "https://overpass-api.de/api/interpreter",
            .method = .POST,
            .body = body,
            .headers = &.{
                .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
                .{ .name = "User-Agent", .value = "merjs/0.1.0" },
            },
        };
    }

    const results = mer.fetchAll(req.allocator, &fetch_reqs);
    defer for (results) |r| if (r) |ok| ok.deinit(req.allocator);

    for (demo_cities, 0..) |city, i| {
        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "city-{d}", .{i}) catch "city";
        const theme = themes[city.ti];

        if (results[i]) |res| {
            const svg = renderSvg(req.allocator, res.body, city, theme);
            const card = std.fmt.allocPrint(
                req.allocator,
                "<div class=\"poster-card\">{s}<div class=\"poster-info\" style=\"background:{s}\"><div class=\"poster-city\" style=\"color:{s}\">{s}</div><div class=\"poster-meta\" style=\"color:{s}\">{s} \xc2\xb7 {s}</div></div></div>",
                .{ svg, theme.bg, theme.tc, city.name, theme.tc, city.country, theme.name },
            ) catch "<div class=\"poster-card\">Error</div>";
            stream.resolve(id, card);
        } else {
            stream.resolve(id, "<div class=\"poster-card\"><p style=\"padding:20px\">Failed to fetch road data</p></div>");
        }
    }
    stream.write("</div>");
    stream.flush();
}

fn renderSvg(alloc: std.mem.Allocator, body: []u8, city: City, theme: Theme) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return svgError("parse error");
    const elements = (parsed.value.object.get("elements") orelse return svgError("no elements")).array;

    const r = 0.018;
    const min_lat = city.lat - r;
    const min_lon = city.lon - r;
    const w: f64 = 400;
    const svg_h: f64 = 520;
    const pad: f64 = 15;
    const scale_x = (w - 2 * pad) / (2 * r);

    var buf: std.ArrayList(u8) = .{};
    const wr = buf.writer(alloc);

    wr.print("<svg viewBox=\"0 0 {d:.0} {d:.0}\" xmlns=\"http://www.w3.org/2000/svg\" style=\"width:100%;display:block;border-radius:8px 8px 0 0\">", .{ w, svg_h }) catch {};
    wr.print("<rect width=\"{d:.0}\" height=\"{d:.0}\" fill=\"{s}\"/>", .{ w, svg_h, theme.bg }) catch {};

    var road_count: usize = 0;
    for (elements.items) |elem| {
        const tags = elem.object.get("tags") orelse continue;
        const highway = (tags.object.get("highway") orelse continue).string;
        const geom = (elem.object.get("geometry") orelse continue).array;
        if (geom.items.len < 2) continue;

        const color = if (std.mem.eql(u8, highway, "motorway") or std.mem.eql(u8, highway, "primary")) theme.r1 else if (std.mem.eql(u8, highway, "secondary")) theme.r2 else theme.r3;
        const sw: f64 = if (std.mem.eql(u8, highway, "motorway") or std.mem.eql(u8, highway, "primary")) 2.0 else if (std.mem.eql(u8, highway, "secondary")) 1.2 else 0.5;

        wr.writeAll("<path d=\"") catch {};
        var has_points = false;
        for (geom.items, 0..) |pt, j| {
            const lat_val = pt.object.get("lat") orelse continue;
            const lon_val = pt.object.get("lon") orelse continue;
            const lat_f: f64 = switch (lat_val) {
                .float => lat_val.float,
                .integer => @floatFromInt(lat_val.integer),
                else => continue,
            };
            const lon_f: f64 = switch (lon_val) {
                .float => lon_val.float,
                .integer => @floatFromInt(lon_val.integer),
                else => continue,
            };
            const x = pad + (lon_f - min_lon) * scale_x;
            const y = pad + (1.0 - (lat_f - min_lat) / (2 * r)) * (svg_h - 60 - 2 * pad);
            wr.print("{s}{d:.1} {d:.1}", .{ if (j == 0) "M" else "L", x, y }) catch {};
            has_points = true;
        }
        if (has_points) {
            wr.print("\" fill=\"none\" stroke=\"{s}\" stroke-width=\"{d:.1}\" stroke-linecap=\"round\"/>", .{ color, sw }) catch {};
            road_count += 1;
        } else {
            wr.writeAll("\" fill=\"none\"/>") catch {};
        }
    }

    // City name at bottom.
    wr.print("<text x=\"{d:.0}\" y=\"{d:.0}\" text-anchor=\"middle\" fill=\"{s}\" font-family=\"Georgia,serif\" font-size=\"22\" font-weight=\"bold\">{s}</text>", .{ w / 2, svg_h - 28, theme.tc, city.name }) catch {};
    wr.print("<text x=\"{d:.0}\" y=\"{d:.0}\" text-anchor=\"middle\" fill=\"{s}\" font-family=\"sans-serif\" font-size=\"9\" opacity=\"0.4\">{d} roads rendered</text>", .{ w / 2, svg_h - 12, theme.tc, road_count }) catch {};
    wr.writeAll("</svg>") catch {};
    return buf.items;
}

fn svgError(msg: []const u8) []const u8 {
    _ = msg;
    return "<svg viewBox=\"0 0 400 520\" xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"400\" height=\"520\" fill=\"#1a1a1a\"/><text x=\"200\" y=\"260\" text-anchor=\"middle\" fill=\"#666\" font-size=\"14\">Loading failed</text></svg>";
}

const page_css =
    \\.poster-page { max-width:900px; margin:0 auto; }
    \\.poster-header { margin-bottom:32px; }
    \\.poster-title { font-family:'DM Serif Display',Georgia,serif; font-size:clamp(28px,4vw,42px); letter-spacing:-0.02em; margin-bottom:8px; }
    \\.poster-title .red { color:var(--red); }
    \\.poster-sub { color:var(--muted); font-size:15px; line-height:1.6; }
    \\.poster-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(220px,1fr)); gap:20px; }
    \\.poster-card { border-radius:10px; overflow:hidden; transition:transform 0.2s,box-shadow 0.2s; box-shadow:0 2px 12px rgba(0,0,0,0.08); }
    \\.poster-card:hover { transform:translateY(-6px); box-shadow:0 8px 24px rgba(0,0,0,0.15); }
    \\.poster-info { padding:14px 16px; }
    \\.poster-city { font-family:'DM Serif Display',Georgia,serif; font-size:20px; margin-bottom:2px; }
    \\.poster-meta { font-size:10px; opacity:0.5; }
    \\.poster-card.skeleton { min-height:380px; background:var(--bg2); }
    \\.poster-svg-skeleton { height:300px; background:var(--bg3); }
    \\.poster-info-skeleton { padding:14px 16px; }
    \\.skeleton { position:relative; overflow:hidden; }
    \\.skeleton::after { content:''; position:absolute; top:0; left:0; right:0; bottom:0; background:linear-gradient(90deg,transparent,rgba(255,255,255,0.3),transparent); animation:shimmer 1.5s infinite; }
    \\.skeleton-title { height:18px; width:50%; background:var(--bg3); border-radius:4px; margin-bottom:8px; }
    \\.skeleton-text { height:12px; width:70%; background:var(--bg3); border-radius:4px; }
    \\@keyframes shimmer { 0%{transform:translateX(-100%)} 100%{transform:translateX(100%)} }
    \\@media(max-width:500px) { .poster-grid { grid-template-columns:1fr 1fr; gap:12px; } .poster-city { font-size:16px; } }
;
