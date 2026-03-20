// worker_entry.zig — self-contained Cloudflare Workers entry for the kanban example.
// Manually wires routes so this example doesn't depend on the main codegen.

const std = @import("std");
const mer = @import("mer");
const Router = @import("router.zig").Router;
const dispatch_mod = @import("dispatch.zig");
const index_page = @import("examples/kanban/app/index");
const layout_mod = @import("examples/kanban/app/layout");

var router: ?Router = null;
const allocator = std.heap.wasm_allocator;

export fn init() void {
    var r = Router.init(allocator, &.{
        .{
            .path = "/",
            .render = index_page.render,
            .render_stream = if (@hasDecl(index_page, "renderStream")) index_page.renderStream else null,
            .meta = if (@hasDecl(index_page, "meta")) index_page.meta else .{},
            .prerender = false,
        },
    });
    r.layout = layout_mod.wrap;
    router = r;
}

export fn alloc(len: u32) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn dealloc(ptr: [*]u8, len: u32) void {
    allocator.free(ptr[0..len]);
}

var last_response: ?[]u8 = null;
var last_urls: []const u8 = "";

export fn collect_fetch_urls(req_ptr: [*]const u8, req_len: u32) [*]const u8 {
    const input = req_ptr[0..req_len];
    const space_idx = std.mem.indexOfScalar(u8, input, ' ') orelse return "".ptr;
    const method = parseMethod(input[0..space_idx]);
    const path = input[space_idx + 1 ..];
    const r = router orelse return "".ptr;
    const req = mer.Request.init(allocator, method, path);
    mer.wasmBeginCollect();
    _ = dispatch_mod.dispatchBuffered(r, req);
    last_urls = mer.wasmEndCollect();
    return last_urls.ptr;
}

export fn collect_urls_len() u32 {
    return @intCast(last_urls.len);
}

export fn provide_fetch_result(url_ptr: [*]const u8, url_len: u32, body_ptr: [*]const u8, body_len: u32) void {
    mer.wasmProvideResult(url_ptr[0..url_len], body_ptr[0..body_len]);
}

export fn handle(req_ptr: [*]const u8, req_len: u32) ?[*]const u8 {
    if (last_response) |prev| allocator.free(prev);
    last_response = null;
    defer mer.wasmClearCache();

    const input = req_ptr[0..req_len];
    const space_idx = std.mem.indexOfScalar(u8, input, ' ') orelse return null;
    const method = parseMethod(input[0..space_idx]);
    const path = input[space_idx + 1 ..];

    const r = router orelse return null;
    const req = mer.Request.init(allocator, method, path);
    const response = dispatch_mod.dispatchBuffered(r, req);

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
