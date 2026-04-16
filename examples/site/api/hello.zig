const mer = @import("mer");

/// Type-safe response — serialized via std.json.stringify, no hand-rolled JSON.
const HelloResponse = struct {
    message: []const u8,
    framework: []const u8,
    node_modules: u32,
    zig_version: []const u8,
};

pub fn render(req: mer.Request) mer.Response {
    return mer.typedJson(req.allocator, HelloResponse{
        .message = "hello from merjs",
        .framework = "zig",
        .node_modules = 0,
        .zig_version = "0.15",
    });
}
