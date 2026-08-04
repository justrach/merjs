const mer = @import("mer");
const index_page = @import("app/index");
const layout_mod = @import("app/layout");

pub const routes = &[_]mer.Route{.{
    .path = "/",
    .render = index_page.render,
    .render_stream = if (@hasDecl(index_page, "renderStream")) index_page.renderStream else null,
    .meta = if (@hasDecl(index_page, "meta")) index_page.meta else .{},
    .prerender = false,
}};

pub const layout = layout_mod.wrap;
