const std = @import("std");
const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "Streaming Map Demo",
    .description = "Watch a city map build progressively using streaming SSR — data fetched from OpenStreetMap in real time.",
    .extra_head = "<link rel=\"stylesheet\" href=\"https://unpkg.com/leaflet@1.9.4/dist/leaflet.css\">" ++
        "<link rel=\"preload\" href=\"https://unpkg.com/leaflet@1.9.4/dist/leaflet.js\" as=\"script\">" ++
        "<script src=\"https://unpkg.com/leaflet@1.9.4/dist/leaflet.js\"></script>" ++
        "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return mer.html(
        \\<h1>Streaming Map Demo</h1>
        \\<p>This page uses streaming SSR. Visit it with the dev server.</p>
    );
}

/// True streaming SSR — fetches city data from multiple OSM APIs in parallel,
/// resolves each section as it arrives. The map shell + skeleton appears instantly.
pub fn renderStream(req: mer.Request, stream: *mer.StreamWriter) void {
    // Get city from query string, default to Singapore.
    const city = mer.formParam(req.query_string, "city") orelse "Singapore";
    const country = mer.formParam(req.query_string, "country") orelse "Singapore";

    // 1. Send shell with map placeholder + skeleton cards.
    stream.write(
        \\<div class="map-page">
        \\  <h1 class="map-title">City Explorer <span class="red">Live</span></h1>
    );
    stream.write("<p class=\"map-sub\">Streaming data for <strong>");
    stream.write(city);
    stream.write(", ");
    stream.write(country);
    stream.write("</strong> from OpenStreetMap</p>");

    // Map placeholder
    stream.placeholder("map-data",
        \\<div class="map-container">
        \\  <div id="map" style="height:400px;background:var(--bg2);display:flex;align-items:center;justify-content:center;border-radius:8px;">
        \\    <span style="color:var(--muted)">Loading map data...</span>
        \\  </div>
        \\</div>
    );

    // Info cards placeholders
    stream.write("<div class=\"info-grid\">");
    stream.placeholder("geo-info",
        \\<div class="card skeleton"><div class="skeleton-title"></div><div class="skeleton-text"></div><div class="skeleton-text short"></div></div>
    );
    stream.placeholder("amenities",
        \\<div class="card skeleton"><div class="skeleton-title"></div><div class="skeleton-text"></div><div class="skeleton-text"></div></div>
    );
    stream.placeholder("weather",
        \\<div class="card skeleton"><div class="skeleton-title"></div><div class="skeleton-text"></div></div>
    );
    stream.write("</div>");
    stream.flush();
    // ^^^ Browser now has the full shell with skeleton cards.

    // 2. Fetch data in parallel.
    const geo_url = std.fmt.allocPrint(
        req.allocator,
        "https://nominatim.openstreetmap.org/search?q={s},{s}&format=json&limit=1&addressdetails=1",
        .{ city, country },
    ) catch "";
    defer if (geo_url.len > 0) req.allocator.free(geo_url);

    const results = mer.fetchAll(req.allocator, &.{
        .{ .url = geo_url, .headers = &.{.{ .name = "User-Agent", .value = "merjs/0.1.0" }} },
        .{ .url = "https://api.open-meteo.com/v1/forecast?latitude=1.29&longitude=103.85&current=temperature_2m,relative_humidity_2m,wind_speed_10m" },
    });
    defer for (results) |r| if (r) |ok| ok.deinit(req.allocator);

    // 3. Resolve geocoding + map.
    if (results[0]) |geo_res| {
        const geo_html = buildGeoCard(req.allocator, geo_res.body, city);
        stream.resolve("geo-info", geo_html.card);
        // Resolve map with coordinates.
        const map_html = buildMapHtml(req.allocator, geo_html.lat, geo_html.lon, city);
        stream.resolve("map-data", map_html);
    } else {
        stream.resolve("geo-info", "<div class=\"card error\">Geocoding failed</div>");
        stream.resolve("map-data", "<div class=\"card error\">Map unavailable</div>");
    }

    // 4. Resolve amenities (from the same geo data).
    if (results[0]) |geo_res| {
        stream.resolve("amenities", buildAmenitiesCard(req.allocator, geo_res.body));
    } else {
        stream.resolve("amenities", "<div class=\"card error\">Data unavailable</div>");
    }

    // 5. Resolve weather.
    if (results[1]) |weather_res| {
        stream.resolve("weather", buildWeatherCard(req.allocator, weather_res.body));
    } else {
        stream.resolve("weather", "<div class=\"card error\">Weather unavailable</div>");
    }

    stream.write("</div>");
    stream.flush();
}

const GeoResult = struct { card: []const u8, lat: []const u8, lon: []const u8 };

fn buildGeoCard(alloc: std.mem.Allocator, body: []u8, city: []const u8) GeoResult {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return .{ .card = "<div class=\"card\"><h3>Location</h3><p>Parse error</p></div>", .lat = "1.29", .lon = "103.85" };
    const arr = parsed.value.array;
    if (arr.items.len == 0)
        return .{ .card = "<div class=\"card\"><h3>Location</h3><p>City not found</p></div>", .lat = "1.29", .lon = "103.85" };
    const item = arr.items[0].object;
    const lat = if (item.get("lat")) |v| v.string else "1.29";
    const lon = if (item.get("lon")) |v| v.string else "103.85";
    const display = if (item.get("display_name")) |v| v.string else city;
    const osm_type = if (item.get("type")) |v| v.string else "place";
    const card = std.fmt.allocPrint(alloc,
        \\<div class="card"><h3>Location</h3><p class="card-stat">{s}</p><p>Type: {s}</p><p>Coordinates: {s}, {s}</p></div>
    , .{ display, osm_type, lat, lon }) catch "<div class=\"card\">Format error</div>";
    return .{ .card = card, .lat = lat, .lon = lon };
}

fn buildMapHtml(alloc: std.mem.Allocator, lat: []const u8, lon: []const u8, city: []const u8) []const u8 {
    return std.fmt.allocPrint(alloc,
        \\<div class="map-container">
        \\  <div id="map" style="height:400px;border-radius:8px;"></div>
        \\  <script>
        \\    var map = L.map('map').setView([{s}, {s}], 13);
        \\    L.tileLayer('https://{{s}}.basemaps.cartocdn.com/light_all/{{z}}/{{x}}/{{y}}@2x.png', {{
        \\      attribution: '&copy; OpenStreetMap contributors &copy; CARTO',
        \\      maxZoom: 19
        \\    }}).addTo(map);
        \\    L.marker([{s}, {s}]).addTo(map).bindPopup('{s}').openPopup();
        \\  </script>
        \\</div>
    , .{ lat, lon, lat, lon, city }) catch "<div>Map error</div>";
}

fn buildAmenitiesCard(alloc: std.mem.Allocator, body: []u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return "<div class=\"card\"><h3>Details</h3><p>Parse error</p></div>";
    const arr = parsed.value.array;
    if (arr.items.len == 0)
        return "<div class=\"card\"><h3>Details</h3><p>No data</p></div>";
    const item = arr.items[0].object;
    const addr = item.get("address") orelse
        return "<div class=\"card\"><h3>Details</h3><p>No address data</p></div>";
    const addr_obj = addr.object;
    const state = if (addr_obj.get("state")) |v| v.string else "N/A";
    const country_name = if (addr_obj.get("country")) |v| v.string else "N/A";
    const postcode = if (addr_obj.get("postcode")) |v| v.string else "N/A";
    return std.fmt.allocPrint(alloc,
        \\<div class="card"><h3>Details</h3><p>State: {s}</p><p>Country: {s}</p><p>Postcode: {s}</p></div>
    , .{ state, country_name, postcode }) catch "<div class=\"card\">Format error</div>";
}

fn buildWeatherCard(alloc: std.mem.Allocator, body: []u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return "<div class=\"card\"><h3>Weather</h3><p>Parse error</p></div>";
    const current = parsed.value.object.get("current") orelse
        return "<div class=\"card\"><h3>Weather</h3><p>No data</p></div>";
    const temp = current.object.get("temperature_2m") orelse return "<div class=\"card\"><h3>Weather</h3><p>No temp</p></div>";
    const humidity = current.object.get("relative_humidity_2m") orelse return "<div class=\"card\"><h3>Weather</h3><p>No humidity</p></div>";
    const wind = current.object.get("wind_speed_10m") orelse return "<div class=\"card\"><h3>Weather</h3><p>No wind</p></div>";
    const temp_f: f64 = switch (temp) {
        .float => temp.float,
        .integer => @floatFromInt(temp.integer),
        else => 0,
    };
    const humidity_f: f64 = switch (humidity) {
        .float => humidity.float,
        .integer => @floatFromInt(humidity.integer),
        else => 0,
    };
    const wind_f: f64 = switch (wind) {
        .float => wind.float,
        .integer => @floatFromInt(wind.integer),
        else => 0,
    };
    return std.fmt.allocPrint(alloc,
        \\<div class="card"><h3>Weather</h3><div class="card-stat">{d:.1}&deg;C</div><p>Humidity: {d:.0}%</p><p>Wind: {d:.1} km/h</p></div>
    , .{ temp_f, humidity_f, wind_f }) catch "<div class=\"card\">Format error</div>";
}

const page_css =
    \\.map-page { max-width:700px; margin:0 auto; }
    \\.map-title { font-family:'DM Serif Display',Georgia,serif; font-size:clamp(28px,4vw,40px); letter-spacing:-0.02em; margin-bottom:8px; }
    \\.map-title .red { color:var(--red); }
    \\.map-sub { color:var(--muted); font-size:15px; margin-bottom:24px; }
    \\.map-sub strong { color:var(--text); }
    \\.map-container { margin-bottom:24px; }
    \\.info-grid { display:grid; grid-template-columns:1fr; gap:12px; margin-top:16px; }
    \\.card { background:var(--bg2); border-radius:8px; padding:20px; }
    \\.card h3 { font-family:'DM Serif Display',Georgia,serif; font-size:16px; margin-bottom:10px; }
    \\.card p { font-size:14px; color:var(--muted); line-height:1.6; }
    \\.card-stat { font-size:28px; font-weight:700; color:var(--text); font-family:'DM Serif Display',Georgia,serif; margin:6px 0; }
    \\.card.error { border-left:3px solid var(--red); }
    \\.skeleton { position:relative; overflow:hidden; }
    \\.skeleton::after { content:''; position:absolute; top:0; left:0; right:0; bottom:0; background:linear-gradient(90deg,transparent,rgba(255,255,255,0.3),transparent); animation:shimmer 1.5s infinite; }
    \\.skeleton-title { height:18px; width:35%; background:var(--bg3); border-radius:4px; margin-bottom:10px; }
    \\.skeleton-text { height:13px; width:75%; background:var(--bg3); border-radius:4px; margin-bottom:7px; }
    \\.skeleton-text.short { width:45%; }
    \\@keyframes shimmer { 0%{transform:translateX(-100%)} 100%{transform:translateX(100%)} }
    \\@media(min-width:600px) { .info-grid { grid-template-columns:1fr 1fr 1fr; } }
;
