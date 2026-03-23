const mer = @import("mer");

pub const meta: mer.Meta = .{ .title = "Dashboard" };

pub fn render(_: mer.Request) mer.Response {
    return mer.html("<h1>Dashboard</h1>");
}
