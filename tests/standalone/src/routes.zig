// Consumer routes for standalone test project.
// This file mirrors what codegen would produce for a real consumer.

const Route = @import("mer").Route;

const app_index = @import("app/index");
const app_about = @import("app/about");

pub const routes: []const Route = &.{
    .{ .path = "/", .render = app_index.render, .render_stream = null, .meta = app_index.meta, .prerender = false },
    .{ .path = "/about", .render = app_about.render, .render_stream = null, .meta = app_about.meta, .prerender = false },
};
