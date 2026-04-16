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
            .html => "text/html; charset=utf-8",
            .json => "application/json",
            .text => "text/plain; charset=utf-8",
            .css => "text/css; charset=utf-8",
            .js => "application/javascript",
            .wasm => "application/wasm",
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .svg => "image/svg+xml",
            .ico => "image/x-icon",
            .webp => "image/webp",
            .octet_stream => "application/octet-stream",
            .redirect => "text/html; charset=utf-8",
        };
    }
};

// ── Set-Cookie ─────────────────────────────────────────────────────────────

pub const SameSite = enum { strict, lax, none };

/// A cookie to emit via Set-Cookie. All slices must outlive the Response.
pub const SetCookie = struct {
    name: []const u8,
    value: []const u8,
    path: []const u8 = "/",
    max_age: ?u32 = null,
    http_only: bool = true,
    secure: bool = false,
    same_site: SameSite = .lax,

    /// Format the Set-Cookie header value into `buf`. Returns the written slice.
    /// Silently truncates if `buf` is too small (512 bytes is always enough).
    pub fn headerValue(self: SetCookie, buf: []u8) []const u8 {
        // 0.16: fixedBufferStream removed. Manual offset tracking.
        var pos: usize = 0;
        const base = std.fmt.bufPrint(buf, "{s}={s}; Path={s}", .{ self.name, self.value, self.path }) catch return buf[0..0];
        pos = base.len;
        if (self.max_age) |age| { const s = std.fmt.bufPrint(buf[pos..], "; Max-Age={d}", .{age}) catch ""; pos += s.len; }
        if (self.http_only) { const s = std.fmt.bufPrint(buf[pos..], "; HttpOnly", .{}) catch ""; pos += s.len; }
        if (self.secure) { const s = std.fmt.bufPrint(buf[pos..], "; Secure", .{}) catch ""; pos += s.len; }
        const ss: []const u8 = switch (self.same_site) {
            .strict => "Strict",
            .lax => "Lax",
            .none => "None",
        };
        const s2 = std.fmt.bufPrint(buf[pos..], "; SameSite={s}", .{ss}) catch "";
        pos += s2.len;
        return buf[0..pos];
    }
};

// ── Response ───────────────────────────────────────────────────────────────

pub const Response = struct {
    status: std.http.Status,
    content_type: ContentType,
    body: []const u8,
    /// Cookies to emit as Set-Cookie headers. Slice must outlive the Response.
    cookies: []const SetCookie = &.{},

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
    return .{ .status = status, .content_type = .redirect, .body = location };
}

/// Return a copy of `res` with its `cookies` field replaced.
///
///   return mer.withCookies(mer.redirect("/dashboard", .see_other), &.{
///       .{ .name = "session", .value = token, .max_age = 86400 },
///   });
pub fn withCookies(res: Response, cookies: []const SetCookie) Response {
    var r = res;
    r.cookies = cookies;
    return r;
}
