// mer-shared.zig — worker-safe public API shared by native and worker builds.
// Keep native-only server, session, telemetry, and watcher imports out of here.

const std = @import("std");
const req_mod = @import("request.zig");
const res_mod = @import("response.zig");
const fetch_mod = @import("fetch.zig");
const env_mod = @import("env.zig");

pub const mercss = @import("mercss.zig");
pub const design = @import("mercss-design.zig");
/// Deprecated demo-only compatibility API. Removed in 0.3.0.
pub const mercss_compat = @import("mercss_compat.zig").declarations(mercss.Component, mercss.ResponsiveComponent, mercss.InteractiveComponent);
pub const version = "0.2.5";

pub const StreamParts = struct {
    head: []const u8,
    tail: []const u8,
    head_allocator: ?std.mem.Allocator = null,
    tail_allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: StreamParts) void {
        if (self.head_allocator) |allocator| allocator.free(@constCast(self.head));
        if (self.tail_allocator) |allocator| allocator.free(@constCast(self.tail));
    }
};

pub const StreamWriter = struct {
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, data: []const u8) void,
    flushFn: *const fn (ctx: *anyopaque) void,
    failedFn: ?*const fn (ctx: *anyopaque) bool = null,

    pub fn write(self: *StreamWriter, data: []const u8) void {
        self.writeFn(self.ctx, data);
    }

    pub fn flush(self: *StreamWriter) void {
        self.flushFn(self.ctx);
    }

    /// Reports terminal sink failure when the backing API can observe it.
    pub fn failed(self: *const StreamWriter) bool {
        return if (self.failedFn) |failedFn| failedFn(self.ctx) else false;
    }

    pub fn placeholder(self: *StreamWriter, id: []const u8, fallback_html: []const u8) void {
        if (!validStreamId(id)) return;
        self.write("<div data-mer-placeholder=\"");
        self.write(id);
        self.write("\">");
        self.write(fallback_html);
        self.write("</div>");
    }

    pub fn resolve(self: *StreamWriter, id: []const u8, content: []const u8) void {
        if (!validStreamId(id)) return;
        self.write("<template data-mer-resolve=\"");
        self.write(id);
        self.write("\">");
        self.write(content);
        self.write("</template><script src=\"/_mer/resolve.js\"></script>");
        self.flush();
    }
};

fn validStreamId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != ':' and c != '.') return false;
    return true;
}

pub const Method = req_mod.Method;
pub const Param = req_mod.Param;
pub const Request = req_mod.Request;
pub const ContentType = res_mod.ContentType;
pub const Response = res_mod.Response;
pub const SameSite = res_mod.SameSite;
pub const SetCookie = res_mod.SetCookie;

pub const html = res_mod.html;
pub const json = res_mod.json;
pub const text = res_mod.text;
pub const notFound = res_mod.notFound;
pub const internalError = res_mod.internalError;
pub const redirect = res_mod.redirect;
pub const withCookies = res_mod.withCookies;

pub fn typedJson(allocator: std.mem.Allocator, value: anytype) Response {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.write(value) catch {
        out.deinit();
        return internalError("json write failed");
    };
    const body = out.toOwnedSlice() catch {
        out.deinit();
        return internalError("json write failed");
    };
    return .{ .status = .ok, .content_type = .json, .body = body, .body_allocator = allocator };
}

pub fn parseJson(comptime T: type, req: Request) !?std.json.Parsed(T) {
    if (req.body.len == 0) return null;
    return @as(?std.json.Parsed(T), try std.json.parseFromSlice(T, req.allocator, req.body, .{ .ignore_unknown_fields = true }));
}

pub fn formParam(body: []const u8, name: []const u8) ?[]const u8 {
    var params = body;
    while (params.len > 0) {
        const amp = std.mem.indexOfScalar(u8, params, '&') orelse params.len;
        const kv = params[0..amp];
        if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
            if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
        }
        params = if (amp < params.len) params[amp + 1 ..] else "";
    }
    return null;
}

pub fn badRequest(msg: []const u8) Response {
    return Response.init(.bad_request, .text, msg);
}

pub fn env(name: []const u8) ?[]const u8 {
    return env_mod.get(name);
}
pub const putEnv = env_mod.put;
pub const loadDotenv = env_mod.loadDotenv;
pub const loadDotenvStatus = env_mod.loadDotenvStatus;
pub const deinitDotenv = env_mod.deinitDotenv;
pub const resetEnv = env_mod.reset;
pub const __mer_set_env_status = env_mod.__mer_set_env_status;

pub const FetchRequest = fetch_mod.FetchRequest;
pub const FetchResponse = fetch_mod.FetchResponse;
pub const fetch = fetch_mod.fetch;
pub const fetchAll = fetch_mod.fetchAll;
pub const wasmBeginCollect = fetch_mod.wasmBeginCollect;
pub const wasmEndCollect = fetch_mod.wasmEndCollect;
pub const wasmEndCollectV2 = fetch_mod.wasmEndCollectV2;
pub const wasmExpectedState = fetch_mod.wasmExpectedState;
pub const wasmRestoreExpectedState = fetch_mod.wasmRestoreExpectedState;
pub const wasmProvideResult = fetch_mod.wasmProvideResult;
pub const wasmProvideResultV2 = fetch_mod.wasmProvideResultV2;
pub const wasmClearCache = fetch_mod.wasmClearCache;
pub const wasmClearCacheV2 = fetch_mod.wasmClearCacheV2;

pub const Meta = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    og_title: ?[]const u8 = null,
    og_description: ?[]const u8 = null,
    og_image: ?[]const u8 = null,
    og_url: ?[]const u8 = null,
    og_type: []const u8 = "website",
    og_site_name: []const u8 = "merjs",
    twitter_card: []const u8 = "summary_large_image",
    twitter_title: ?[]const u8 = null,
    twitter_description: ?[]const u8 = null,
    twitter_image: ?[]const u8 = null,
    twitter_site: ?[]const u8 = null,
    canonical: ?[]const u8 = null,
    robots: ?[]const u8 = null,
    extra_head: ?[]const u8 = null,
};

pub const h = @import("html.zig");
pub const lint = @import("html_lint.zig");
pub const css = @import("css.zig");

/// Render a Node without changing its render-storage lifetime. The returned
/// Response owns only the serialized body and may be deinitialized independently.
pub fn render(allocator: std.mem.Allocator, node: h.Node) Response {
    const body = h.render(allocator, node) catch return internalError("html render failed");
    return .{ .status = .ok, .content_type = .html, .body = body, .body_allocator = allocator };
}

pub const dhi = @import("dhi.zig");

pub const RenderFn = *const fn (req: Request) Response;
pub const StreamRenderFn = *const fn (req: Request, stream: *StreamWriter) void;

pub const Route = struct {
    path: []const u8,
    render: RenderFn,
    render_stream: ?StreamRenderFn = null,
    meta: Meta = .{},
    prerender: bool = false,
};

const TestStream = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    flushes: usize = 0,
};

fn testStreamWrite(ctx: *anyopaque, data: []const u8) void {
    const test_stream: *TestStream = @ptrCast(@alignCast(ctx));
    test_stream.bytes.appendSlice(std.testing.allocator, data) catch @panic("test allocation failed");
}

fn testStreamFlush(ctx: *anyopaque) void {
    const test_stream: *TestStream = @ptrCast(@alignCast(ctx));
    test_stream.flushes += 1;
}

fn testStreamFailed(ctx: *anyopaque) bool {
    const test_stream: *TestStream = @ptrCast(@alignCast(ctx));
    return test_stream.flushes > 0;
}

test "stream sink failures are observable when the backing API supports them" {
    var output = TestStream{};
    defer output.bytes.deinit(std.testing.allocator);
    var stream = StreamWriter{
        .allocator = std.testing.allocator,
        .ctx = &output,
        .writeFn = testStreamWrite,
        .flushFn = testStreamFlush,
        .failedFn = testStreamFailed,
    };
    try std.testing.expect(!stream.failed());
    stream.flush();
    try std.testing.expect(stream.failed());
}

test "stream placeholders use validated attributes and a CSP-safe external resolver" {
    var output = TestStream{};
    defer output.bytes.deinit(std.testing.allocator);
    var stream = StreamWriter{
        .allocator = std.testing.allocator,
        .ctx = &output,
        .writeFn = testStreamWrite,
        .flushFn = testStreamFlush,
    };
    stream.placeholder("safe-id:1", "loading");
    stream.resolve("safe-id:1", "ready");
    stream.resolve("bad\" id", "ignored");

    try std.testing.expectEqualStrings(
        "<div data-mer-placeholder=\"safe-id:1\">loading</div>" ++
            "<template data-mer-resolve=\"safe-id:1\">ready</template>" ++
            "<script src=\"/_mer/resolve.js\"></script>",
        output.bytes.items,
    );
    try std.testing.expectEqual(@as(usize, 1), output.flushes);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes.items, "<script>") == null);
}
