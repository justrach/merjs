// Shim exposing internal src/ modules for the desktop build target.
// A single module root ensures shared files (router.zig etc.) belong to exactly one module.
pub const server = @import("server.zig");
pub const ssr = @import("ssr.zig");
