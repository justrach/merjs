// GENERATED — do not edit by hand.
// Re-run `zig build codegen` to regenerate.

const Route = @import("../router.zig").Route;

const api_hello = @import("api/hello");
const api_time = @import("api/time");
const api_users = @import("api/users");
const app_about = @import("app/about");
const app_counter = @import("app/counter");
const app_dashboard = @import("app/dashboard");
const app_index = @import("app/index");
const app_users = @import("app/users");
const app_weather = @import("app/weather");

pub const routes: []const Route = &.{
    .{ .path = "/api/hello", .render = api_hello.render, .meta = if (@hasDecl(api_hello, "meta")) api_hello.meta else .{}, .prerender = if (@hasDecl(api_hello, "prerender")) api_hello.prerender else false },
    .{ .path = "/api/time", .render = api_time.render, .meta = if (@hasDecl(api_time, "meta")) api_time.meta else .{}, .prerender = if (@hasDecl(api_time, "prerender")) api_time.prerender else false },
    .{ .path = "/api/users", .render = api_users.render, .meta = if (@hasDecl(api_users, "meta")) api_users.meta else .{}, .prerender = if (@hasDecl(api_users, "prerender")) api_users.prerender else false },
    .{ .path = "/about", .render = app_about.render, .meta = if (@hasDecl(app_about, "meta")) app_about.meta else .{}, .prerender = if (@hasDecl(app_about, "prerender")) app_about.prerender else false },
    .{ .path = "/counter", .render = app_counter.render, .meta = if (@hasDecl(app_counter, "meta")) app_counter.meta else .{}, .prerender = if (@hasDecl(app_counter, "prerender")) app_counter.prerender else false },
    .{ .path = "/dashboard", .render = app_dashboard.render, .meta = if (@hasDecl(app_dashboard, "meta")) app_dashboard.meta else .{}, .prerender = if (@hasDecl(app_dashboard, "prerender")) app_dashboard.prerender else false },
    .{ .path = "/", .render = app_index.render, .meta = if (@hasDecl(app_index, "meta")) app_index.meta else .{}, .prerender = if (@hasDecl(app_index, "prerender")) app_index.prerender else false },
    .{ .path = "/users", .render = app_users.render, .meta = if (@hasDecl(app_users, "meta")) app_users.meta else .{}, .prerender = if (@hasDecl(app_users, "prerender")) app_users.prerender else false },
    .{ .path = "/weather", .render = app_weather.render, .meta = if (@hasDecl(app_weather, "meta")) app_weather.meta else .{}, .prerender = if (@hasDecl(app_weather, "prerender")) app_weather.prerender else false },
};

comptime {
    if (!@hasDecl(app_about, "meta")) @compileError("app/about.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_counter, "meta")) @compileError("app/counter.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_dashboard, "meta")) @compileError("app/dashboard.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_index, "meta")) @compileError("app/index.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_users, "meta")) @compileError("app/users.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_weather, "meta")) @compileError("app/weather.zig must export pub const meta: mer.Meta");
}

const app_layout = @import("app/layout");
pub const layout = app_layout.wrap;
const app_404 = @import("app/404");
pub const notFound = app_404.render;
