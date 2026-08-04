// router.zig — file-based router with hash-map exact matching.
// app/index.zig    → "/"
// app/about.zig    → "/about"
// app/users/[id].zig → "/users/:id"  (dynamic segment)

const std = @import("std");
const mer = @import("mer");

pub const RenderFn = mer.RenderFn;
pub const StreamRenderFn = mer.StreamRenderFn;
/// Legacy layouts may return allocator-owned, borrowed, static, or foreign
/// slices. Dispatch copies distinct results and never infers ownership.
pub const LayoutFn = *const fn (std.mem.Allocator, []const u8, []const u8, mer.Meta) []const u8;

pub const StreamParts = mer.StreamParts;
/// Allocated parts must set their corresponding allocator metadata.
pub const StreamLayoutFn = *const fn (std.mem.Allocator, []const u8, mer.Meta) StreamParts;

pub const Route = mer.Route;

pub const MatchResult = struct {
    route: Route,
    request: mer.Request,
    allocator: std.mem.Allocator,
    owned_params: []mer.Param = &.{},

    pub fn deinit(self: *MatchResult) void {
        if (self.owned_params.len > 0) self.allocator.free(self.owned_params);
        self.* = undefined;
    }
};

const PathMatch = struct {
    route: Route,
    param_count: usize,
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
    max_params: usize = 0,

    /// Compatibility constructor. Allocation failure is fatal rather than
    /// returning a partially initialized router with missing routes.
    pub fn init(allocator: std.mem.Allocator, routes: []const Route) Router {
        return initFallible(allocator, routes) catch @panic("out of memory initializing router");
    }

    pub fn initFallible(allocator: std.mem.Allocator, routes: []const Route) !Router {
        var router = Router{ .allocator = allocator, .routes = routes };
        errdefer router.exact_map.deinit(allocator);

        var dynamic_list: std.ArrayListUnmanaged(Route) = .empty;
        errdefer dynamic_list.deinit(allocator);
        for (routes, 0..) |route, i| {
            const param_count = routeParamCount(route.path);
            if (param_count > 0) {
                try dynamic_list.append(allocator, route);
                router.max_params = @max(router.max_params, param_count);
            } else {
                try router.exact_map.put(allocator, route.path, i);
            }
        }
        router.dynamic_routes = try dynamic_list.toOwnedSlice(allocator);
        return router;
    }

    /// Build a Router from a codegen'd routes module (the `@import("routes")` namespace).
    /// Reads `routes`, `layout`, `streamLayout`, `notFound` if declared.
    pub fn fromGenerated(allocator: std.mem.Allocator, comptime generated: type) Router {
        return fromGeneratedFallible(allocator, generated) catch @panic("out of memory initializing generated router");
    }

    pub fn fromGeneratedFallible(allocator: std.mem.Allocator, comptime generated: type) !Router {
        var r = try Router.initFallible(allocator, generated.routes);
        if (@hasDecl(generated, "layout")) r.layout = generated.layout;
        if (@hasDecl(generated, "streamLayout")) r.stream_layout = generated.streamLayout;
        if (@hasDecl(generated, "notFound")) r.not_found = generated.notFound;
        return r;
    }

    pub fn deinit(self: *Router) void {
        self.exact_map.deinit(self.allocator);
        self.allocator.free(self.dynamic_routes);
    }

    /// Return true only for a concrete route path, excluding dynamic matches.
    /// A trailing slash uses the same fallback as findRoute.
    pub fn hasExactRoute(self: Router, path_arg: []const u8) bool {
        return self.findExact(path_arg) != null;
    }

    /// Find a route by path (exact or dynamic match). Returns null if not found.
    pub fn findRoute(self: Router, path_arg: []const u8) ?Route {
        if (self.findExact(path_arg)) |route| return route;
        return if (self.findDynamic(path_arg, null)) |result| result.route else null;
    }

    /// Match a request and populate any dynamic route parameters. The caller
    /// must deinit a non-null result after synchronous rendering completes.
    pub fn match(self: Router, req: mer.Request) !?MatchResult {
        if (self.findExact(req.path)) |route| {
            return .{ .route = route, .request = req, .allocator = req.allocator };
        }

        if (self.max_params == 0) return null;
        const params = try req.allocator.alloc(mer.Param, self.max_params);
        errdefer req.allocator.free(params);
        const result = self.findDynamic(req.path, params) orelse {
            req.allocator.free(params);
            return null;
        };
        var matched_req = req;
        matched_req.params = params[0..result.param_count];
        return .{
            .route = result.route,
            .request = matched_req,
            .allocator = req.allocator,
            .owned_params = params,
        };
    }

    fn findExact(self: Router, path_arg: []const u8) ?Route {
        if (self.exact_map.get(path_arg)) |idx| return self.routes[idx];
        if (trimTrailingSlash(path_arg)) |trimmed| {
            if (self.exact_map.get(trimmed)) |idx| return self.routes[idx];
        }
        return null;
    }

    fn findDynamic(self: Router, path_arg: []const u8, params: ?[]mer.Param) ?PathMatch {
        for (self.dynamic_routes) |route| {
            if (matchRouteInternal(route.path, path_arg, params)) |n| return .{ .route = route, .param_count = n };
        }
        if (trimTrailingSlash(path_arg)) |trimmed| {
            for (self.dynamic_routes) |route| {
                if (matchRouteInternal(route.path, trimmed, params)) |n| return .{ .route = route, .param_count = n };
            }
        }
        return null;
    }
};

fn trimTrailingSlash(path: []const u8) ?[]const u8 {
    if (path.len > 1 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
    return null;
}

fn routeParamCount(path: []const u8) usize {
    var count: usize = 0;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len > 0 and segment[0] == ':') count += 1;
    }
    return count;
}

/// Try to match `req_path` against `route_path` where `:name` segments are wildcards.
pub fn matchRoute(route_path: []const u8, req_path: []const u8, out: []mer.Param) ?usize {
    return matchRouteInternal(route_path, req_path, out);
}

fn matchRouteInternal(route_path: []const u8, req_path: []const u8, out: ?[]mer.Param) ?usize {
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
            if (out) |params| {
                if (n >= params.len) return null;
                params[n] = .{ .key = r_seg[1..], .value = p_seg };
            }
            n += 1;
        } else if (!std.mem.eql(u8, r_seg, p_seg)) return null;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

fn dummyRender(_: mer.Request) mer.Response {
    return mer.html("<p>ok</p>");
}

test "matchRoute: exact static path" {
    var out: [8]mer.Param = undefined;
    try std.testing.expectEqual(@as(?usize, 0), matchRoute("/about", "/about", &out));
}

test "matchRoute: root path" {
    var out: [8]mer.Param = undefined;
    try std.testing.expectEqual(@as(?usize, 0), matchRoute("/", "/", &out));
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
    try std.testing.expect(matchRoute("/users/:id", "/users/", &out) == null);
}

test "Router.init: separates exact and dynamic routes" {
    const routes = [_]Route{
        .{ .path = "/", .render = dummyRender },
        .{ .path = "/about", .render = dummyRender },
        .{ .path = "/users/:id", .render = dummyRender },
        .{ .path = "/org/:org/repo/:repo", .render = dummyRender },
    };
    var router = try Router.initFallible(std.testing.allocator, &routes);
    defer router.deinit();
    try std.testing.expectEqual(@as(u32, 2), router.exact_map.count());
    try std.testing.expectEqual(@as(usize, 2), router.dynamic_routes.len);
}

test "Router exact normalized match beats raw dynamic match" {
    const routes = [_]Route{
        .{ .path = "/users/new", .render = dummyRender },
        .{ .path = "/users/:id/", .render = dummyRender },
    };
    var router = try Router.initFallible(std.testing.allocator, &routes);
    defer router.deinit();
    try std.testing.expectEqualStrings("/users/new", router.findRoute("/users/new/").?.path);
}

test "Router.hasExactRoute excludes dynamic matches" {
    const routes = [_]Route{
        .{ .path = "/about", .render = dummyRender },
        .{ .path = "/:slug", .render = dummyRender },
    };
    var router = Router.init(std.testing.allocator, &routes);
    defer router.deinit();
    try std.testing.expect(router.hasExactRoute("/about"));
    try std.testing.expect(router.hasExactRoute("/about/"));
    try std.testing.expect(!router.hasExactRoute("/favicon.ico"));
    try std.testing.expect(router.findRoute("/favicon.ico") != null);
}

test "Router.findRoute exact dynamic trailing slash and missing" {
    const routes = [_]Route{
        .{ .path = "/", .render = dummyRender },
        .{ .path = "/about", .render = dummyRender, .meta = .{ .title = "About" } },
        .{ .path = "/users/:id", .render = dummyRender, .meta = .{ .title = "User" } },
    };
    var router = Router.init(std.testing.allocator, &routes);
    defer router.deinit();
    try std.testing.expectEqualStrings("About", router.findRoute("/about").?.meta.title);
    try std.testing.expectEqualStrings("User", router.findRoute("/users/99").?.meta.title);
    try std.testing.expectEqualStrings("/about", router.findRoute("/about/").?.path);
    try std.testing.expect(router.findRoute("/nope") == null);
}

test "Router.match supports more than eight params and frees them" {
    const routes = [_]Route{
        .{ .path = "/:a/:b/:c/:d/:e/:f/:g/:h/:i", .render = dummyRender },
    };
    var router = try Router.initFallible(std.testing.allocator, &routes);
    defer router.deinit();

    const req = mer.Request.init(std.testing.allocator, .GET, "/1/2/3/4/5/6/7/8/9/");
    var matched = (try router.match(req)).?;
    defer matched.deinit();
    try std.testing.expectEqual(@as(usize, 9), matched.request.params.len);
    try std.testing.expectEqualStrings("9", matched.request.param("i").?);
}

test "Router.initFallible reports allocation failure" {
    var storage: [1]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    const routes = [_]Route{.{ .path = "/route", .render = dummyRender }};
    try std.testing.expectError(error.OutOfMemory, Router.initFallible(fba.allocator(), &routes));
}

test "Router.findRoute: consumer routes without framework example routes" {
    const consumer_routes = [_]Route{
        .{ .path = "/", .render = dummyRender, .meta = .{ .title = "My App" } },
        .{ .path = "/dashboard", .render = dummyRender, .meta = .{ .title = "Dashboard" } },
        .{ .path = "/settings", .render = dummyRender, .meta = .{ .title = "Settings" } },
        .{ .path = "/projects/:id", .render = dummyRender },
    };
    var router = Router.init(std.testing.allocator, &consumer_routes);
    defer router.deinit();
    try std.testing.expectEqualStrings("My App", router.findRoute("/").?.meta.title);
    try std.testing.expectEqualStrings("Dashboard", router.findRoute("/dashboard").?.meta.title);
    try std.testing.expectEqualStrings("Settings", router.findRoute("/settings").?.meta.title);
    try std.testing.expect(router.findRoute("/projects/123") != null);
    try std.testing.expect(router.findRoute("/about") == null);
    try std.testing.expect(router.findRoute("/api/hello") == null);
    try std.testing.expect(router.findRoute("/blog") == null);
    try std.testing.expect(router.findRoute("/docs") == null);
}
