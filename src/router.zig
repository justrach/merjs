// router.zig — file-based router.
// pages/index.zig  → "/"
// pages/about.zig  → "/about"

const std = @import("std");
const mer = @import("mer");

pub const RenderFn = *const fn (req: mer.Request) mer.Response;

pub const Route = struct {
    path: []const u8,
    render: RenderFn,
};

pub const Router = struct {
    routes: []const Route,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, routes: []const Route) Router {
        return .{ .allocator = allocator, .routes = routes };
    }

    pub fn deinit(_: *Router) void {}

    /// Match a URL path to a route and call its render function.
    pub fn dispatch(self: Router, req: mer.Request) mer.Response {
        for (self.routes) |route| {
            if (std.mem.eql(u8, route.path, req.path)) return route.render(req);
        }
        // Strip trailing slash and retry (except root).
        if (req.path.len > 1 and req.path[req.path.len - 1] == '/') {
            const trimmed = req.path[0 .. req.path.len - 1];
            for (self.routes) |route| {
                if (std.mem.eql(u8, route.path, trimmed)) return route.render(req);
            }
        }
        return mer.notFound();
    }
};
