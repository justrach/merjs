// GENERATED — do not edit by hand.
// Re-run `zig build codegen` to regenerate.

const Route = @import("mer").Route;

const api_collections = @import("api/collections");
const app_environment = @import("app/environment");
const app_index = @import("app/index");
const app_weather = @import("app/weather");

pub const routes: []const Route = &.{
    .{ .path = "/api/collections", .render = api_collections.render, .render_stream = if (@hasDecl(api_collections, "renderStream")) api_collections.renderStream else null, .meta = if (@hasDecl(api_collections, "meta")) api_collections.meta else .{}, .prerender = if (@hasDecl(api_collections, "prerender")) api_collections.prerender else false },
    .{ .path = "/environment", .render = app_environment.render, .render_stream = if (@hasDecl(app_environment, "renderStream")) app_environment.renderStream else null, .meta = if (@hasDecl(app_environment, "meta")) app_environment.meta else .{}, .prerender = if (@hasDecl(app_environment, "prerender")) app_environment.prerender else false },
    .{ .path = "/", .render = app_index.render, .render_stream = if (@hasDecl(app_index, "renderStream")) app_index.renderStream else null, .meta = if (@hasDecl(app_index, "meta")) app_index.meta else .{}, .prerender = if (@hasDecl(app_index, "prerender")) app_index.prerender else false },
    .{ .path = "/weather", .render = app_weather.render, .render_stream = if (@hasDecl(app_weather, "renderStream")) app_weather.renderStream else null, .meta = if (@hasDecl(app_weather, "meta")) app_weather.meta else .{}, .prerender = if (@hasDecl(app_weather, "prerender")) app_weather.prerender else false },
};

comptime {
    if (!@hasDecl(app_environment, "meta")) @compileError("app/environment.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_index, "meta")) @compileError("app/index.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_weather, "meta")) @compileError("app/weather.zig must export pub const meta: mer.Meta");
}

const app_layout = @import("app/layout");
pub const layout = app_layout.wrap;
pub const streamLayout = if (@hasDecl(app_layout, "streamWrap")) app_layout.streamWrap else null;
