// GENERATED — do not edit by hand.
// Re-run `zig build codegen` to regenerate.

const Route = @import("../router.zig").Route;

const examples_site_api_hello = @import("examples/site/api/hello");
const examples_site_api_time = @import("examples/site/api/time");
const examples_site_api_users = @import("examples/site/api/users");
const examples_site_app_about = @import("examples/site/app/about");
const examples_site_app_blog = @import("examples/site/app/blog");
const examples_site_app_counter = @import("examples/site/app/counter");
const examples_site_app_dashboard = @import("examples/site/app/dashboard");
const examples_site_app_docs = @import("examples/site/app/docs");
const examples_site_app_index = @import("examples/site/app/index");
const examples_site_app_map_demo = @import("examples/site/app/map-demo");
const examples_site_app_sandbox = @import("examples/site/app/sandbox");
const examples_site_app_stream_demo = @import("examples/site/app/stream-demo");
const examples_site_app_synth = @import("examples/site/app/synth");
const examples_site_app_users = @import("examples/site/app/users");
const examples_site_app_weather = @import("examples/site/app/weather");

pub const routes: []const Route = &.{
    .{ .path = "/api/hello", .render = examples_site_api_hello.render, .render_stream = if (@hasDecl(examples_site_api_hello, "renderStream")) examples_site_api_hello.renderStream else null, .meta = if (@hasDecl(examples_site_api_hello, "meta")) examples_site_api_hello.meta else .{}, .prerender = if (@hasDecl(examples_site_api_hello, "prerender")) examples_site_api_hello.prerender else false },
    .{ .path = "/api/time", .render = examples_site_api_time.render, .render_stream = if (@hasDecl(examples_site_api_time, "renderStream")) examples_site_api_time.renderStream else null, .meta = if (@hasDecl(examples_site_api_time, "meta")) examples_site_api_time.meta else .{}, .prerender = if (@hasDecl(examples_site_api_time, "prerender")) examples_site_api_time.prerender else false },
    .{ .path = "/api/users", .render = examples_site_api_users.render, .render_stream = if (@hasDecl(examples_site_api_users, "renderStream")) examples_site_api_users.renderStream else null, .meta = if (@hasDecl(examples_site_api_users, "meta")) examples_site_api_users.meta else .{}, .prerender = if (@hasDecl(examples_site_api_users, "prerender")) examples_site_api_users.prerender else false },
    .{ .path = "/about", .render = examples_site_app_about.render, .render_stream = if (@hasDecl(examples_site_app_about, "renderStream")) examples_site_app_about.renderStream else null, .meta = if (@hasDecl(examples_site_app_about, "meta")) examples_site_app_about.meta else .{}, .prerender = if (@hasDecl(examples_site_app_about, "prerender")) examples_site_app_about.prerender else false },
    .{ .path = "/blog", .render = examples_site_app_blog.render, .render_stream = if (@hasDecl(examples_site_app_blog, "renderStream")) examples_site_app_blog.renderStream else null, .meta = if (@hasDecl(examples_site_app_blog, "meta")) examples_site_app_blog.meta else .{}, .prerender = if (@hasDecl(examples_site_app_blog, "prerender")) examples_site_app_blog.prerender else false },
    .{ .path = "/counter", .render = examples_site_app_counter.render, .render_stream = if (@hasDecl(examples_site_app_counter, "renderStream")) examples_site_app_counter.renderStream else null, .meta = if (@hasDecl(examples_site_app_counter, "meta")) examples_site_app_counter.meta else .{}, .prerender = if (@hasDecl(examples_site_app_counter, "prerender")) examples_site_app_counter.prerender else false },
    .{ .path = "/dashboard", .render = examples_site_app_dashboard.render, .render_stream = if (@hasDecl(examples_site_app_dashboard, "renderStream")) examples_site_app_dashboard.renderStream else null, .meta = if (@hasDecl(examples_site_app_dashboard, "meta")) examples_site_app_dashboard.meta else .{}, .prerender = if (@hasDecl(examples_site_app_dashboard, "prerender")) examples_site_app_dashboard.prerender else false },
    .{ .path = "/docs", .render = examples_site_app_docs.render, .render_stream = if (@hasDecl(examples_site_app_docs, "renderStream")) examples_site_app_docs.renderStream else null, .meta = if (@hasDecl(examples_site_app_docs, "meta")) examples_site_app_docs.meta else .{}, .prerender = if (@hasDecl(examples_site_app_docs, "prerender")) examples_site_app_docs.prerender else false },
    .{ .path = "/", .render = examples_site_app_index.render, .render_stream = if (@hasDecl(examples_site_app_index, "renderStream")) examples_site_app_index.renderStream else null, .meta = if (@hasDecl(examples_site_app_index, "meta")) examples_site_app_index.meta else .{}, .prerender = if (@hasDecl(examples_site_app_index, "prerender")) examples_site_app_index.prerender else false },
    .{ .path = "/map-demo", .render = examples_site_app_map_demo.render, .render_stream = if (@hasDecl(examples_site_app_map_demo, "renderStream")) examples_site_app_map_demo.renderStream else null, .meta = if (@hasDecl(examples_site_app_map_demo, "meta")) examples_site_app_map_demo.meta else .{}, .prerender = if (@hasDecl(examples_site_app_map_demo, "prerender")) examples_site_app_map_demo.prerender else false },
    .{ .path = "/sandbox", .render = examples_site_app_sandbox.render, .render_stream = if (@hasDecl(examples_site_app_sandbox, "renderStream")) examples_site_app_sandbox.renderStream else null, .meta = if (@hasDecl(examples_site_app_sandbox, "meta")) examples_site_app_sandbox.meta else .{}, .prerender = if (@hasDecl(examples_site_app_sandbox, "prerender")) examples_site_app_sandbox.prerender else false },
    .{ .path = "/stream-demo", .render = examples_site_app_stream_demo.render, .render_stream = if (@hasDecl(examples_site_app_stream_demo, "renderStream")) examples_site_app_stream_demo.renderStream else null, .meta = if (@hasDecl(examples_site_app_stream_demo, "meta")) examples_site_app_stream_demo.meta else .{}, .prerender = if (@hasDecl(examples_site_app_stream_demo, "prerender")) examples_site_app_stream_demo.prerender else false },
    .{ .path = "/synth", .render = examples_site_app_synth.render, .render_stream = if (@hasDecl(examples_site_app_synth, "renderStream")) examples_site_app_synth.renderStream else null, .meta = if (@hasDecl(examples_site_app_synth, "meta")) examples_site_app_synth.meta else .{}, .prerender = if (@hasDecl(examples_site_app_synth, "prerender")) examples_site_app_synth.prerender else false },
    .{ .path = "/users", .render = examples_site_app_users.render, .render_stream = if (@hasDecl(examples_site_app_users, "renderStream")) examples_site_app_users.renderStream else null, .meta = if (@hasDecl(examples_site_app_users, "meta")) examples_site_app_users.meta else .{}, .prerender = if (@hasDecl(examples_site_app_users, "prerender")) examples_site_app_users.prerender else false },
    .{ .path = "/weather", .render = examples_site_app_weather.render, .render_stream = if (@hasDecl(examples_site_app_weather, "renderStream")) examples_site_app_weather.renderStream else null, .meta = if (@hasDecl(examples_site_app_weather, "meta")) examples_site_app_weather.meta else .{}, .prerender = if (@hasDecl(examples_site_app_weather, "prerender")) examples_site_app_weather.prerender else false },
};

comptime {
    if (!@hasDecl(examples_site_app_about, "meta")) @compileError("examples/site/app/about.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(examples_site_app_blog, "meta")) @compileError("examples/site/app/blog.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(examples_site_app_counter, "meta")) @compileError("examples/site/app/counter.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(examples_site_app_dashboard, "meta")) @compileError("examples/site/app/dashboard.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(examples_site_app_docs, "meta")) @compileError("examples/site/app/docs.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(examples_site_app_index, "meta")) @compileError("examples/site/app/index.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(examples_site_app_map_demo, "meta")) @compileError("examples/site/app/map-demo.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(examples_site_app_sandbox, "meta")) @compileError("examples/site/app/sandbox.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(examples_site_app_stream_demo, "meta")) @compileError("examples/site/app/stream-demo.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(examples_site_app_synth, "meta")) @compileError("examples/site/app/synth.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(examples_site_app_users, "meta")) @compileError("examples/site/app/users.zig must export pub const meta: mer.Meta");
    if (!@hasDecl(examples_site_app_weather, "meta")) @compileError("examples/site/app/weather.zig must export pub const meta: mer.Meta");
}

const app_layout = @import("examples/site/app/layout");
pub const layout = app_layout.wrap;
pub const streamLayout = if (@hasDecl(app_layout, "streamWrap")) app_layout.streamWrap else null;
const app_404 = @import("examples/site/app/404");
pub const notFound = app_404.render;
