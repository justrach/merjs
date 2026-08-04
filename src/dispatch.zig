// dispatch.zig — request dispatch: route matching → render → layout wrapping.
// Extracted from router.zig so the Router struct stays focused on routing data
// structures (init/deinit/findRoute/matchRoute).

const std = @import("std");
const mer = @import("mer");
const Router = @import("router.zig").Router;

const RenderResult = struct {
    response: mer.Response,
    meta: mer.Meta,
};

fn renderMatched(router: Router, req: mer.Request) RenderResult {
    var matched = router.match(req) catch return .{ .response = mer.internalError("<h1>500 Internal Server Error</h1>"), .meta = .{} };
    if (matched) |*result| {
        defer result.deinit();
        return .{
            .response = result.route.render(result.request),
            .meta = result.route.meta,
        };
    }
    return .{
        .response = if (router.not_found) |nf| nf(req) else mer.notFound(),
        .meta = .{},
    };
}

fn wrapResponse(router: Router, req: mer.Request, result: RenderResult) mer.Response {
    var response = result.response;
    if (router.layout) |wrap| {
        if (response.content_type == .html and response.body.len > 0 and !std.mem.startsWith(u8, response.body, "<!")) {
            // LayoutFn predates explicit ownership metadata and existing layouts
            // return allocator-owned, borrowed, static, and foreign slices. Give
            // allocator-using layouts scoped storage, then copy the result so a
            // Response never guesses how the returned slice must be released.
            var layout_arena = std.heap.ArenaAllocator.init(req.allocator);
            defer layout_arena.deinit();
            const body = wrap(layout_arena.allocator(), req.path, response.body, result.meta);
            if (body.ptr != response.body.ptr or body.len != response.body.len) {
                const owned = req.allocator.dupe(u8, body) catch return response;
                response.replaceBodyOwned(req.allocator, owned);
            }
        }
    }
    return response;
}

/// Match a URL path to a route and call its render function.
pub fn dispatch(router: Router, req: mer.Request) mer.Response {
    var render_storage = mer.h.RenderStorage.init(req.allocator);
    const owns_render_storage = !mer.h.hasRenderAllocator();
    if (owns_render_storage) render_storage.activate();
    defer if (owns_render_storage) render_storage.deinit();
    return wrapResponse(router, req, renderMatched(router, req));
}

/// Result of a streaming dispatch — head/body/tail are separate for chunked flushing.
pub const StreamResult = struct {
    head: []const u8,
    body: []const u8,
    tail: []const u8,
    response: mer.Response,
    is_streaming: bool,
    parts: ?mer.StreamParts = null,

    pub fn deinitParts(self: StreamResult) void {
        if (self.parts) |parts| parts.deinit();
    }
};

/// Dispatch with streaming layout support. If stream_layout is set and the
/// response is HTML, returns head/body/tail separately for chunked flushing.
/// Otherwise falls back to the normal assembled response.
pub fn dispatchStreaming(router: Router, req: mer.Request) StreamResult {
    var render_storage = mer.h.RenderStorage.init(req.allocator);
    const owns_render_storage = !mer.h.hasRenderAllocator();
    if (owns_render_storage) render_storage.activate();
    defer if (owns_render_storage) render_storage.deinit();

    const result = renderMatched(router, req);
    var response = result.response;

    if (router.stream_layout) |stream_wrap| {
        if (response.content_type == .html and response.body.len > 0 and !std.mem.startsWith(u8, response.body, "<!")) {
            const parts = stream_wrap(req.allocator, req.path, result.meta);
            return .{
                .head = parts.head,
                .body = response.body,
                .tail = parts.tail,
                .response = response,
                .is_streaming = true,
                .parts = parts,
            };
        }
    }

    response = wrapResponse(router, req, result);
    return .{ .head = "", .body = response.body, .tail = "", .response = response, .is_streaming = false };
}

/// Like dispatch() but calls renderStream (if present) with a buffering writer,
/// so pages that only export renderStream work on Cloudflare Workers.
pub fn dispatchBuffered(router: Router, req: mer.Request) mer.Response {
    var render_storage = mer.h.RenderStorage.init(req.allocator);
    const owns_render_storage = !mer.h.hasRenderAllocator();
    if (owns_render_storage) render_storage.activate();
    defer if (owns_render_storage) render_storage.deinit();

    var matched = router.match(req) catch return mer.internalError("<h1>500 Internal Server Error</h1>");
    if (matched) |*result| {
        defer result.deinit();
        if (result.route.render_stream) |render_stream| {
            var ctx = BufCtx{ .alloc = req.allocator };
            defer ctx.list.deinit(req.allocator);
            var stream = mer.StreamWriter{
                .allocator = req.allocator,
                .ctx = &ctx,
                .writeFn = bufWriteFn,
                .flushFn = bufFlushFn,
            };
            render_stream(result.request, &stream);
            if (ctx.failed) return mer.internalError("<h1>500 Internal Server Error</h1>");
            const body = ctx.list.toOwnedSlice(req.allocator) catch return mer.internalError("<h1>500 Internal Server Error</h1>");

            if (router.stream_layout) |wrap| {
                const parts = wrap(req.allocator, req.path, result.route.meta);
                defer parts.deinit();
                const full = std.mem.concat(req.allocator, u8, &.{ parts.head, body, parts.tail }) catch {
                    req.allocator.free(body);
                    return mer.internalError("<h1>500 Internal Server Error</h1>");
                };
                req.allocator.free(body);
                return .{ .status = .ok, .content_type = .html, .body = full, .body_allocator = req.allocator };
            }
            if (router.layout) |wrap| {
                var response: mer.Response = .{ .status = .ok, .content_type = .html, .body = body, .body_allocator = req.allocator };
                var layout_arena = std.heap.ArenaAllocator.init(req.allocator);
                defer layout_arena.deinit();
                const full = wrap(layout_arena.allocator(), req.path, body, result.route.meta);
                if (full.ptr != body.ptr or full.len != body.len) {
                    const owned = req.allocator.dupe(u8, full) catch return response;
                    response.replaceBodyOwned(req.allocator, owned);
                }
                return response;
            }
            return .{ .status = .ok, .content_type = .html, .body = body, .body_allocator = req.allocator };
        }
        return wrapResponse(router, req, .{
            .response = result.route.render(result.request),
            .meta = result.route.meta,
        });
    }

    return wrapResponse(router, req, .{
        .response = if (router.not_found) |nf| nf(req) else mer.notFound(),
        .meta = .{},
    });
}

const BufCtx = struct {
    list: std.ArrayListUnmanaged(u8) = .empty,
    alloc: std.mem.Allocator,
    failed: bool = false,
};

fn bufWriteFn(ctx: *anyopaque, data: []const u8) void {
    const bc: *BufCtx = @ptrCast(@alignCast(ctx));
    if (bc.failed) return;
    bc.list.appendSlice(bc.alloc, data) catch {
        bc.failed = true;
    };
}

fn bufFlushFn(ctx: *anyopaque) void {
    _ = ctx;
}

fn paramRender(req: mer.Request) mer.Response {
    return mer.html(req.param("id") orelse "exact");
}

fn paramRenderStream(req: mer.Request, stream: *mer.StreamWriter) void {
    stream.write(req.param("id") orelse "exact");
}

test "dispatch variants share exact, dynamic, and trailing-slash matches without leaking params" {
    const routes = [_]mer.Route{
        .{ .path = "/users/new", .render = paramRender, .render_stream = paramRenderStream },
        .{ .path = "/users/:id", .render = paramRender, .render_stream = paramRenderStream },
    };
    var router = try Router.initFallible(std.testing.allocator, &routes);
    defer router.deinit();

    for ([_]struct { path: []const u8, expected: []const u8 }{
        .{ .path = "/users/new", .expected = "exact" },
        .{ .path = "/users/42", .expected = "42" },
        .{ .path = "/users/42/", .expected = "42" },
    }) |case| {
        const req = mer.Request.init(std.testing.allocator, .GET, case.path);
        try std.testing.expectEqualStrings(case.expected, dispatch(router, req).body);
        try std.testing.expectEqualStrings(case.expected, dispatchStreaming(router, req).body);
        const buffered = dispatchBuffered(router, req);
        defer buffered.deinit();
        try std.testing.expectEqualStrings(case.expected, buffered.body);
    }
}

test "true streaming keeps dynamic params valid during synchronous render" {
    const routes = [_]mer.Route{
        .{ .path = "/users/:id", .render = paramRender, .render_stream = paramRenderStream },
    };
    var router = try Router.initFallible(std.testing.allocator, &routes);
    defer router.deinit();

    var matched = (try router.match(mer.Request.init(std.testing.allocator, .GET, "/users/42"))).?;
    defer matched.deinit();
    var ctx = BufCtx{ .alloc = std.testing.allocator };
    defer ctx.list.deinit(std.testing.allocator);
    var stream = mer.StreamWriter{
        .allocator = std.testing.allocator,
        .ctx = &ctx,
        .writeFn = bufWriteFn,
        .flushFn = bufFlushFn,
    };
    matched.route.render_stream.?(matched.request, &stream);
    try std.testing.expectEqualStrings("42", ctx.list.items);
}

var fallback_render_count: usize = 0;

fn countedRender(req: mer.Request) mer.Response {
    fallback_render_count += 1;
    return paramRender(req);
}

test "buffered fallback matches and renders once" {
    const routes = [_]mer.Route{
        .{ .path = "/users/:id", .render = countedRender },
    };
    var router = try Router.initFallible(std.testing.allocator, &routes);
    defer router.deinit();

    fallback_render_count = 0;
    const response = dispatchBuffered(router, mer.Request.init(std.testing.allocator, .GET, "/users/42"));
    defer response.deinit();
    try std.testing.expectEqualStrings("42", response.body);
    try std.testing.expectEqual(@as(usize, 1), fallback_render_count);
}

fn ownedHtmlRender(req: mer.Request) mer.Response {
    const body = req.allocator.dupe(u8, "page") catch return mer.internalError("allocation failed");
    return .{ .status = .ok, .content_type = .html, .body = body, .body_allocator = req.allocator };
}

fn copiedNodeRender(req: mer.Request) mer.Response {
    const child = mer.h.span(.{}, "shared");
    const copy = child;
    return mer.render(req.allocator, mer.h.div(.{}, .{ child, copy }));
}

fn testLayout(allocator: std.mem.Allocator, _: []const u8, body: []const u8, _: mer.Meta) []const u8 {
    return std.mem.concat(allocator, u8, &.{ "<main>", body, "</main>" }) catch @panic("test allocation failed");
}

fn testStreamLayout(allocator: std.mem.Allocator, _: []const u8, _: mer.Meta) mer.StreamParts {
    const head = allocator.dupe(u8, "<main>") catch @panic("test allocation failed");
    return .{ .head = head, .tail = "</main>", .head_allocator = allocator };
}

test "layouts replace owned and copied-node bodies across repeated dispatches" {
    const routes = [_]mer.Route{
        .{ .path = "/page", .render = ownedHtmlRender, .render_stream = paramRenderStream },
        .{ .path = "/copied", .render = copiedNodeRender },
    };
    var router = try Router.initFallible(std.testing.allocator, &routes);
    defer router.deinit();
    router.layout = testLayout;

    for (0..100) |_| {
        const req = mer.Request.init(std.testing.allocator, .GET, "/page");
        const response = dispatch(router, req);
        try std.testing.expect(response.body_allocator != null);
        try std.testing.expectEqualStrings("<main>page</main>", response.body);
        response.deinit();

        const buffered = dispatchBuffered(router, req);
        try std.testing.expect(buffered.body_allocator != null);
        try std.testing.expectEqualStrings("<main>exact</main>", buffered.body);
        buffered.deinit();

        const copied = dispatch(router, mer.Request.init(std.testing.allocator, .GET, "/copied"));
        try std.testing.expect(copied.body_allocator != null);
        try std.testing.expectEqualStrings("<main><div><span>shared</span><span>shared</span></div></main>", copied.body);
        copied.deinit();
    }

    router.layout = null;
    router.stream_layout = testStreamLayout;
    const streamed = dispatchBuffered(router, mer.Request.init(std.testing.allocator, .GET, "/page"));
    defer streamed.deinit();
    try std.testing.expect(streamed.body_allocator != null);
    try std.testing.expectEqualStrings("<main>exact</main>", streamed.body);
}

fn passthroughLayout(_: std.mem.Allocator, _: []const u8, body: []const u8, _: mer.Meta) []const u8 {
    return body;
}

test "passthrough layouts retain existing body ownership" {
    const routes = [_]mer.Route{
        .{ .path = "/page", .render = ownedHtmlRender, .render_stream = paramRenderStream },
        .{ .path = "/borrowed", .render = paramRender },
    };
    var router = try Router.initFallible(std.testing.allocator, &routes);
    defer router.deinit();
    router.layout = passthroughLayout;

    for (0..100) |_| {
        const req = mer.Request.init(std.testing.allocator, .GET, "/page");
        const response = dispatch(router, req);
        try std.testing.expect(response.body_allocator != null);
        try std.testing.expectEqualStrings("page", response.body);
        response.deinit();

        const buffered = dispatchBuffered(router, req);
        try std.testing.expect(buffered.body_allocator != null);
        try std.testing.expectEqualStrings("exact", buffered.body);
        buffered.deinit();
    }

    const borrowed = dispatch(router, mer.Request.init(std.testing.allocator, .GET, "/borrowed"));
    try std.testing.expect(borrowed.body_allocator == null);
    try std.testing.expectEqualStrings("exact", borrowed.body);
}

var foreign_layout_body: []const u8 = "";

fn staticLayout(_: std.mem.Allocator, _: []const u8, _: []const u8, _: mer.Meta) []const u8 {
    return "<main>static</main>";
}

fn foreignLayout(_: std.mem.Allocator, _: []const u8, _: []const u8, _: mer.Meta) []const u8 {
    return foreign_layout_body;
}

test "legacy layouts copy borrowed static and foreign slices without inferring ownership" {
    const routes = [_]mer.Route{.{ .path = "/page", .render = ownedHtmlRender }};
    var router = try Router.initFallible(std.testing.allocator, &routes);
    defer router.deinit();

    router.layout = staticLayout;
    const static_response = dispatch(router, mer.Request.init(std.testing.allocator, .GET, "/page"));
    try std.testing.expect(static_response.body_allocator != null);
    try std.testing.expectEqualStrings("<main>static</main>", static_response.body);
    static_response.deinit();

    const foreign = try std.testing.allocator.dupe(u8, "<main>foreign</main>");
    defer std.testing.allocator.free(foreign);
    foreign_layout_body = foreign;
    router.layout = foreignLayout;
    const foreign_response = dispatch(router, mer.Request.init(std.testing.allocator, .GET, "/page"));
    try std.testing.expect(foreign_response.body.ptr != foreign.ptr);
    try std.testing.expectEqualStrings(foreign, foreign_response.body);
    foreign_response.deinit();
}

test "streaming dispatch exposes layout ownership for caller teardown" {
    const routes = [_]mer.Route{.{ .path = "/page", .render = ownedHtmlRender }};
    var router = try Router.initFallible(std.testing.allocator, &routes);
    defer router.deinit();
    router.stream_layout = testStreamLayout;

    const result = dispatchStreaming(router, mer.Request.init(std.testing.allocator, .GET, "/page"));
    defer result.response.deinit();
    defer result.deinitParts();
    try std.testing.expect(result.parts != null);
    try std.testing.expectEqualStrings("<main>", result.head);
    try std.testing.expectEqualStrings("</main>", result.tail);
}

test "parameter and buffered stream allocation failures return 500" {
    const routes = [_]mer.Route{
        .{ .path = "/users/:id", .render = paramRender },
        .{ .path = "/stream", .render = paramRender, .render_stream = paramRenderStream },
    };
    var router = try Router.initFallible(std.testing.allocator, &routes);
    defer router.deinit();

    var param_storage: [1]u8 = undefined;
    var param_fba = std.heap.FixedBufferAllocator.init(&param_storage);
    const param_response = dispatch(router, mer.Request.init(param_fba.allocator(), .GET, "/users/42"));
    try std.testing.expectEqual(std.http.Status.internal_server_error, param_response.status);

    var stream_storage: [1]u8 = undefined;
    var stream_fba = std.heap.FixedBufferAllocator.init(&stream_storage);
    const stream_response = dispatchBuffered(router, mer.Request.init(stream_fba.allocator(), .GET, "/stream"));
    try std.testing.expectEqual(std.http.Status.internal_server_error, stream_response.status);
}
