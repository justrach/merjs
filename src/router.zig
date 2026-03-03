// router.zig — file-based router.
// app/index.zig  → "/"
// app/about.zig  → "/about"

const std = @import("std");
const mer = @import("mer");

pub const RenderFn = *const fn (req: mer.Request) mer.Response;
pub const LayoutFn = *const fn (std.mem.Allocator, []const u8, []const u8, mer.Meta) []const u8;

pub const Route = struct {
    path: []const u8,
    render: RenderFn,
    meta: mer.Meta = .{},
};

pub const Router = struct {
    routes: []const Route,
    allocator: std.mem.Allocator,
    not_found: ?RenderFn = null,
    layout: ?LayoutFn = null,

    pub fn init(allocator: std.mem.Allocator, routes: []const Route) Router {
        return .{ .allocator = allocator, .routes = routes };
    }

    pub fn deinit(_: *Router) void {}

    /// Match a URL path to a route and call its render function.
    /// If a layout is set and the response is HTML, wraps it automatically.
    pub fn dispatch(self: Router, req: mer.Request) mer.Response {
        var meta: mer.Meta = .{};
        var response: mer.Response = blk: {
            for (self.routes) |route| {
                if (std.mem.eql(u8, route.path, req.path)) {
                    meta = route.meta;
                    break :blk route.render(req);
                }
            }
            // Strip trailing slash and retry (except root).
            if (req.path.len > 1 and req.path[req.path.len - 1] == '/') {
                const trimmed = req.path[0 .. req.path.len - 1];
                for (self.routes) |route| {
                    if (std.mem.eql(u8, route.path, trimmed)) {
                        meta = route.meta;
                        break :blk route.render(req);
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
