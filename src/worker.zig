// worker.zig — Cloudflare Workers WASM entry point.
// Exports handle() for the JS shim to call on each fetch event.
//
// Protocol (shared memory):
//   Request  → "GET /path" (method + space + path, written by JS)
//   Response → first 4 bytes: u16 status (LE) + u16 content_type_len (LE)
//              next content_type_len bytes: content-type string
//              remaining bytes: response body

const std = @import("std");
const mer = @import("mer");
const ssr = @import("ssr.zig");
const Router = @import("router.zig").Router;

var router: ?Router = null;

/// Allocator for WASM — backed by WebAssembly pages.
const allocator = std.heap.wasm_allocator;

/// Called once by the JS shim to initialize the router.
export fn init() void {
    router = ssr.buildRouter(allocator);
}

/// Allocate `len` bytes in WASM memory. Returns pointer for JS to write into.
export fn alloc(len: u32) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Free a previously allocated buffer.
export fn dealloc(ptr: [*]u8, len: u32) void {
    allocator.free(ptr[0..len]);
}

/// Handle a request. `req_ptr` points to "METHOD /path" written by JS.
/// Returns a pointer to the response buffer. JS reads the length from `response_len()`.
var last_response: ?[]u8 = null;
var last_urls: []const u8 = "";

/// Phase 1: run renderStream in collect mode to discover which URLs are needed.
/// Returns pointer to newline-delimited URL list; call `collect_urls_len()` for length.
export fn collect_fetch_urls(req_ptr: [*]const u8, req_len: u32) [*]const u8 {
    const input = req_ptr[0..req_len];
    const space_idx = std.mem.indexOfScalar(u8, input, ' ') orelse return "".ptr;
    const method = parseMethod(input[0..space_idx]);
    const path = input[space_idx + 1 ..];
    const r = router orelse return "".ptr;
    const req = mer.Request.init(allocator, method, path);
    mer.wasmBeginCollect();
    _ = r.dispatchBuffered(req);
    last_urls = mer.wasmEndCollect();
    return last_urls.ptr;
}

export fn collect_urls_len() u32 {
    return @intCast(last_urls.len);
}

/// Phase 2 (per URL): JS provides a fetched result before calling handle().
export fn provide_fetch_result(url_ptr: [*]const u8, url_len: u32, body_ptr: [*]const u8, body_len: u32) void {
    mer.wasmProvideResult(url_ptr[0..url_len], body_ptr[0..body_len]);
}

export fn handle(req_ptr: [*]const u8, req_len: u32) ?[*]const u8 {
    // Free previous response.
    if (last_response) |prev| allocator.free(prev);
    last_response = null;
    defer mer.wasmClearCache();

    const input = req_ptr[0..req_len];
    const space_idx = std.mem.indexOfScalar(u8, input, ' ') orelse return null;
    const method = parseMethod(input[0..space_idx]);
    const path = input[space_idx + 1 ..];

    const r = router orelse return null;
    const req = mer.Request.init(allocator, method, path);
    const response = r.dispatchBuffered(req);

    // Encode response: status_u16 LE | ct_len_u16 LE | content-type | body
    const ct_str = response.content_type.mime();
    const total = 4 + ct_str.len + response.body.len;
    const buf = allocator.alloc(u8, total) catch return null;

    const status_int: u16 = @intFromEnum(response.status);
    const ct_len: u16 = @intCast(ct_str.len);
    std.mem.writeInt(u16, buf[0..2], status_int, .little);
    std.mem.writeInt(u16, buf[2..4], ct_len, .little);
    @memcpy(buf[4 .. 4 + ct_str.len], ct_str);
    @memcpy(buf[4 + ct_str.len ..], response.body);

    last_response = buf;
    return buf.ptr;
}

/// Returns the length of the last response buffer.
export fn response_len() u32 {
    return if (last_response) |r| @intCast(r.len) else 0;
}

fn parseMethod(s: []const u8) mer.Method {
    if (std.mem.eql(u8, s, "GET")) return .GET;
    if (std.mem.eql(u8, s, "POST")) return .POST;
    if (std.mem.eql(u8, s, "PUT")) return .PUT;
    if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
    if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
    if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
    if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
    return .unknown;
}
