// main.zig — entry point for the `native` build target.
//
// Built via `zig build native` (dev) or `zig build native-build` (prod).
// The build wires these imports:
//   - `mer`       → framework (Server, Router, Config, native shell)
//   - `routes`    → src/generated/routes.zig (the app's routes)
//   - `manifest`  → the project's mer.app.zon
//
// Usage:
//   zig build native -- --dev      (dev: hot reload, devtools)
//   zig build native -- --no-dev   (embedded: no hot reload)

const std = @import("std");
const mer = @import("mer");
const runtime = @import("runtime");
const native = mer.native;

const log = std.log.scoped(.native);

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    // Resolve the manifest comptime from the imported .zon.
    var app_manifest = native.Manifest.fromZon(@import("manifest"));

    // CLI overrides (mirrors src/main.zig flags).
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dev")) {
            app_manifest.dev = true;
            app_manifest.server_mode = "dev";
        } else if (std.mem.eql(u8, args[i], "--no-dev")) {
            app_manifest.dev = false;
            app_manifest.server_mode = "embedded";
        } else if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
            app_manifest.host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            app_manifest.port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        }
    }

    // Build the router from generated routes (same as src/main.zig).
    var router = mer.Router.fromGenerated(allocator, @import("routes"));
    defer router.deinit();

    log.info("mer native — {s} v{s} ({s})", .{ app_manifest.display_name, app_manifest.version, app_manifest.server_mode });
    try native.Shell.run(allocator, app_manifest, &router, .{});
}
