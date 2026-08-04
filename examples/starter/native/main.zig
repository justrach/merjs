// native/main.zig — native shell entry point (scaffolded by `mer add native`).
//
// Build/run:
//   mer native            # dev: hot reload + WebView
//   mer native build      # prod binary
//   mer package           # .app bundle
//
// The build wires `mer`, `routes`, and `manifest` (→ mer.app.zon) imports.
const std = @import("std");
const mer = @import("mer");
const native = mer.native;

const log = std.log.scoped(.native);

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    _ = try mer.loadDotenvStatus(allocator);
    defer mer.deinitDotenv();

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    var app_manifest = native.Manifest.fromZon(@import("manifest"));

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dev")) {
            app_manifest.dev = true;
            app_manifest.server_mode = "dev";
        } else if (std.mem.eql(u8, args[i], "--no-dev")) {
            app_manifest.dev = false;
            app_manifest.server_mode = "embedded";
        }
    }

    var router = mer.Router.fromGenerated(allocator, @import("routes"));
    defer router.deinit();

    log.info("mer native — {s} v{s} ({s})", .{ app_manifest.display_name, app_manifest.version, app_manifest.server_mode });
    try native.Shell.run(allocator, app_manifest, &router, .{});
}
