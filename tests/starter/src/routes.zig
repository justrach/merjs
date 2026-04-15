const Route = @import("mer").Route;

const app_index = @import("app/index");
const app_about = @import("app/about");
const api_hello = @import("api/hello");

pub const routes: []const Route = &.{
    .{ .path = "/", .render = app_index.render, .render_stream = null, .meta = app_index.meta, .prerender = false },
    .{ .path = "/about", .render = app_about.render, .render_stream = null, .meta = app_about.meta, .prerender = true },
    .{ .path = "/api/hello", .render = api_hello.render, .render_stream = null, .meta = .{}, .prerender = false },
};
