// GENERATED — do not edit by hand.
// Re-run `zig build codegen` to regenerate.

const Route = @import("../router.zig").Route;

const api_ai = @import("api/ai");
const api_collections = @import("api/collections");
const api_suggestions = @import("api/suggestions");
const app_ai = @import("app/ai");
const app_environment = @import("app/environment");
const app_explore = @import("app/explore");
const app_index = @import("app/index");
const app_weather = @import("app/weather");

pub const routes: []const Route = &.{
    .{ .path = "/api/ai", .render = api_ai.render, .meta = if (@hasDecl(api_ai, "meta")) api_ai.meta else .{}, .prerender = if (@hasDecl(api_ai, "prerender")) api_ai.prerender else false },
    .{ .path = "/api/collections", .render = api_collections.render, .meta = if (@hasDecl(api_collections, "meta")) api_collections.meta else .{}, .prerender = if (@hasDecl(api_collections, "prerender")) api_collections.prerender else false },
    .{ .path = "/api/suggestions", .render = api_suggestions.render, .meta = if (@hasDecl(api_suggestions, "meta")) api_suggestions.meta else .{}, .prerender = if (@hasDecl(api_suggestions, "prerender")) api_suggestions.prerender else false },
    .{ .path = "/ai", .render = app_ai.render, .meta = if (@hasDecl(app_ai, "meta")) app_ai.meta else .{}, .prerender = if (@hasDecl(app_ai, "prerender")) app_ai.prerender else false },
    .{ .path = "/environment", .render = app_environment.render, .meta = if (@hasDecl(app_environment, "meta")) app_environment.meta else .{}, .prerender = if (@hasDecl(app_environment, "prerender")) app_environment.prerender else false },
    .{ .path = "/explore", .render = app_explore.render, .meta = if (@hasDecl(app_explore, "meta")) app_explore.meta else .{}, .prerender = if (@hasDecl(app_explore, "prerender")) app_explore.prerender else false },
    .{ .path = "/", .render = app_index.render, .meta = if (@hasDecl(app_index, "meta")) app_index.meta else .{}, .prerender = if (@hasDecl(app_index, "prerender")) app_index.prerender else false },
    .{ .path = "/weather", .render = app_weather.render, .meta = if (@hasDecl(app_weather, "meta")) app_weather.meta else .{}, .prerender = if (@hasDecl(app_weather, "prerender")) app_weather.prerender else false },
};

comptime {
    if (!@hasDecl(app_ai, "meta")) @compileError("app/ai.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_environment, "meta")) @compileError("app/environment.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_explore, "meta")) @compileError("app/explore.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_index, "meta")) @compileError("app/index.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_weather, "meta")) @compileError("app/weather.zig must export pub const meta: mer.Meta");
}

const app_layout = @import("app/layout");
pub const layout = app_layout.wrap;
const app_404 = @import("app/404");
pub const notFound = app_404.render;
