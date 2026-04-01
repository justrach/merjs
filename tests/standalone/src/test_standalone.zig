// Standalone consumer integration test.
// Proves merjs works as a dependency — a consumer project uses only
// @import("mer") for types and @import("routes") for its own routes.
// This simulates what a real user would do after `zig fetch merjs`.

const std = @import("std");
const mer = @import("mer");
const generated = @import("routes");

// ---------------------------------------------------------------------------
// 1. mer module provides the expected public types
// ---------------------------------------------------------------------------

test "mer: Route type is accessible" {
    const RouteType = mer.Route;
    // Route has the expected fields.
    const r: RouteType = .{
        .path = "/test",
        .render = undefined,
    };
    try std.testing.expectEqualStrings("/test", r.path);
}

test "mer: Request and Response types are accessible" {
    // Just prove the types resolve — this is a compile-time check.
    const req = mer.Request{
        .method = .GET,
        .path = "/",
        .query_string = "",
        .body = "",
        .cookies_raw = "",
        .params = &.{},
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqualStrings("/", req.path);

    const resp = mer.html("<p>hello</p>");
    try std.testing.expect(resp.content_type == .html);
    try std.testing.expectEqualStrings("<p>hello</p>", resp.body);
}

test "mer: Meta type has expected fields" {
    const m: mer.Meta = .{
        .title = "My Page",
        .description = "A test page",
    };
    try std.testing.expectEqualStrings("My Page", m.title);
    try std.testing.expectEqualStrings("A test page", m.description);
    // Default values.
    try std.testing.expectEqualStrings("website", m.og_type);
    try std.testing.expectEqualStrings("merjs", m.og_site_name);
}
test "mer: response helpers are accessible" {
    const t = mer.text(.ok, "plain");
    try std.testing.expect(t.content_type == .text);

    const j = mer.json("{\"ok\":true}");
    try std.testing.expect(j.content_type == .json);

    const nf = mer.notFound();
    try std.testing.expect(nf.status == .not_found);

    const redir = mer.redirect("/new", .see_other);
    try std.testing.expect(redir.status == .see_other);

    const bad = mer.badRequest("nope");
    try std.testing.expect(bad.status == .bad_request);
}

test "mer: version string is present" {
    try std.testing.expect(mer.version.len > 0);
}

test "mer: RenderFn type matches page signatures" {
    // Prove that a consumer page's render function has the right type.
    const render_fn: mer.RenderFn = @import("routes").routes[0].render;
    _ = render_fn;
}

// ---------------------------------------------------------------------------
// 2. Consumer routes work correctly
// ---------------------------------------------------------------------------

test "consumer routes: correct number of routes" {
    try std.testing.expectEqual(@as(usize, 2), generated.routes.len);
}

test "consumer routes: index route exists at /" {
    const route = generated.routes[0];
    try std.testing.expectEqualStrings("/", route.path);
    try std.testing.expectEqualStrings("Standalone Home", route.meta.title);
}

test "consumer routes: about route exists at /about" {
    const route = generated.routes[1];
    try std.testing.expectEqualStrings("/about", route.path);
    try std.testing.expectEqualStrings("Standalone About", route.meta.title);
}

test "consumer routes: render functions produce correct HTML" {
    const req = mer.Request{
        .method = .GET,
        .path = "/",
        .query_string = "",
        .body = "",
        .cookies_raw = "",
        .params = &.{},
        .allocator = std.testing.allocator,
    };

    const home_resp = generated.routes[0].render(req);
    try std.testing.expectEqualStrings("<h1>Standalone Home</h1>", home_resp.body);
    try std.testing.expect(home_resp.content_type == .html);

    const about_resp = generated.routes[1].render(req);
    try std.testing.expectEqualStrings("<h1>About This App</h1>", about_resp.body);
    try std.testing.expect(about_resp.content_type == .html);
}

// ---------------------------------------------------------------------------
// 3. Framework example routes do NOT leak into consumer build
// ---------------------------------------------------------------------------

test "framework example routes are NOT present" {
    // These paths belong to the merjs example site — they must NOT appear
    // in a consumer project that defines its own routes.
    for (generated.routes) |route| {
        // None of the framework example paths should be here.
        try std.testing.expect(!std.mem.eql(u8, route.path, "/api/hello"));
        try std.testing.expect(!std.mem.eql(u8, route.path, "/api/time"));
        try std.testing.expect(!std.mem.eql(u8, route.path, "/blog"));
        try std.testing.expect(!std.mem.eql(u8, route.path, "/docs"));
        try std.testing.expect(!std.mem.eql(u8, route.path, "/weather"));
        try std.testing.expect(!std.mem.eql(u8, route.path, "/counter"));
        try std.testing.expect(!std.mem.eql(u8, route.path, "/synth"));
    }
}

// ---------------------------------------------------------------------------
// 4. Consumer can build a route lookup (inline, without Router module)
// ---------------------------------------------------------------------------

test "consumer route lookup by path" {
    // A consumer can iterate routes to find a match — this is what Router.findRoute
    // does internally. Proves the routes table is usable for dispatch.
    const target_path = "/about";
    var found: ?mer.Route = null;
    for (generated.routes) |route| {
        if (std.mem.eql(u8, route.path, target_path)) {
            found = route;
            break;
        }
    }
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("Standalone About", found.?.meta.title);
}

test "consumer route lookup: unknown path returns null" {
    const target_path = "/nonexistent";
    var found: ?mer.Route = null;
    for (generated.routes) |route| {
        if (std.mem.eql(u8, route.path, target_path)) {
            found = route;
            break;
        }
    }
    try std.testing.expect(found == null);
}

// ---------------------------------------------------------------------------
// 5. Runtime re-exports — the whole point of issue #69
// ---------------------------------------------------------------------------

test "mer: Router.fromGenerated builds router from consumer routes" {
    var router = mer.Router.fromGenerated(std.testing.allocator, generated);
    defer router.deinit();

    // Correct route count
    try std.testing.expectEqual(@as(usize, 2), router.routes.len);

    // Exact path lookup works
    const home = router.findRoute("/").?;
    try std.testing.expectEqualStrings("Standalone Home", home.meta.title);

    const about = router.findRoute("/about").?;
    try std.testing.expectEqualStrings("Standalone About", about.meta.title);

    // Unknown path returns null
    try std.testing.expect(router.findRoute("/nonexistent") == null);
}

test "mer: Config type is accessible with expected defaults" {
    const config = mer.Config{};
    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqual(@as(u16, 3000), config.port);
    try std.testing.expect(!config.dev);
}

test "mer: Watcher can be constructed" {
    var watcher = mer.Watcher.init(std.testing.allocator, "app");
    defer watcher.deinit();
    try std.testing.expectEqualStrings("app", watcher.watch_dir);
}

test "mer: Server can be constructed (without listening)" {
    var router = mer.Router.fromGenerated(std.testing.allocator, generated);
    defer router.deinit();
    // Just prove Server.init compiles and returns — don't call listen().
    var server = mer.Server.init(std.testing.allocator, .{
        .host = "127.0.0.1",
        .port = 0,
    }, &router, null);
    // Server has a thread pool that needs no cleanup if we never call listen().
    _ = &server;
}

test "mer: runPrerender function is accessible" {
    // Just prove the function signature resolves — don't actually run it
    // (it writes to dist/ which we don't want in tests).
    const f = mer.runPrerender;
    try std.testing.expect(@TypeOf(f) != void);
}

// ---------------------------------------------------------------------------
// 6. mer utility functions work for consumers
// ---------------------------------------------------------------------------

test "mer: formParam parses URL-encoded body" {
    const body = "name=alice&age=30&city=paris";
    try std.testing.expectEqualStrings("alice", mer.formParam(body, "name").?);
    try std.testing.expectEqualStrings("30", mer.formParam(body, "age").?);
    try std.testing.expectEqualStrings("paris", mer.formParam(body, "city").?);
    try std.testing.expect(mer.formParam(body, "missing") == null);
}
