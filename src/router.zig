// router.zig — file-based router with hash-map exact matching.
// app/index.zig    → "/"
// app/about.zig    → "/about"
// app/users/[id].zig → "/users/:id"  (dynamic segment)

const std = @import("std");
const mer = @import("mer");

pub const RenderFn = *const fn (req: mer.Request) mer.Response;
pub const LayoutFn = *const fn (std.mem.Allocator, []const u8, []const u8, mer.Meta) []const u8;

pub const Route = struct {
    path: []const u8,
    render: RenderFn,
    meta: mer.Meta = .{},
    prerender: bool = false,
};

pub const Router = struct {
    routes: []const Route,
    allocator: std.mem.Allocator,
    not_found: ?RenderFn = null,
    layout: ?LayoutFn = null,
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
};

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
