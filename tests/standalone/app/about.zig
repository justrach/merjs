const mer = @import("mer");

pub const meta: mer.Meta = .{ .title = "Standalone About" };

pub fn render(_: mer.Request) mer.Response {
    return mer.html("<h1>About This App</h1>");
}
