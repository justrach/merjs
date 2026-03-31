const mer = @import("mer");

pub const meta: mer.Meta = .{ .title = "Standalone Home" };

pub fn render(_: mer.Request) mer.Response {
    return mer.html("<h1>Standalone Home</h1>");
}
