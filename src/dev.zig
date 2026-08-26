// dev.zig — dev-mode helpers: hot reload injection, error overlay, debug endpoint.
// Owned by mer.zig (pub const dev = @import("dev.zig")) to avoid Zig file-ownership errors.
// Does NOT import mer.zig to prevent circular dependencies.

const std = @import("std");
const res_mod = @import("response.zig");
const metrics = @import("metrics.zig");

/// Minimal route info passed from server.zig for the debug endpoint.
pub const RouteDebugInfo = struct {
    path: []const u8,
};

// Hot reload client: on an SSE reload event, fetch the current URL, parse it,
// and morph the live <body> in place (morphdom-style diff) instead of a full
// location.reload(). This preserves window scroll position, form field values,
// and the focused element. Any failure falls back to location.reload().
//
// IMPORTANT: this script MUST end with </body> — injectHotReload() (below) and
// the streaming tail in server.zig rely on that closing tag being present here.
pub const hot_reload_script =
    \\<script id="__mer_hr__">
    \\(function(){
    \\  var es = new EventSource('/_mer/events');
    \\  var reloading = false;
    \\  function fullReload(){ if(reloading) return; reloading = true; location.reload(); }
    \\  function fieldKey(el){
    \\    if(!el || el.nodeType!==1) return null;
    \\    if(el.id) return '#'+el.id;
    \\    if(el.name) return el.tagName+'['+el.name+']';
    \\    return null;
    \\  }
    \\  function findByKey(k){
    \\    if(!k) return null;
    \\    if(k.charAt(0)==='#') return document.getElementById(k.slice(1));
    \\    var m = k.match(/^([A-Z]+)\[(.+)\]$/);
    \\    if(m) return document.querySelector(m[1]+'[name="'+m[2]+'"]');
    \\    return null;
    \\  }
    \\  function captureFields(root){
    \\    var map = {}, els = root.querySelectorAll('input,textarea,select'), i, el, k;
    \\    for(i=0;i<els.length;i++){
    \\      el = els[i]; k = fieldKey(el); if(!k) continue;
    \\      map[k] = { value: el.value, checked: el.checked };
    \\    }
    \\    return map;
    \\  }
    \\  function restoreFields(root, map){
    \\    var els = root.querySelectorAll('input,textarea,select'), i, el, k, rec, t;
    \\    for(i=0;i<els.length;i++){
    \\      el = els[i]; k = fieldKey(el); if(!k || !(k in map)) continue;
    \\      rec = map[k]; t = (el.type||'').toLowerCase();
    \\      if(t==='checkbox' || t==='radio'){ el.checked = rec.checked; }
    \\      else { el.value = rec.value; }
    \\    }
    \\  }
    \\  function morphAttrs(from, to){
    \\    var i, a, ta = to.attributes, fa = from.attributes;
    \\    for(i=0;i<ta.length;i++){ a = ta[i]; if(from.getAttribute(a.name)!==a.value) from.setAttribute(a.name, a.value); }
    \\    for(i=fa.length-1;i>=0;i--){ a = fa[i]; if(!to.hasAttribute(a.name)) from.removeAttribute(a.name); }
    \\  }
    \\  function morph(from, to){
    \\    var f = from.firstChild, t = to.firstChild, nf, nt;
    \\    while(t){
    \\      nf = f ? f.nextSibling : null; nt = t.nextSibling;
    \\      if(!f){
    \\        from.appendChild(document.importNode(t, true));
    \\      } else if(f.nodeType!==t.nodeType || (f.nodeType===1 && f.nodeName!==t.nodeName)){
    \\        from.replaceChild(document.importNode(t, true), f);
    \\      } else if(f.nodeType===1){
    \\        morphAttrs(f, t); morph(f, t);
    \\      } else if(f.nodeValue!==t.nodeValue){
    \\        f.nodeValue = t.nodeValue;
    \\      }
    \\      f = nf; t = nt;
    \\    }
    \\    while(f){ nf = f.nextSibling; from.removeChild(f); f = nf; }
    \\  }
    \\  function escapeHtml(s){ return String(s).replace(/[&<>]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;'}[c]; }); }
    \\  function clearBuildError(){ var el = document.getElementById('__mer_build_err__'); if(el) el.remove(); }
    \\  function showBuildError(text){
    \\    var el = document.getElementById('__mer_build_err__');
    \\    if(!el){
    \\      el = document.createElement('div');
    \\      el.id = '__mer_build_err__';
    \\      el.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:rgba(26,26,46,0.97);color:#e0e0e0;font:13px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;padding:32px;overflow:auto';
    \\      document.body.appendChild(el);
    \\    }
    \\    el.innerHTML =
    \\      '<div style="color:#ff5555;font-size:20px;font-weight:600;margin-bottom:4px">Compile error</div>'
    \\      + '<div style="color:#8a7f78;margin-bottom:16px">merjs dev &mdash; fix the error and save to reload</div>'
    \\      + '<pre style="white-space:pre-wrap;word-break:break-word;color:#ffd479;background:#111124;padding:16px;border-radius:8px;border:1px solid #ff5555;margin:0">'
    \\      + escapeHtml(text) + '</pre>';
    \\  }
    \\  function apply(){
    \\    if(reloading) return;
    \\    clearBuildError();
    \\    var sx = window.scrollX, sy = window.scrollY;
    \\    var ae = document.activeElement, activeKey = fieldKey(ae), sel = null;
    \\    if(ae){ try { sel = [ae.selectionStart, ae.selectionEnd]; } catch(e){} }
    \\    fetch(location.href, { headers: { 'x-mer-hot-reload': '1' }, cache: 'no-store' })
    \\      .then(function(r){ if(!r.ok) throw new Error('status '+r.status); return r.text(); })
    \\      .then(function(html){
    \\        var doc = new DOMParser().parseFromString(html, 'text/html');
    \\        if(!doc || !doc.body || !doc.documentElement) throw new Error('parse failed');
    \\        var fields = captureFields(document.body);
    \\        morphAttrs(document.documentElement, doc.documentElement);
    \\        if(doc.title && doc.title!==document.title) document.title = doc.title;
    \\        morph(document.body, doc.body);
    \\        restoreFields(document.body, fields);
    \\        window.scrollTo(sx, sy);
    \\        if(activeKey){
    \\          var el = findByKey(activeKey);
    \\          if(el){ try { el.focus(); if(sel && el.setSelectionRange) el.setSelectionRange(sel[0], sel[1]); } catch(e){} }
    \\        }
    \\      })
    \\      .catch(fullReload);
    \\  }
    \\  es.onmessage = apply;
    \\  es.addEventListener('builderror', function(ev){ showBuildError(ev.data); });
    \\})();
    \\</script>
    \\</body>
;

pub fn injectHotReload(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    const marker = "</body>";
    const idx = std.mem.lastIndexOf(u8, body, marker) orelse return error.NoBodyTag;
    const before = body[0..idx];
    const after = body[idx + marker.len ..];
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ before, hot_reload_script, after });
}

/// Dev error overlay — renders a styled error page in the browser when a route handler fails.
pub fn sendErrorOverlay(std_req: *std.http.Server.Request, target: []const u8, err: anyerror, version: []const u8) !void {
    const error_name = @errorName(err);

    const fixed = [1]std.http.Header{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    };
    var header_buf: [4096]u8 = undefined;
    var bw = try std_req.respondStreaming(&header_buf, .{
        .respond_options = .{
            .status = .internal_server_error,
            .extra_headers = &fixed,
        },
    });

    try bw.writer.writeAll(
        \\<!DOCTYPE html><html><head><meta charset="UTF-8"><title>merjs error</title>
        \\<style>
        \\*{margin:0;padding:0;box-sizing:border-box}
        \\body{font-family:-apple-system,system-ui,monospace;background:#1a1a2e;color:#e0e0e0;padding:2em}
        \\.err-box{max-width:720px;margin:3em auto;border:2px solid #ff5555;border-radius:12px;overflow:hidden}
        \\.err-header{background:#ff5555;color:#fff;padding:16px 24px;font-size:14px;font-weight:600;letter-spacing:0.5px}
        \\.err-body{padding:24px}
        \\.err-name{font-size:28px;color:#ff7979;margin-bottom:12px}
        \\.err-path{color:#82b1ff;font-size:16px;margin-bottom:24px}
        \\.err-hint{background:#222244;border-radius:8px;padding:16px;margin-top:16px;font-size:13px;line-height:1.6;color:#aaa}
        \\.err-hint code{color:#64ffda;background:#1a1a2e;padding:2px 6px;border-radius:3px}
        \\.err-footer{border-top:1px solid #333;padding:16px 24px;font-size:12px;color:#666}
        \\</style></head><body>
        \\<div class="err-box">
        \\<div class="err-header">MERJS DEV ERROR</div>
        \\<div class="err-body">
        \\<div class="err-name">
    );
    try bw.writer.writeAll(error_name);
    try bw.writer.writeAll(
        \\</div>
        \\<div class="err-path">
    );
    try bw.writer.writeAll(target);
    try bw.writer.writeAll(
        \\</div>
        \\<div class="err-hint">
        \\<strong>Debugging tips:</strong><br>
        \\&bull; Run with <code>--verbose</code> to see per-request timing<br>
        \\&bull; Visit <code>/_mer/debug</code> to see all registered routes<br>
        \\&bull; Check the terminal for the full error log<br>
        \\&bull; Use <code>std.log.scoped(.mypage)</code> in your page handler for custom logs
        \\</div>
        \\</div>
        \\<div class="err-footer">merjs v
    );
    try bw.writer.writeAll(version);
    try bw.writer.writeAll(
        \\ &mdash; this error page is only shown in dev mode</div>
        \\</div></body></html>
    );
    try bw.end();
}

fn writeStatJson(w: *std.Io.Writer, name: []const u8, s: metrics.Stat) !void {
    try w.print(
        "\"{s}\":{{\"avg\":{d},\"p50\":{d},\"p95\":{d},\"p99\":{d},\"max\":{d}}}",
        .{ name, s.avg, s.p50, s.p95, s.p99, s.max },
    );
}

fn writeStatRow(w: *std.Io.Writer, label: []const u8, s: metrics.Stat) !void {
    try w.print(
        "<tr><td>{s}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td></tr>",
        .{ label, s.avg, s.p50, s.p95, s.p99, s.max },
    );
}

/// Build a response for the /_mer/debug endpoint.
/// Caller is responsible for sending it via sendResponse (which adds security headers).
pub fn serveDebug(
    alloc: std.mem.Allocator,
    routes: []const RouteDebugInfo,
    exact_count: usize,
    dynamic_count: usize,
    query_string: []const u8,
    version: []const u8,
) !res_mod.Response {
    const want_json = std.mem.indexOf(u8, query_string, "format=json") != null;
    var body: std.Io.Writer.Allocating = .init(alloc);
    const w = &body.writer;

    if (want_json) {
        // JSON mode — for agents and programmatic access.
        try w.writeAll("{\"version\":\"");
        try w.writeAll(version);
        try w.writeAll("\",\"zig\":\"");
        try w.writeAll(@import("builtin").zig_version_string);
        try w.print("\",\"routes_exact\":{d},\"routes_dynamic\":{d},\"routes\":[", .{ exact_count, dynamic_count });
        for (routes, 0..) |route, i| {
            if (i > 0) try w.writeAll(",");
            const rtype: []const u8 = if (std.mem.startsWith(u8, route.path, "/api/")) "api" else "page";
            try w.print("{{\"path\":\"{s}\",\"type\":\"{s}\"}}", .{ route.path, rtype });
        }
        try w.writeAll("],");

        // Metrics block (TTFB + duration percentiles, per-route breakdown).
        const report = metrics.collect(alloc) catch metrics.Report{
            .total_requests = 0,
            .window = 0,
            .ttfb = .{},
            .duration = .{},
            .routes = &.{},
        };
        try w.print("\"metrics\":{{\"total_requests\":{d},\"window\":{d},", .{ report.total_requests, report.window });
        try writeStatJson(w, "ttfb_us", report.ttfb);
        try w.writeAll(",");
        try writeStatJson(w, "duration_us", report.duration);
        try w.writeAll(",\"routes\":[");
        for (report.routes, 0..) |r, i| {
            if (i > 0) try w.writeAll(",");
            try w.print(
                "{{\"path\":\"{s}\",\"count\":{d},\"avg_ttfb_us\":{d},\"avg_duration_us\":{d}}}",
                .{ r.path, r.count, r.avg_ttfb_us, r.avg_duration_us },
            );
        }
        try w.writeAll("]},");

        try w.writeAll("\"hints\":[");
        try w.writeAll("\"Run with --verbose for per-request timing\",");
        try w.writeAll("\"Visit /_mer/events for SSE hot reload stream\",");
        try w.writeAll("\"Use std.log.scoped(.mypage) in page handlers\"");
        try w.writeAll("]}");

        return res_mod.Response.init(.ok, .json, body.written());
    } else {
        // HTML mode — for browsers.
        try w.writeAll("<html><head><title>merjs debug</title><style>");
        try w.writeAll("body{font-family:monospace;max-width:720px;margin:2em auto;background:#1a1a2e;color:#e0e0e0}");
        try w.writeAll("h1{color:#64ffda}h2{color:#82b1ff;margin-top:1.5em}table{border-collapse:collapse;width:100%}");
        try w.writeAll("td,th{text-align:left;padding:4px 12px;border-bottom:1px solid #333}th{color:#aaa}");
        try w.writeAll("code{color:#64ffda;background:#222244;padding:2px 6px;border-radius:3px}");
        try w.writeAll("</style></head><body>");
        try w.writeAll("<h1>merjs debug</h1>");

        try w.writeAll("<h2>Routes</h2><table><tr><th>Path</th><th>Type</th></tr>");
        for (routes) |route| {
            const rtype: []const u8 = if (std.mem.startsWith(u8, route.path, "/api/")) "API" else "Page";
            try w.print("<tr><td>{s}</td><td>{s}</td></tr>", .{ route.path, rtype });
        }
        try w.writeAll("</table>");

        try w.writeAll("<h2>Config</h2><table>");
        try w.print("<tr><td>Version</td><td>{s}</td></tr>", .{version});
        try w.print("<tr><td>Zig</td><td>{s}</td></tr>", .{@import("builtin").zig_version_string});
        try w.print("<tr><td>Routes</td><td>{d} exact + {d} dynamic</td></tr>", .{ exact_count, dynamic_count });
        try w.writeAll("</table>");

        // Metrics section.
        const report = metrics.collect(alloc) catch metrics.Report{
            .total_requests = 0,
            .window = 0,
            .ttfb = .{},
            .duration = .{},
            .routes = &.{},
        };
        try w.print("<h2>Metrics <small>(last {d} of {d} requests)</small></h2>", .{ report.window, report.total_requests });
        try w.writeAll("<table><tr><th>Metric</th><th>avg</th><th>p50</th><th>p95</th><th>p99</th><th>max</th></tr>");
        try writeStatRow(w, "TTFB (\u{00b5}s)", report.ttfb);
        try writeStatRow(w, "Duration (\u{00b5}s)", report.duration);
        try w.writeAll("</table>");

        if (report.routes.len > 0) {
            try w.writeAll("<h2>Per-route</h2><table><tr><th>Path</th><th>count</th><th>avg TTFB (\u{00b5}s)</th><th>avg dur (\u{00b5}s)</th></tr>");
            for (report.routes) |r| {
                try w.print("<tr><td>{s}</td><td>{d}</td><td>{d}</td><td>{d}</td></tr>", .{ r.path, r.count, r.avg_ttfb_us, r.avg_duration_us });
            }
            try w.writeAll("</table>");
        }

        try w.writeAll("<h2>Hints</h2><ul>");
        try w.writeAll("<li>Run with <code>--verbose</code> to log per-request timing</li>");
        try w.writeAll("<li>Use <code>std.log.scoped(.mypage)</code> in page handlers for route-level logs</li>");
        try w.writeAll("<li><code>/_mer/events</code> — SSE hot reload stream</li>");
        try w.writeAll("<li>Append <code>?format=json</code> to this URL for machine-readable output</li>");
        try w.writeAll("<li>Run with <code>--debug</code> to enable kuri browser automation at <code>/_mer/kuri/</code></li>");
        try w.writeAll("</ul>");

        try w.writeAll("</body></html>");

        return res_mod.Response.init(.ok, .html, body.written());
    }
}
