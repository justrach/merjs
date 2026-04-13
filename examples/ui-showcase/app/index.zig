const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "Welcome",
    .description = "A new merjs project.",
};

const page_node = page();

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn page() h.Node {
    return h.div(.{ .class = "page" }, .{
        h.h1(.{ .class = "title" }, "Welcome to merjs"),
        h.p(.{ .class = "sub" }, .{
            h.text("Edit "),
            h.code(.{}, "app/index.zig"),
            h.text(" to get started."),
        }),
        h.div(.{ .class = "links" }, .{
            h.a(.{ .href = "/about", .class = "btn" }, "About"),
            h.a(.{ .href = "/api/hello", .class = "btn btn-outline" }, "API Example"),
        }),
    });
}
