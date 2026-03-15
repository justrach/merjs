// router.zig — file-based router with hash-map exact matching.
// app/index.zig    → "/"
// app/about.zig    → "/about"
// app/users/[id].zig → "/users/:id"  (dynamic segment)

const std = @import("std");
const mer = @import("mer");

pub const RenderFn = *const fn (req: mer.Request) mer.Response;
pub const StreamRenderFn = *const fn (req: mer.Request, stream: *mer.StreamWriter) void;
pub const LayoutFn = *const fn (std.mem.Allocator, []const u8, []const u8, mer.Meta) []const u8;

pub const StreamParts = mer.StreamParts;
pub const StreamLayoutFn = *const fn (std.mem.Allocator, []const u8, mer.Meta) StreamParts;

pub const Route = struct {
    path: []const u8,
    render: RenderFn,
    render_stream: ?StreamRenderFn = null,
    meta: mer.Meta = .{},
    prerender: bool = false,
};

pub const Router = struct {
    routes: []const Route,
    allocator: std.mem.Allocator,
    not_found: ?RenderFn = null,
    layout: ?LayoutFn = null,
    stream_layout: ?StreamLayoutFn = null,
    /// Hash map for O(1) exact route lookups.
    exact_map: std.StringHashMapUnmanaged(usize) = .{},
    /// Subset of routes containing dynamic segments (`:param`).
    dynamic_routes: []const Route = &.{},

    pub fn init(allocator: std.mem.Allocator, routes: []const Route) Router {
        var router = Router{ .allocator = allocator, .routes = routes };

        // Build exact match hash map + dynamic route list.
        var dynamic_list: std.ArrayListUnmanaged(Route) = .{};
        for (routes, 0..) |route, i| {
            if (std.mem.indexOfScalar(u8, route.path, ':') != null) {
                dynamic_list.append(allocator, route) catch {};
            } else {
                router.exact_map.put(allocator, route.path, i) catch {};
            }
        }
        router.dynamic_routes = dynamic_list.toOwnedSlice(allocator) catch &.{};

        return router;
    }

    pub fn deinit(self: *Router) void {
        self.exact_map.deinit(self.allocator);
        self.allocator.free(self.dynamic_routes);
    }

    /// Find a route by path (exact or dynamic match). Returns null if not found.
    pub fn findRoute(self: Router, path_arg: []const u8) ?Route {
        if (self.exact_map.get(path_arg)) |idx| return self.routes[idx];
        var params_buf: [8]mer.Param = undefined;
        for (self.dynamic_routes) |route| {
            if (matchRoute(route.path, path_arg, &params_buf) != null) return route;
        }
        // Trailing slash fallback.
        if (path_arg.len > 1 and path_arg[path_arg.len - 1] == '/') {
            const trimmed = path_arg[0 .. path_arg.len - 1];
            if (self.exact_map.get(trimmed)) |idx| return self.routes[idx];
            for (self.dynamic_routes) |route| {
                if (matchRoute(route.path, trimmed, &params_buf) != null) return route;
            }
        }
        return null;
    }

    /// Match a URL path to a route and call its render function.
    pub fn dispatch(self: Router, req: mer.Request) mer.Response {
        var meta: mer.Meta = .{};
        var params_buf: [8]mer.Param = undefined;

        var response: mer.Response = blk: {
            // 1. O(1) exact match via hash map.
            if (self.exact_map.get(req.path)) |idx| {
                meta = self.routes[idx].meta;
                break :blk self.routes[idx].render(req);
            }

            // 2. Dynamic pattern match (only routes with `:param` segments).
            for (self.dynamic_routes) |route| {
                if (matchRoute(route.path, req.path, &params_buf)) |n| {
                    meta = route.meta;
                    var dyn_req = req;
                    dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
                    break :blk route.render(dyn_req);
                }
            }

            // 3. Trailing-slash normalisation (except root).
            if (req.path.len > 1 and req.path[req.path.len - 1] == '/') {
                const trimmed = req.path[0 .. req.path.len - 1];
                if (self.exact_map.get(trimmed)) |idx| {
                    meta = self.routes[idx].meta;
                    break :blk self.routes[idx].render(req);
                }
                for (self.dynamic_routes) |route| {
                    if (matchRoute(route.path, trimmed, &params_buf)) |n| {
                        meta = route.meta;
                        var dyn_req = req;
                        dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
                        break :blk route.render(dyn_req);
                    }
                }
            }

            if (self.not_found) |nf| break :blk nf(req);
            break :blk mer.notFound();
        };

        // Auto-wrap HTML responses with layout (skip if response already has <!DOCTYPE).
        if (self.layout) |wrap| {
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
    pub fn dispatchStreaming(self: Router, req: mer.Request) StreamResult {
        var meta: mer.Meta = .{};
        var params_buf: [8]mer.Param = undefined;

        var response: mer.Response = blk: {
            if (self.exact_map.get(req.path)) |idx| {
                meta = self.routes[idx].meta;
                break :blk self.routes[idx].render(req);
            }
            for (self.dynamic_routes) |route| {
                if (matchRoute(route.path, req.path, &params_buf)) |n| {
                    meta = route.meta;
                    var dyn_req = req;
                    dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
                    break :blk route.render(dyn_req);
                }
            }
            if (req.path.len > 1 and req.path[req.path.len - 1] == '/') {
                const trimmed = req.path[0 .. req.path.len - 1];
                if (self.exact_map.get(trimmed)) |idx| {
                    meta = self.routes[idx].meta;
                    break :blk self.routes[idx].render(req);
                }
                for (self.dynamic_routes) |route| {
                    if (matchRoute(route.path, trimmed, &params_buf)) |n| {
                        meta = route.meta;
                        var dyn_req = req;
                        dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
                        break :blk route.render(dyn_req);
                    }
                }
            }
            if (self.not_found) |nf| break :blk nf(req);
            break :blk mer.notFound();
        };

        // Use streaming layout if available and response is an HTML fragment.
        if (self.stream_layout) |stream_wrap| {
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
        if (self.layout) |wrap| {
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
    pub fn dispatchBuffered(self: Router, req: mer.Request) mer.Response {
        var meta: mer.Meta = .{};
        var params_buf: [8]mer.Param = undefined;

        // Find the route.
        const route: ?Route = blk: {
            if (self.exact_map.get(req.path)) |idx| {
                meta = self.routes[idx].meta;
                break :blk self.routes[idx];
            }
            for (self.dynamic_routes) |route| {
                if (matchRoute(route.path, req.path, &params_buf)) |n| {
                    meta = route.meta;
                    var dyn_req = req;
                    dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
                    break :blk route;
                }
            }
            if (req.path.len > 1 and req.path[req.path.len - 1] == '/') {
                const trimmed = req.path[0 .. req.path.len - 1];
                if (self.exact_map.get(trimmed)) |idx| {
                    meta = self.routes[idx].meta;
                    break :blk self.routes[idx];
                }
            }
            break :blk null;
        };

        // If the route has renderStream, buffer it into a full response.
        if (route) |r| {
            if (r.render_stream) |rs| {
                var ctx = BufCtx{ .alloc = req.allocator };
                var stream = mer.StreamWriter{
                    .allocator = req.allocator,
                    .ctx = &ctx,
                    .writeFn = bufWriteFn,
                    .flushFn = bufFlushFn,
                };
                rs(req, &stream);
                const body = ctx.list.toOwnedSlice(req.allocator) catch "";

                // Wrap with stream layout (head + body + tail).
                if (self.stream_layout) |wrap| {
                    const parts = wrap(req.allocator, req.path, meta);
                    const full = std.mem.concat(req.allocator, u8, &.{ parts.head, body, parts.tail }) catch body;
                    return .{ .status = .ok, .content_type = .html, .body = full };
                }
                if (self.layout) |wrap| {
                    return .{ .status = .ok, .content_type = .html, .body = wrap(req.allocator, req.path, body, meta) };
                }
                return .{ .status = .ok, .content_type = .html, .body = body };
            }
        }

        // No renderStream — fall back to regular dispatch.
        return self.dispatch(req);
    }
};

const BufCtx = struct {
    list: std.ArrayListUnmanaged(u8) = .{},
    alloc: std.mem.Allocator,
};

fn bufWriteFn(ctx: *anyopaque, data: []const u8) void {
    const bc: *BufCtx = @ptrCast(@alignCast(ctx));
    bc.list.appendSlice(bc.alloc, data) catch {};
}

fn bufFlushFn(ctx: *anyopaque) void {
    _ = ctx;
}

/// Try to match `req_path` against `route_path` where `:name` segments are wildcards.
fn matchRoute(route_path: []const u8, req_path: []const u8, out: []mer.Param) ?usize {
    var ri = std.mem.splitScalar(u8, route_path, '/');
    var pi = std.mem.splitScalar(u8, req_path, '/');
    var n: usize = 0;

    while (true) {
        const rs = ri.next();
        const ps = pi.next();
        if (rs == null and ps == null) return n;
        if (rs == null or ps == null) return null;
        const r_seg = rs.?;
        const p_seg = ps.?;
        if (r_seg.len > 0 and r_seg[0] == ':') {
            if (p_seg.len == 0) return null;
            if (n >= out.len) return null;
            out[n] = .{ .key = r_seg[1..], .value = p_seg };
            n += 1;
        } else {
            if (!std.mem.eql(u8, r_seg, p_seg)) return null;
        }
    }
}
