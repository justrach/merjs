const std = @import("std");
const mer = @import("mer");
const routes = @import("routes");
const not_found = @import("app/404");

test "starter scaffold routes compile and load" {
    var router = mer.Router.fromGenerated(std.testing.allocator, routes);
    defer router.deinit();

    try std.testing.expectEqual(@as(usize, 3), router.routes.len);
    try std.testing.expect(router.findRoute("/") != null);
    try std.testing.expect(router.findRoute("/about") != null);
    try std.testing.expect(router.findRoute("/api/hello") != null);
}

test "starter scaffold 404 template compiles" {
    const resp = not_found.render(.{
        .method = .GET,
        .path = "/missing",
        .query_string = "",
        .body = "",
        .cookies_raw = "",
        .params = &.{},
        .allocator = std.testing.allocator,
    });

    try std.testing.expect(resp.status == .not_found);
    try std.testing.expect(resp.content_type == .html);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "This route doesn't exist yet.") != null);
}
