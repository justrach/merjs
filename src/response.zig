const std = @import("std");

pub const ContentType = enum {
    html,
    json,
    text,
    css,
    js,
    wasm,
    png,
    jpeg,
    gif,
    svg,
    ico,
    webp,
    octet_stream,
    /// Internal sentinel used by redirect(). server.zig emits Location header.
    redirect,

    pub fn mime(self: ContentType) []const u8 {
        return switch (self) {
            .html         => "text/html; charset=utf-8",
            .json         => "application/json",
            .text         => "text/plain; charset=utf-8",
            .css          => "text/css; charset=utf-8",
            .js           => "application/javascript",
            .wasm         => "application/wasm",
            .png          => "image/png",
            .jpeg         => "image/jpeg",
            .gif          => "image/gif",
            .svg          => "image/svg+xml",
            .ico          => "image/x-icon",
            .webp         => "image/webp",
            .octet_stream => "application/octet-stream",
            .redirect     => "text/html; charset=utf-8",
        };
    }
};

pub const Response = struct {
    status:       std.http.Status,
    content_type: ContentType,
    body:         []const u8,

    pub fn init(status: std.http.Status, ct: ContentType, body: []const u8) Response {
        return .{ .status = status, .content_type = ct, .body = body };
    }
};

// ── Response helpers ───────────────────────────────────────────────────────

pub fn html(body: []const u8) Response {
    return Response.init(.ok, .html, body);
}

pub fn json(body: []const u8) Response {
    return Response.init(.ok, .json, body);
}

pub fn text(status: std.http.Status, body: []const u8) Response {
    return Response.init(status, .text, body);
}

pub fn notFound() Response {
    return Response.init(.not_found, .html, "<h1>404 Not Found</h1>");
}

pub fn internalError(msg: []const u8) Response {
    return Response.init(.internal_server_error, .html, msg);
}

/// HTTP redirect. `location` must be a stable slice (comptime string or arena).
///
///   return mer.redirect("/login", .found);               // 302
///   return mer.redirect("/dashboard", .see_other);       // 303 — after POST
///   return mer.redirect("/new-path", .moved_permanently);// 301
pub fn redirect(location: []const u8, status: std.http.Status) Response {
    // body carries the Location URL; server.zig detects content_type == .redirect.
    return .{ .status = status, .content_type = .redirect, .body = location };
}
