// Consumer routes — NOT the framework example routes.
// This file proves #62: consumer projects can have their own routes
// without conflicting with merjs's api/hello, app/about, etc.

const Route = @import("mer").Route;

const app_index = @import("app/index");
const app_dashboard = @import("app/dashboard");

pub const routes: []const Route = &.{
    .{ .path = "/", .render = app_index.render, .render_stream = null, .meta = app_index.meta, .prerender = false },
    .{ .path = "/dashboard", .render = app_dashboard.render, .render_stream = null, .meta = app_dashboard.meta, .prerender = false },
};
