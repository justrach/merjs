const std = @import("std");

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    unknown,

    pub fn fromStd(m: std.http.Method) Method {
        return switch (m) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
            .PATCH => .PATCH,
            .HEAD => .HEAD,
            .OPTIONS => .OPTIONS,
            else => .unknown,
        };
    }
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, method: Method, path: []const u8) Request {
        return .{ .allocator = allocator, .method = method, .path = path };
    }
};
