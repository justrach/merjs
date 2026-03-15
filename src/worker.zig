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

export fn handle(req_ptr: [*]const u8, req_len: u32) ?[*]const u8 {
    // Free previous response.
    if (last_response) |prev| allocator.free(prev);
    last_response = null;

    const input = req_ptr[0..req_len];

    // Parse "GET /path"
    const space_idx = std.mem.indexOfScalar(u8, input, ' ') orelse return null;
    const method_str = input[0..space_idx];
    const path = input[space_idx + 1 ..];

    const method: mer.Method = if (std.mem.eql(u8, method_str, "GET"))
        .GET
    else if (std.mem.eql(u8, method_str, "POST"))
        .POST
    else if (std.mem.eql(u8, method_str, "PUT"))
        .PUT
    else if (std.mem.eql(u8, method_str, "DELETE"))
        .DELETE
    else if (std.mem.eql(u8, method_str, "PATCH"))
        .PATCH
    else if (std.mem.eql(u8, method_str, "HEAD"))
        .HEAD
    else if (std.mem.eql(u8, method_str, "OPTIONS"))
        .OPTIONS
    else
        .unknown;

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
