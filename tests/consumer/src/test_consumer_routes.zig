// Integration test: proves a consumer project can use merjs with its own routes.
// This is the core test for issue #62.
//
// Before the fix, ssr.zig did @import("generated/routes.zig") which resolved to
// merjs's cached copy containing api/hello, app/about, etc. — causing build
// failures for consumer projects with different pages.
//
// After the fix, ssr.zig does @import("routes") — a named module that the
// consumer's build.zig wires to their own routes file.

const std = @import("std");
const mer = @import("mer");
const ssr = @import("ssr.zig");

test "consumer: buildRouter uses consumer routes, not framework example routes" {
    var router = ssr.buildRouter(std.testing.allocator);
    defer router.deinit();

    // Consumer routes are present
    const home = router.findRoute("/").?;
    try std.testing.expectEqualStrings("Consumer Home", home.meta.title);

    const dash = router.findRoute("/dashboard").?;
    try std.testing.expectEqualStrings("Dashboard", dash.meta.title);

    // Only 2 routes total
    try std.testing.expectEqual(@as(usize, 2), router.routes.len);
}

test "consumer: framework example routes do NOT leak in" {
    var router = ssr.buildRouter(std.testing.allocator);
    defer router.deinit();

    // These are merjs example site routes — they must NOT exist in a consumer build.
    try std.testing.expect(router.findRoute("/api/hello") == null);
    try std.testing.expect(router.findRoute("/api/time") == null);
    try std.testing.expect(router.findRoute("/about") == null);
    try std.testing.expect(router.findRoute("/blog") == null);
    try std.testing.expect(router.findRoute("/docs") == null);
    try std.testing.expect(router.findRoute("/weather") == null);
}

test "consumer: route render functions produce correct output" {
    var router = ssr.buildRouter(std.testing.allocator);
    defer router.deinit();

    const route = router.findRoute("/").?;
    const resp = route.render(.{
        .method = .GET,
        .path = "/",
        .query_string = "",
        .body = "",
        .cookies_raw = "",
        .params = &.{},
        .allocator = std.testing.allocator,
    });
    try std.testing.expectEqualStrings("<h1>Consumer Home</h1>", resp.body);
    try std.testing.expect(resp.content_type == .html);
}
