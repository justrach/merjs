// router.zig — file-based router with hash-map exact matching.
// app/index.zig    → "/"
// app/about.zig    → "/about"
// app/users/[id].zig → "/users/:id"  (dynamic segment)

const std = @import("std");
const mer = @import("mer");

pub const RenderFn = mer.RenderFn;
pub const StreamRenderFn = mer.StreamRenderFn;
pub const LayoutFn = *const fn (std.mem.Allocator, []const u8, []const u8, mer.Meta) []const u8;

pub const StreamParts = mer.StreamParts;
pub const StreamLayoutFn = *const fn (std.mem.Allocator, []const u8, mer.Meta) StreamParts;

pub const Route = mer.Route;

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
};

/// Try to match `req_path` against `route_path` where `:name` segments are wildcards.
pub fn matchRoute(route_path: []const u8, req_path: []const u8, out: []mer.Param) ?usize {
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

// ── Tests ────────────────────────────────────────────────────────────────────

fn dummyRender(_: mer.Request) mer.Response {
    return mer.html("<p>ok</p>");
}

test "matchRoute: exact static path" {
    var out: [8]mer.Param = undefined;
    const n = matchRoute("/about", "/about", &out);
    try std.testing.expectEqual(@as(?usize, 0), n);
}

test "matchRoute: root path" {
    var out: [8]mer.Param = undefined;
    const n = matchRoute("/", "/", &out);
    try std.testing.expectEqual(@as(?usize, 0), n);
}

test "matchRoute: single dynamic segment" {
    var out: [8]mer.Param = undefined;
    const n = matchRoute("/users/:id", "/users/42", &out).?;
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("id", out[0].key);
    try std.testing.expectEqualStrings("42", out[0].value);
}

test "matchRoute: multiple dynamic segments" {
    var out: [8]mer.Param = undefined;
    const n = matchRoute("/org/:org/repo/:repo", "/org/acme/repo/widgets", &out).?;
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("org", out[0].key);
    try std.testing.expectEqualStrings("acme", out[0].value);
    try std.testing.expectEqualStrings("repo", out[1].key);
    try std.testing.expectEqualStrings("widgets", out[1].value);
}

test "matchRoute: mismatch returns null" {
    var out: [8]mer.Param = undefined;
    try std.testing.expect(matchRoute("/about", "/contact", &out) == null);
}

test "matchRoute: extra segments returns null" {
    var out: [8]mer.Param = undefined;
    try std.testing.expect(matchRoute("/about", "/about/more", &out) == null);
}

test "matchRoute: fewer segments returns null" {
    var out: [8]mer.Param = undefined;
    try std.testing.expect(matchRoute("/users/:id", "/users", &out) == null);
}

test "matchRoute: empty dynamic segment returns null" {
    var out: [8]mer.Param = undefined;
    // "/users/" splits into ["", "users", ""] — the last segment is empty
    try std.testing.expect(matchRoute("/users/:id", "/users/", &out) == null);
}

test "Router.init: separates exact and dynamic routes" {
    const routes = [_]Route{
        .{ .path = "/", .render = dummyRender },
        .{ .path = "/about", .render = dummyRender },
        .{ .path = "/users/:id", .render = dummyRender },
        .{ .path = "/org/:org/repo/:repo", .render = dummyRender },
    };
    var router = Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    // 2 exact routes in the hash map, 2 dynamic routes
    try std.testing.expectEqual(@as(u32, 2), router.exact_map.count());
    try std.testing.expectEqual(@as(usize, 2), router.dynamic_routes.len);
}

test "Router.findRoute: exact match" {
    const routes = [_]Route{
        .{ .path = "/", .render = dummyRender },
        .{ .path = "/about", .render = dummyRender, .meta = .{ .title = "About" } },
    };
    var router = Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const found = router.findRoute("/about").?;
    try std.testing.expectEqualStrings("/about", found.path);
    try std.testing.expectEqualStrings("About", found.meta.title);
}

test "Router.findRoute: dynamic match" {
    const routes = [_]Route{
        .{ .path = "/", .render = dummyRender },
        .{ .path = "/users/:id", .render = dummyRender, .meta = .{ .title = "User" } },
    };
    var router = Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const found = router.findRoute("/users/99").?;
    try std.testing.expectEqualStrings("/users/:id", found.path);
    try std.testing.expectEqualStrings("User", found.meta.title);
}

test "Router.findRoute: trailing slash fallback" {
    const routes = [_]Route{
        .{ .path = "/about", .render = dummyRender },
    };
    var router = Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    // "/about/" should fall back to "/about"
    const found = router.findRoute("/about/").?;
    try std.testing.expectEqualStrings("/about", found.path);
}

test "Router.findRoute: not found returns null" {
    const routes = [_]Route{
        .{ .path = "/", .render = dummyRender },
    };
    var router = Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    try std.testing.expect(router.findRoute("/nope") == null);
}

test "Router.findRoute: consumer routes without framework example routes" {
    // This is the core #62 test: a consumer project has its OWN routes,
    // not the framework's api/hello, app/about etc. The router should
    // only contain the consumer's routes and match them correctly.
    const consumer_routes = [_]Route{
        .{ .path = "/", .render = dummyRender, .meta = .{ .title = "My App" } },
        .{ .path = "/dashboard", .render = dummyRender, .meta = .{ .title = "Dashboard" } },
        .{ .path = "/settings", .render = dummyRender, .meta = .{ .title = "Settings" } },
        .{ .path = "/projects/:id", .render = dummyRender },
    };
    var router = Router.init(std.testing.allocator, &consumer_routes);
    defer router.deinit();

    // Consumer routes work
    try std.testing.expectEqualStrings("My App", router.findRoute("/").?.meta.title);
    try std.testing.expectEqualStrings("Dashboard", router.findRoute("/dashboard").?.meta.title);
    try std.testing.expectEqualStrings("Settings", router.findRoute("/settings").?.meta.title);
    try std.testing.expect(router.findRoute("/projects/123") != null);

    // Framework example routes do NOT exist
    try std.testing.expect(router.findRoute("/about") == null);
    try std.testing.expect(router.findRoute("/api/hello") == null);
    try std.testing.expect(router.findRoute("/blog") == null);
    try std.testing.expect(router.findRoute("/docs") == null);
}
