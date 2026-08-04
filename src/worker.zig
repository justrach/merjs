// worker.zig — Cloudflare Workers WASM entry point.
// Exports handle() for the JS shim to call on each fetch event.
//
// Protocol (shared memory):
//   Request  → six u32 LE fields (five lengths + header count), then
//              method, path+query, body, cookie, trusted client identity,
//              and length-prefixed headers
//   Response → "MER1", u16 protocol version, u16 status, u16 header count,
//              u16 reserved, u32 body length, then repeated u16 name length +
//              u32 value length + bytes, followed by the response body.

const std = @import("std");
const mer = @import("mer");
const dispatch_mod = @import("dispatch.zig");
const Router = @import("router.zig").Router;

var router: ?Router = null;

const max_request_bytes: usize = 2 * 1024 * 1024;
const max_request_target_bytes: usize = 16 * 1024;
const max_request_body_bytes: usize = 1024 * 1024;
const max_cookie_bytes: usize = 16 * 1024;
const max_client_identity_bytes: usize = 256;
const max_header_bytes: usize = 64 * 1024;
const max_headers: usize = 16;
const response_magic: u32 = 0x3152454d; // "MER1" in little-endian memory.
const response_protocol_version: u16 = 1;
const max_response_bytes: usize = 32 * 1024 * 1024;
const max_response_headers: usize = 10;
const max_response_header_name_bytes: usize = 64;
const max_response_header_value_bytes: usize = 4096;
const max_response_header_bytes: usize = 32 * 1024;
const max_response_cookies: usize = 8;

const IncomingRequest = struct {
    method: mer.Method,
    path: []const u8,
    query: []const u8,
    body: []const u8,
    cookies: []const u8,
    client_identity: ?[]const u8,
    headers: []const std.http.Header,
};

fn decodeRequest(input: []const u8, header_storage: []std.http.Header) ?IncomingRequest {
    if (input.len < 24 or input.len > max_request_bytes) return null;
    const method_len: usize = std.mem.readInt(u32, input[0..4], .little);
    const target_len: usize = std.mem.readInt(u32, input[4..8], .little);
    const body_len: usize = std.mem.readInt(u32, input[8..12], .little);
    const cookie_len: usize = std.mem.readInt(u32, input[12..16], .little);
    const identity_len: usize = std.mem.readInt(u32, input[16..20], .little);
    const header_count: usize = std.mem.readInt(u32, input[20..24], .little);
    if (method_len == 0 or method_len > 16 or target_len == 0 or target_len > max_request_target_bytes or
        body_len > max_request_body_bytes or cookie_len > max_cookie_bytes or
        identity_len > max_client_identity_bytes or header_count > max_headers or
        header_count > header_storage.len) return null;
    const payload_len = std.math.add(usize, method_len, target_len) catch return null;
    const with_body = std.math.add(usize, payload_len, body_len) catch return null;
    const with_cookie = std.math.add(usize, with_body, cookie_len) catch return null;
    const fixed_end = std.math.add(usize, 24 + with_cookie, identity_len) catch return null;
    if (fixed_end > input.len) return null;

    var offset: usize = 24;
    const method_bytes = input[offset .. offset + method_len];
    offset += method_len;
    const target = input[offset .. offset + target_len];
    offset += target_len;
    const body = input[offset .. offset + body_len];
    offset += body_len;
    const cookies = input[offset .. offset + cookie_len];
    offset += cookie_len;
    const client_identity = input[offset .. offset + identity_len];
    offset += identity_len;
    const headers_start = offset;
    for (header_storage[0..header_count]) |*header| {
        if (offset + 8 > input.len) return null;
        const name_len: usize = std.mem.readInt(u32, input[offset..][0..4], .little);
        const value_len: usize = std.mem.readInt(u32, input[offset + 4 ..][0..4], .little);
        offset += 8;
        const entry_len = std.math.add(usize, name_len, value_len) catch return null;
        if (name_len == 0 or entry_len > max_header_bytes or entry_len > input.len - offset) return null;
        header.* = .{ .name = input[offset .. offset + name_len], .value = input[offset + name_len .. offset + entry_len] };
        offset += entry_len;
    }
    if (offset != input.len or offset - headers_start > max_header_bytes) return null;

    const query_at = std.mem.indexOfScalar(u8, target, '?');
    const path = if (query_at) |at| target[0..at] else target;
    const query = if (query_at) |at| target[at + 1 ..] else "";
    if (path.len == 0 or path[0] != '/') return null;
    return .{ .method = parseMethod(method_bytes), .path = path, .query = query, .body = body, .cookies = cookies, .client_identity = if (client_identity.len == 0) null else client_identity, .headers = header_storage[0..header_count] };
}

var incoming_headers: [max_headers]std.http.Header = undefined;

fn makeRequest(input: []const u8) ?mer.Request {
    const incoming = decodeRequest(input, &incoming_headers) orelse return null;
    var req = mer.Request.init(allocator, incoming.method, incoming.path);
    req.query_string = incoming.query;
    req.body = incoming.body;
    req.cookies_raw = incoming.cookies;
    req.headers = incoming.headers;
    req.client_identity = incoming.client_identity;
    return req;
}

/// Allocator for WASM — backed by WebAssembly pages.
const allocator = std.heap.wasm_allocator;

/// Called once by the JS shim to initialize the router.
export fn init() void {
    // Force analysis of the status-returning export even when application
    // routes do not read environment bindings themselves.
    _ = mer.__mer_set_env_status;
    router = Router.fromGenerated(allocator, @import("routes"));
}

/// Allocate `len` bytes in WASM memory. Returns pointer for JS to write into.
export fn alloc(len: u32) ?[*]u8 {
    if (len > 8 * 1024 * 1024) return null;
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Free a previously allocated buffer.
export fn dealloc(ptr: [*]u8, len: u32) void {
    allocator.free(ptr[0..len]);
}

/// Handle a request. `req_ptr` points to the bounded binary request written by JS.
/// Returns a pointer to the response buffer. JS reads the length from `response_len()`.
var last_response: ?[]u8 = null;
var last_requests: []const u8 = "";
var last_fetch_error: u32 = 0;
var request_dispatch_count: u32 = 0;

/// Phase 1: collect a bounded binary request list during a dry render.
/// Returns its pointer; call `collect_urls_len()` for the byte length.
export fn collect_fetch_urls(req_ptr: [*]const u8, req_len: u32) [*]const u8 {
    last_requests = "";
    last_fetch_error = 0;
    const req = makeRequest(req_ptr[0..req_len]) orelse {
        _ = mer.wasmClearCacheV2();
        return "".ptr;
    };
    const r = router orelse {
        _ = mer.wasmClearCacheV2();
        return "".ptr;
    };
    mer.wasmBeginCollect();
    request_dispatch_count +%= 1;
    const response = dispatch_mod.dispatchBuffered(r, req);
    response.deinit();
    const collected = mer.wasmEndCollectV2();
    last_requests = collected.bytes;
    last_fetch_error = collected.error_code;
    return last_requests.ptr;
}

export fn collect_urls_len() u32 {
    return @intCast(last_requests.len);
}

export fn expected_state_ptr() [*]const u8 {
    return mer.wasmExpectedState().ptr;
}

export fn expected_state_len() u32 {
    return @intCast(mer.wasmExpectedState().len);
}

export fn restore_expected_state(ptr: [*]const u8, len: u32) u32 {
    return mer.wasmRestoreExpectedState(ptr[0..len]);
}

export fn dispatch_count() u32 {
    return request_dispatch_count;
}

/// Phase 2 (per request ID): JS provides status and a bounded response body.
export fn provide_fetch_result(id: u32, status: u32, body_ptr: [*]const u8, body_len: u32) u32 {
    return mer.wasmProvideResultV2(id, status, body_ptr[0..body_len]);
}

export fn fetch_protocol_error() u32 {
    return last_fetch_error;
}

const EncodedHeader = struct { name: []const u8, value: []const u8 };

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_response_header_name_bytes) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    return true;
}

fn validHeaderValue(value: []const u8) bool {
    if (value.len > max_response_header_value_bytes) return false;
    for (value) |c| if (c == 0 or c == '\r' or c == '\n' or (c < 0x20 and c != '\t') or c == 0x7f) return false;
    return true;
}

fn validCookie(cookie: mer.SetCookie) bool {
    if (!validHeaderName(cookie.name) or cookie.value.len == 0) return false;
    for (cookie.value) |c| if (c <= 0x20 or c >= 0x7f or c == ';' or c == ',') return false;
    if (cookie.path.len == 0) return false;
    for (cookie.path) |c| if (c < 0x20 or c >= 0x7f or c == ';') return false;
    var length = cookie.name.len + 1 + cookie.value.len + "; Path=".len + cookie.path.len;
    if (cookie.max_age) |age| {
        var digits: usize = 1;
        var remaining = age;
        while (remaining >= 10) : (remaining /= 10) digits += 1;
        length += "; Max-Age=".len + digits;
    }
    if (cookie.http_only) length += "; HttpOnly".len;
    if (cookie.secure) length += "; Secure".len;
    length += "; SameSite=".len + switch (cookie.same_site) {
        .strict => @as(usize, 6),
        .lax => 3,
        .none => 4,
    };
    return length < 512;
}

fn encodeResponse(response: mer.Response) ?[]u8 {
    if (response.cookies.len > max_response_cookies) return null;
    var cookie_values: [max_response_cookies][512]u8 = undefined;
    var headers: [2 + max_response_cookies]EncodedHeader = undefined;
    var header_count: usize = 0;
    headers[header_count] = .{ .name = "content-type", .value = response.content_type.mime() };
    header_count += 1;
    const is_redirect = response.content_type == .redirect;
    const status_int: u16 = @intFromEnum(response.status);
    if (is_redirect and (response.body.len == 0 or status_int < 300 or status_int >= 400)) return null;
    if (is_redirect) {
        headers[header_count] = .{ .name = "location", .value = response.body };
        header_count += 1;
    }
    for (response.cookies, 0..) |cookie, i| {
        if (!validCookie(cookie)) return null;
        const value = cookie.headerValue(&cookie_values[i]);
        if (value.len == 0 or value.len == cookie_values[i].len) return null;
        headers[header_count] = .{ .name = "set-cookie", .value = value };
        header_count += 1;
    }
    if (header_count > max_response_headers) return null;

    var header_bytes: usize = 0;
    for (headers[0..header_count]) |header| {
        if (!validHeaderName(header.name) or !validHeaderValue(header.value)) return null;
        header_bytes = std.math.add(usize, header_bytes, 6 + header.name.len + header.value.len) catch return null;
    }
    if (header_bytes > max_response_header_bytes) return null;
    const body = if (is_redirect) "" else response.body;
    const total = std.math.add(usize, 16 + header_bytes, body.len) catch return null;
    if (total > max_response_bytes) return null;
    const buf = allocator.alloc(u8, total) catch return null;

    std.mem.writeInt(u32, buf[0..4], response_magic, .little);
    std.mem.writeInt(u16, buf[4..6], response_protocol_version, .little);
    std.mem.writeInt(u16, buf[6..8], status_int, .little);
    std.mem.writeInt(u16, buf[8..10], @intCast(header_count), .little);
    std.mem.writeInt(u16, buf[10..12], 0, .little);
    std.mem.writeInt(u32, buf[12..16], @intCast(body.len), .little);
    var offset: usize = 16;
    for (headers[0..header_count]) |header| {
        std.mem.writeInt(u16, buf[offset..][0..2], @intCast(header.name.len), .little);
        std.mem.writeInt(u32, buf[offset + 2 ..][0..4], @intCast(header.value.len), .little);
        offset += 6;
        @memcpy(buf[offset .. offset + header.name.len], header.name);
        offset += header.name.len;
        @memcpy(buf[offset .. offset + header.value.len], header.value);
        offset += header.value.len;
    }
    @memcpy(buf[offset..], body);
    return buf;
}

export fn handle(req_ptr: [*]const u8, req_len: u32) ?[*]const u8 {
    // Free previous response.
    if (last_response) |prev| allocator.free(prev);
    last_response = null;
    defer last_fetch_error = mer.wasmClearCacheV2();

    const req = makeRequest(req_ptr[0..req_len]) orelse return null;
    const r = router orelse return null;
    request_dispatch_count +%= 1;
    const response = dispatch_mod.dispatchBuffered(r, req);
    defer response.deinit();

    const buf = encodeResponse(response) orelse return null;
    last_response = buf;
    return buf.ptr;
}

/// Returns the length of the last response buffer.
export fn response_len() u32 {
    return if (last_response) |r| @intCast(r.len) else 0;
}

/// Release response bytes as soon as JS has copied them.
export fn response_done() void {
    if (last_response) |response| allocator.free(response);
    last_response = null;
}

test "binary request protocol preserves method target body cookies and headers" {
    const method = "POST";
    const target = "/submit?q=zig";
    const body = "name=mer";
    const cookies = "session=abc; theme=dark";
    const client_identity = "198.51.100.8";
    const header_name = "content-type";
    const header_value = "application/x-www-form-urlencoded";
    var bytes: [32 + method.len + target.len + body.len + cookies.len + client_identity.len + header_name.len + header_value.len]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], method.len, .little);
    std.mem.writeInt(u32, bytes[4..8], target.len, .little);
    std.mem.writeInt(u32, bytes[8..12], body.len, .little);
    std.mem.writeInt(u32, bytes[12..16], cookies.len, .little);
    std.mem.writeInt(u32, bytes[16..20], client_identity.len, .little);
    std.mem.writeInt(u32, bytes[20..24], 1, .little);
    var offset: usize = 24;
    for ([_][]const u8{ method, target, body, cookies, client_identity }) |part| {
        @memcpy(bytes[offset .. offset + part.len], part);
        offset += part.len;
    }
    std.mem.writeInt(u32, bytes[offset..][0..4], header_name.len, .little);
    std.mem.writeInt(u32, bytes[offset + 4 ..][0..4], header_value.len, .little);
    offset += 8;
    @memcpy(bytes[offset .. offset + header_name.len], header_name);
    offset += header_name.len;
    @memcpy(bytes[offset .. offset + header_value.len], header_value);

    var headers: [max_headers]std.http.Header = undefined;
    const incoming = decodeRequest(&bytes, &headers).?;
    try std.testing.expectEqual(mer.Method.POST, incoming.method);
    try std.testing.expectEqualStrings("/submit", incoming.path);
    try std.testing.expectEqualStrings("q=zig", incoming.query);
    try std.testing.expectEqualStrings(body, incoming.body);
    try std.testing.expectEqualStrings(cookies, incoming.cookies);
    try std.testing.expectEqualStrings(client_identity, incoming.client_identity.?);
    try std.testing.expectEqualStrings(header_value, incoming.headers[0].value);
}

test "binary request protocol enforces body cookie identity and header bounds" {
    var header: [24]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], 3, .little);
    std.mem.writeInt(u32, header[4..8], 1, .little);
    std.mem.writeInt(u32, header[8..12], max_request_body_bytes + 1, .little);
    var headers: [max_headers]std.http.Header = undefined;
    try std.testing.expect(decodeRequest(&header, &headers) == null);
    std.mem.writeInt(u32, header[8..12], 0, .little);
    std.mem.writeInt(u32, header[12..16], max_cookie_bytes + 1, .little);
    try std.testing.expect(decodeRequest(&header, &headers) == null);
    std.mem.writeInt(u32, header[12..16], 0, .little);
    std.mem.writeInt(u32, header[16..20], max_client_identity_bytes + 1, .little);
    try std.testing.expect(decodeRequest(&header, &headers) == null);
    std.mem.writeInt(u32, header[16..20], 0, .little);
    std.mem.writeInt(u32, header[20..24], max_headers + 1, .little);
    try std.testing.expect(decodeRequest(&header, &headers) == null);
}

test "response protocol preserves redirect location and repeated cookies" {
    const response = mer.withCookies(mer.redirect("/dashboard", .see_other), &.{
        .{ .name = "session", .value = "abc", .secure = true },
        .{ .name = "csrf", .value = "xyz", .http_only = false, .same_site = .strict },
    });
    const encoded = encodeResponse(response).?;
    defer allocator.free(encoded);
    try std.testing.expectEqual(response_magic, std.mem.readInt(u32, encoded[0..4], .little));
    try std.testing.expectEqual(response_protocol_version, std.mem.readInt(u16, encoded[4..6], .little));
    try std.testing.expectEqual(@as(u16, 303), std.mem.readInt(u16, encoded[6..8], .little));
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, encoded[8..10], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, encoded[12..16], .little));
    try std.testing.expect(std.mem.indexOf(u8, encoded, "location/dashboard") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, encoded, "set-cookie"));
}

test "response protocol rejects malformed and bounded metadata" {
    try std.testing.expect(!validHeaderName("Location"));
    try std.testing.expect(!validHeaderName("bad header"));
    try std.testing.expect(!validHeaderValue("ok\r\ninjected: yes"));
    try std.testing.expect(encodeResponse(mer.withCookies(mer.html("ok"), &.{
        .{ .name = "session", .value = "bad\r\nvalue" },
    })) == null);
    const too_many = [_]mer.SetCookie{.{ .name = "a", .value = "b" }} ** (max_response_cookies + 1);
    try std.testing.expect(encodeResponse(mer.withCookies(mer.html("ok"), &too_many)) == null);
    const oversized_location = [_]u8{'x'} ** (max_response_header_value_bytes + 1);
    try std.testing.expect(encodeResponse(mer.redirect(&oversized_location, .found)) == null);
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
