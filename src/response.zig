const std = @import("std");

pub const ContentType = enum {
    html,
    json,
    text,
    css,
    js,
    wasm,
    octet_stream,

    pub fn mime(self: ContentType) []const u8 {
        return switch (self) {
            .html => "text/html; charset=utf-8",
            .json => "application/json",
            .text => "text/plain; charset=utf-8",
            .css  => "text/css; charset=utf-8",
            .js   => "application/javascript",
            .wasm => "application/wasm",
            .octet_stream => "application/octet-stream",
        };
    }
};

pub const Response = struct {
    status: std.http.Status,
    content_type: ContentType,
    body: []const u8,

    pub fn init(status: std.http.Status, ct: ContentType, body: []const u8) Response {
        return .{ .status = status, .content_type = ct, .body = body };
    }
};

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
