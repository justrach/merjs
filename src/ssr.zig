// ssr.zig — SSR dispatch layer.
// Imports the generated routes table and builds a Router.

const std = @import("std");
const mer = @import("mer");
const Router = @import("router.zig").Router;
const generated = @import("generated/routes.zig");

pub fn buildRouter(allocator: std.mem.Allocator) Router {
    return Router.init(allocator, generated.routes);
}
