const mer = @import("mer");
const h = mer.h;

pub const prerender = true;

pub const meta: mer.Meta = .{
    .title = "About",
    .description = "About this merjs project.",
};

const page_node = page();

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn page() h.Node {
    return h.div(.{ .class = "page" }, .{
        h.h1(.{ .class = "title" }, "About"),
        h.p(.{}, .{
            h.text("This project is built with "),
            h.a(.{ .href = "https://github.com/justrach/merjs" }, "merjs"),
            h.text(" — a Zig-native web framework with file-based routing, SSR, and WASM support."),
        }),
        h.div(.{ .class = "features" }, .{
            feature("File-based routing", "Drop a .zig file in app/ or api/ and it becomes a route."),
            feature("Server-side rendering", "Pages render at request time via render(req)."),
            feature("Type-safe APIs", "Return Zig structs as JSON — no hand-rolled serialization."),
            feature("Zero node_modules", "One zig build serve. That's it."),
        }),
        h.a(.{ .href = "/", .class = "btn" }, "Back to home"),
    });
}

fn feature(title: []const u8, desc: []const u8) h.Node {
    return h.div(.{ .class = "feature" }, .{
        h.div(.{ .class = "feature-title" }, title),
        h.p(.{ .class = "feature-desc" }, desc),
    });
}
