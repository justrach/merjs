const mer = @import("mer");

pub const meta: mer.Meta = .{ .title = "Consumer Home" };

pub fn render(_: mer.Request) mer.Response {
    return mer.html("<h1>Consumer Home</h1>");
}
