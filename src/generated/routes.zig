// GENERATED — do not edit by hand.
// Re-run `zig build codegen` to regenerate.

const Route = @import("mer").Route;

const api_hello = @import("api/hello");
const api_time = @import("api/time");
const api_users = @import("api/users");
const app_about = @import("app/about");
const app_blog = @import("app/blog");
const app_counter = @import("app/counter");
const app_css_demo = @import("app/css-demo");
const app_dashboard = @import("app/dashboard");
const app_desktop = @import("app/desktop");
const app_docs = @import("app/docs");
const app_index = @import("app/index");
const app_map_demo = @import("app/map-demo");
const app_sandbox = @import("app/sandbox");
const app_stream_demo = @import("app/stream-demo");
const app_synth = @import("app/synth");
const app_users = @import("app/users");
const app_weather = @import("app/weather");

pub const routes: []const Route = &.{
    .{ .path = "/api/hello", .render = api_hello.render, .render_stream = if (@hasDecl(api_hello, "renderStream")) api_hello.renderStream else null, .meta = if (@hasDecl(api_hello, "meta")) api_hello.meta else .{}, .prerender = if (@hasDecl(api_hello, "prerender")) api_hello.prerender else false },
    .{ .path = "/api/time", .render = api_time.render, .render_stream = if (@hasDecl(api_time, "renderStream")) api_time.renderStream else null, .meta = if (@hasDecl(api_time, "meta")) api_time.meta else .{}, .prerender = if (@hasDecl(api_time, "prerender")) api_time.prerender else false },
    .{ .path = "/api/users", .render = api_users.render, .render_stream = if (@hasDecl(api_users, "renderStream")) api_users.renderStream else null, .meta = if (@hasDecl(api_users, "meta")) api_users.meta else .{}, .prerender = if (@hasDecl(api_users, "prerender")) api_users.prerender else false },
    .{ .path = "/about", .render = app_about.render, .render_stream = if (@hasDecl(app_about, "renderStream")) app_about.renderStream else null, .meta = if (@hasDecl(app_about, "meta")) app_about.meta else .{}, .prerender = if (@hasDecl(app_about, "prerender")) app_about.prerender else false },
    .{ .path = "/blog", .render = app_blog.render, .render_stream = if (@hasDecl(app_blog, "renderStream")) app_blog.renderStream else null, .meta = if (@hasDecl(app_blog, "meta")) app_blog.meta else .{}, .prerender = if (@hasDecl(app_blog, "prerender")) app_blog.prerender else false },
    .{ .path = "/counter", .render = app_counter.render, .render_stream = if (@hasDecl(app_counter, "renderStream")) app_counter.renderStream else null, .meta = if (@hasDecl(app_counter, "meta")) app_counter.meta else .{}, .prerender = if (@hasDecl(app_counter, "prerender")) app_counter.prerender else false },
    .{ .path = "/css-demo", .render = app_css_demo.render, .render_stream = if (@hasDecl(app_css_demo, "renderStream")) app_css_demo.renderStream else null, .meta = if (@hasDecl(app_css_demo, "meta")) app_css_demo.meta else .{}, .prerender = if (@hasDecl(app_css_demo, "prerender")) app_css_demo.prerender else false },
    .{ .path = "/dashboard", .render = app_dashboard.render, .render_stream = if (@hasDecl(app_dashboard, "renderStream")) app_dashboard.renderStream else null, .meta = if (@hasDecl(app_dashboard, "meta")) app_dashboard.meta else .{}, .prerender = if (@hasDecl(app_dashboard, "prerender")) app_dashboard.prerender else false },
    .{ .path = "/desktop", .render = app_desktop.render, .render_stream = if (@hasDecl(app_desktop, "renderStream")) app_desktop.renderStream else null, .meta = if (@hasDecl(app_desktop, "meta")) app_desktop.meta else .{}, .prerender = if (@hasDecl(app_desktop, "prerender")) app_desktop.prerender else false },
    .{ .path = "/docs", .render = app_docs.render, .render_stream = if (@hasDecl(app_docs, "renderStream")) app_docs.renderStream else null, .meta = if (@hasDecl(app_docs, "meta")) app_docs.meta else .{}, .prerender = if (@hasDecl(app_docs, "prerender")) app_docs.prerender else false },
    .{ .path = "/", .render = app_index.render, .render_stream = if (@hasDecl(app_index, "renderStream")) app_index.renderStream else null, .meta = if (@hasDecl(app_index, "meta")) app_index.meta else .{}, .prerender = if (@hasDecl(app_index, "prerender")) app_index.prerender else false },
    .{ .path = "/map-demo", .render = app_map_demo.render, .render_stream = if (@hasDecl(app_map_demo, "renderStream")) app_map_demo.renderStream else null, .meta = if (@hasDecl(app_map_demo, "meta")) app_map_demo.meta else .{}, .prerender = if (@hasDecl(app_map_demo, "prerender")) app_map_demo.prerender else false },
    .{ .path = "/sandbox", .render = app_sandbox.render, .render_stream = if (@hasDecl(app_sandbox, "renderStream")) app_sandbox.renderStream else null, .meta = if (@hasDecl(app_sandbox, "meta")) app_sandbox.meta else .{}, .prerender = if (@hasDecl(app_sandbox, "prerender")) app_sandbox.prerender else false },
    .{ .path = "/stream-demo", .render = app_stream_demo.render, .render_stream = if (@hasDecl(app_stream_demo, "renderStream")) app_stream_demo.renderStream else null, .meta = if (@hasDecl(app_stream_demo, "meta")) app_stream_demo.meta else .{}, .prerender = if (@hasDecl(app_stream_demo, "prerender")) app_stream_demo.prerender else false },
    .{ .path = "/synth", .render = app_synth.render, .render_stream = if (@hasDecl(app_synth, "renderStream")) app_synth.renderStream else null, .meta = if (@hasDecl(app_synth, "meta")) app_synth.meta else .{}, .prerender = if (@hasDecl(app_synth, "prerender")) app_synth.prerender else false },
    .{ .path = "/users", .render = app_users.render, .render_stream = if (@hasDecl(app_users, "renderStream")) app_users.renderStream else null, .meta = if (@hasDecl(app_users, "meta")) app_users.meta else .{}, .prerender = if (@hasDecl(app_users, "prerender")) app_users.prerender else false },
    .{ .path = "/weather", .render = app_weather.render, .render_stream = if (@hasDecl(app_weather, "renderStream")) app_weather.renderStream else null, .meta = if (@hasDecl(app_weather, "meta")) app_weather.meta else .{}, .prerender = if (@hasDecl(app_weather, "prerender")) app_weather.prerender else false },
};

comptime {
    if (!@hasDecl(app_about, "meta")) @compileError("app/about.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_blog, "meta")) @compileError("app/blog.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_counter, "meta")) @compileError("app/counter.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_css_demo, "meta")) @compileError("app/css-demo.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_dashboard, "meta")) @compileError("app/dashboard.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_desktop, "meta")) @compileError("app/desktop.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_docs, "meta")) @compileError("app/docs.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_index, "meta")) @compileError("app/index.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_map_demo, "meta")) @compileError("app/map-demo.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_sandbox, "meta")) @compileError("app/sandbox.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_stream_demo, "meta")) @compileError("app/stream-demo.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_synth, "meta")) @compileError("app/synth.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_users, "meta")) @compileError("app/users.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(app_weather, "meta")) @compileError("app/weather.zig must export pub const meta: mer.Meta");
}

const app_layout = @import("app/layout");
pub const layout = app_layout.wrap;
pub const streamLayout = if (@hasDecl(app_layout, "streamWrap")) app_layout.streamWrap else null;
const app_404 = @import("app/404");
pub const notFound = app_404.render;
