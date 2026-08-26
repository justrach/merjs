// dispatch.zig — request dispatch: route matching → render → layout wrapping.
// Extracted from router.zig so the Router struct stays focused on routing data
// structures (init/deinit/findRoute/matchRoute).

const std = @import("std");
const mer = @import("mer");
const Router = @import("router.zig").Router;
const Route = @import("router.zig").Route;
const matchRoute = @import("router.zig").matchRoute;

/// A matched route plus the (possibly param-populated) request and its meta.
pub const Match = struct {
    route: Route,
    req: mer.Request,
    meta: mer.Meta,
};

/// Resolve a request to a route (exact → dynamic → trailing-slash fallback),
/// populating dynamic params into a copy of the request. Shared by every
/// dispatch path so matching + guard semantics stay identical.
pub fn matchRequest(router: Router, req: mer.Request) ?Match {
    var params_buf: [8]mer.Param = undefined;

    if (router.exact_map.get(req.path)) |idx| {
        return .{ .route = router.routes[idx], .req = req, .meta = router.routes[idx].meta };
    }
    for (router.dynamic_routes) |route| {
        if (matchRoute(route.path, req.path, &params_buf)) |n| {
            var dyn_req = req;
            dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
            return .{ .route = route, .req = dyn_req, .meta = route.meta };
        }
    }
    if (req.path.len > 1 and req.path[req.path.len - 1] == '/') {
        const trimmed = req.path[0 .. req.path.len - 1];
        if (router.exact_map.get(trimmed)) |idx| {
            return .{ .route = router.routes[idx], .req = req, .meta = router.routes[idx].meta };
        }
        for (router.dynamic_routes) |route| {
            if (matchRoute(route.path, trimmed, &params_buf)) |n| {
                var dyn_req = req;
                dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
                return .{ .route = route, .req = dyn_req, .meta = route.meta };
            }
        }
    }
    return null;
}

/// Run global middleware (every request, before routing). First non-null
/// response short-circuits dispatch.
pub fn globalGuard(router: Router, req: mer.Request) ?mer.Response {
    for (router.global_middleware) |mw| {
        if (mw(req)) |resp| return resp;
    }
    return null;
}

/// Run a route's per-route guard, if any.
pub fn routeGuard(route: Route, req: mer.Request) ?mer.Response {
    if (route.middleware) |mw| return mw(req);
    return null;
}

/// Match a URL path to a route and call its render function.
pub fn dispatch(router: Router, req: mer.Request) mer.Response {
    // Global middleware — runs on every request, before routing.
    if (globalGuard(router, req)) |resp| return resp;

    var meta: mer.Meta = .{};
    var response: mer.Response = blk: {
        if (matchRequest(router, req)) |m| {
            meta = m.meta;
            // Per-route guard short-circuits render (no layout wrap).
            if (routeGuard(m.route, m.req)) |resp| return resp;
            break :blk m.route.render(m.req);
        }
        if (router.not_found) |nf| break :blk nf(req);
        break :blk mer.notFound();
    };

    // Auto-wrap HTML responses with layout (skip if response already has <!DOCTYPE).
    if (router.layout) |wrap| {
        if (response.content_type == .html and response.body.len > 0) {
            if (!std.mem.startsWith(u8, response.body, "<!")) {
                response.body = wrap(req.allocator, req.path, response.body, meta);
            }
        }
    }

    return response;
}

/// Result of a streaming dispatch — head/body/tail are separate for chunked flushing.
pub const StreamResult = struct {
    head: []const u8,
    body: []const u8,
    tail: []const u8,
    response: mer.Response,
    is_streaming: bool,
};

/// Dispatch with streaming layout support. If stream_layout is set and the
/// response is HTML, returns head/body/tail separately for chunked flushing.
/// Otherwise falls back to the normal assembled response.
pub fn dispatchStreaming(router: Router, req: mer.Request) StreamResult {
    // Global middleware — runs on every request, before routing. A guard
    // response is returned as a plain (non-streaming) result.
    if (globalGuard(router, req)) |resp| {
        return .{ .head = "", .body = resp.body, .tail = "", .response = resp, .is_streaming = false };
    }

    var meta: mer.Meta = .{};
    var response: mer.Response = blk: {
        if (matchRequest(router, req)) |m| {
            meta = m.meta;
            if (routeGuard(m.route, m.req)) |resp| {
                return .{ .head = "", .body = resp.body, .tail = "", .response = resp, .is_streaming = false };
            }
            break :blk m.route.render(m.req);
        }
        if (router.not_found) |nf| break :blk nf(req);
        break :blk mer.notFound();
    };

    // Use streaming layout if available and response is an HTML fragment.
    if (router.stream_layout) |stream_wrap| {
        if (response.content_type == .html and response.body.len > 0) {
            if (!std.mem.startsWith(u8, response.body, "<!")) {
                const parts = stream_wrap(req.allocator, req.path, meta);
                return .{
                    .head = parts.head,
                    .body = response.body,
                    .tail = parts.tail,
                    .response = response,
                    .is_streaming = true,
                };
            }
        }
    }

    // Fallback: use regular layout wrapping.
    if (router.layout) |wrap| {
        if (response.content_type == .html and response.body.len > 0) {
            if (!std.mem.startsWith(u8, response.body, "<!")) {
                response.body = wrap(req.allocator, req.path, response.body, meta);
            }
        }
    }

    return .{ .head = "", .body = response.body, .tail = "", .response = response, .is_streaming = false };
}

/// Like dispatch() but calls renderStream (if present) with a buffering writer,
/// so pages that only export renderStream work on Cloudflare Workers.
pub fn dispatchBuffered(router: Router, req: mer.Request) mer.Response {
    // Global middleware — runs on every request, before routing.
    if (globalGuard(router, req)) |resp| return resp;

    const match = matchRequest(router, req);
    if (match) |m| {
        // Per-route guard short-circuits render.
        if (routeGuard(m.route, m.req)) |resp| return resp;

        // If the route has renderStream, buffer it into a full response.
        if (m.route.render_stream) |rs| {
            var ctx = BufCtx{ .alloc = req.allocator };
            var stream = mer.StreamWriter{
                .allocator = req.allocator,
                .ctx = &ctx,
                .writeFn = bufWriteFn,
                .flushFn = bufFlushFn,
            };
            rs(m.req, &stream);
            const body = ctx.list.toOwnedSlice(req.allocator) catch "";

            // Wrap with stream layout (head + body + tail).
            if (router.stream_layout) |wrap| {
                const parts = wrap(req.allocator, req.path, m.meta);
                const full = std.mem.concat(req.allocator, u8, &.{ parts.head, body, parts.tail }) catch body;
                return .{ .status = .ok, .content_type = .html, .body = full };
            }
            if (router.layout) |wrap| {
                return .{ .status = .ok, .content_type = .html, .body = wrap(req.allocator, req.path, body, m.meta) };
            }
            return .{ .status = .ok, .content_type = .html, .body = body };
        }

        // Regular render + layout wrap (guards already ran above).
        var response = m.route.render(m.req);
        if (router.layout) |wrap| {
            if (response.content_type == .html and response.body.len > 0 and !std.mem.startsWith(u8, response.body, "<!")) {
                response.body = wrap(req.allocator, req.path, response.body, m.meta);
            }
        }
        return response;
    }

    // No match — not-found (with layout wrap).
    var response = if (router.not_found) |nf| nf(req) else mer.notFound();
    if (router.layout) |wrap| {
        if (response.content_type == .html and response.body.len > 0 and !std.mem.startsWith(u8, response.body, "<!")) {
            response.body = wrap(req.allocator, req.path, response.body, .{});
        }
    }
    return response;
}

const BufCtx = struct {
    list: std.ArrayListUnmanaged(u8) = .empty,
    alloc: std.mem.Allocator,
};

fn bufWriteFn(ctx: *anyopaque, data: []const u8) void {
    const bc: *BufCtx = @ptrCast(@alignCast(ctx));
    bc.list.appendSlice(bc.alloc, data) catch {};
}

fn bufFlushFn(ctx: *anyopaque) void {
    _ = ctx;
}

// ── Middleware / guard tests (#23) ──────────────────────────────────────────

const testing = std.testing;

fn okRender(_: mer.Request) mer.Response {
    return mer.html("<p>ok</p>");
}
fn blockGuard(_: mer.Request) ?mer.Response {
    return mer.redirect("/login", .see_other);
}
fn passGuard(_: mer.Request) ?mer.Response {
    return null;
}

test "dispatch: per-route middleware short-circuits render" {
    const routes = [_]Route{
        .{ .path = "/admin", .render = okRender, .middleware = blockGuard },
    };
    var router = Router.init(testing.allocator, &routes);
    defer router.deinit();

    const req = mer.Request.init(testing.allocator, .GET, "/admin");
    const resp = dispatch(router, req);
    try testing.expectEqual(std.http.Status.see_other, resp.status);
}

test "dispatch: passing middleware allows render" {
    const routes = [_]Route{
        .{ .path = "/admin", .render = okRender, .middleware = passGuard },
    };
    var router = Router.init(testing.allocator, &routes);
    defer router.deinit();

    const req = mer.Request.init(testing.allocator, .GET, "/admin");
    const resp = dispatch(router, req);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expectEqualStrings("<p>ok</p>", resp.body);
}

test "dispatch: global middleware runs on every request" {
    const routes = [_]Route{
        .{ .path = "/", .render = okRender },
    };
    var router = Router.init(testing.allocator, &routes);
    defer router.deinit();
    const gm = [_]mer.MiddlewareFn{blockGuard};
    router.global_middleware = &gm;

    const req = mer.Request.init(testing.allocator, .GET, "/");
    const resp = dispatch(router, req);
    try testing.expectEqual(std.http.Status.see_other, resp.status);
}

test "requireSession: redirects without cookie, passes with cookie" {
    var req = mer.Request.init(testing.allocator, .GET, "/dashboard");
    try testing.expect(mer.requireSession(req) != null);

    req.cookies_raw = "session=abc123";
    try testing.expect(mer.requireSession(req) == null);
}
