const std = @import("std");
const mer = @import("mer");
const zigly = @import("zigly");

const allocator = std.heap.wasm_allocator;

pub fn main() !void {
    const router = mer.Router.fromGenerated(allocator, @import("routes"));

    var downstream = try zigly.downstream();

    var uri_buf: [8192]u8 = undefined;
    const path = try downstream.request.getPath(&uri_buf);
    if (try tryServeStatic(&downstream, path)) return;

    const req = try buildMerRequest(&downstream, path, &uri_buf);

    mer.h.setRenderAllocator(allocator);
    mer.setWasiFetch(&fastlyFetch);

    const response = mer.dispatch.dispatchBuffered(router, req);

    try sendFastlyResponse(&downstream, response);
}

fn buildMerRequest(
    downstream: *zigly.http.Downstream,
    path: []const u8,
    uri_buf: *[8192]u8,
) !mer.Request {
    var method_buf: [16]u8 = undefined;
    const method_str = try downstream.request.getMethod(&method_buf);
    const method = parseFastlyMethod(method_str);

    const uri = try downstream.request.getUri(uri_buf);
    const query_string = if (uri.query) |q| switch (q) {
        .raw => |r| r,
        .percent_encoded => |e| e,
    } else "";

    const owned_path = try allocator.dupe(u8, path);
    const owned_qs = try allocator.dupe(u8, query_string);

    var req = mer.Request.init(allocator, method, owned_path);
    req.query_string = owned_qs;
    req.body = downstream.request.body.readAll(allocator, 4 * 1024 * 1024) catch |err| blk: {
        std.log.warn("fastly: body read failed: {s}", .{@errorName(err)});
        break :blk "";
    };
    req.cookies_raw = downstream.request.headers.get(allocator, "Cookie") catch |err| blk: {
        std.log.warn("fastly: cookie header read failed: {s}", .{@errorName(err)});
        break :blk "";
    };

    return req;
}

fn sendFastlyResponse(downstream: *zigly.http.Downstream, response: mer.Response) !void {
    var resp = downstream.response;

    const status: u16 = @intFromEnum(response.status);
    try resp.setStatus(status);

    for (response.cookies) |ck| {
        var buf: [512]u8 = undefined;
        const val = ck.headerValue(&buf);
        const owned = try allocator.dupe(u8, val);
        try resp.headers.append(allocator, "Set-Cookie", owned);
    }

    if (response.content_type == .redirect) {
        try resp.headers.set("Location", response.body);
        try resp.finish();
        return;
    }

    for (mer.security_headers) |hdr| {
        try resp.headers.set(hdr.name, hdr.value);
    }

    try resp.headers.set("Content-Type", response.content_type.mime());
    try resp.body.writeAll(response.body);
    try resp.finish();
}

fn fastlyFetch(alloc: std.mem.Allocator, opts: mer.FetchRequest) anyerror!mer.FetchResponse {
    var upstream = try zigly.http.Request.new(@tagName(opts.method), opts.url);
    for (opts.headers) |h| {
        try upstream.headers.set(h.name, h.value);
    }
    if (opts.body) |b| try upstream.body.writeAll(b);

    const backend_name = resolveBackend(opts.url);
    var resp = try upstream.send(backend_name);

    const body = try resp.body.readAll(alloc, 10 * 1024 * 1024);
    const status_int = try resp.getStatus();
    return .{
        .status = @enumFromInt(status_int),
        .body = body,
    };
}

const BackendMapping = struct {
    origin: []const u8,
    backend: []const u8,
};

const backend_mappings = [_]BackendMapping{};
const default_backend = "origin";

fn resolveBackend(url: []const u8) []const u8 {
    for (&backend_mappings) |m| {
        if (std.mem.startsWith(u8, url, m.origin)) return m.backend;
    }
    return default_backend;
}

const static_assets = @import("static_assets");

fn tryServeStatic(downstream: *zigly.http.Downstream, path: []const u8) !bool {
    const asset = static_assets.get(path) orelse return false;

    var resp = downstream.response;
    try resp.setStatus(200);
    try resp.headers.set("Content-Type", asset.content_type);
    try resp.headers.set("Cache-Control", "public, max-age=31536000, immutable");
    try resp.body.writeAll(asset.data);
    try resp.finish();
    return true;
}

fn parseFastlyMethod(s: []const u8) mer.Method {
    if (std.mem.eql(u8, s, "GET")) return .GET;
    if (std.mem.eql(u8, s, "POST")) return .POST;
    if (std.mem.eql(u8, s, "PUT")) return .PUT;
    if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
    if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
    if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
    if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
    return .unknown;
}
