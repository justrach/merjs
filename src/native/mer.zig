// mer.zig — `mer.native` module root.
//
// Re-exports the native shell surface so consumer code does:
//   const native = @import("mer").native;
//   try native.Shell.run(allocator, manifest, &router);

pub const Shell = @import("shell.zig");
pub const Manifest = @import("manifest.zig");
pub const macos = @import("macos.zig");
pub const bridge = @import("bridge.zig");
pub const commands = @import("commands.zig");
pub const update = @import("update.zig");
