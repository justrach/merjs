//! Minimal native desktop primitives.
//!
//! The first supported host is macOS. It presents a merjs loopback server in
//! the system WKWebView; server startup and shutdown remain owned by the app.
//!
//! Stacked from pranavp311 #107. Validation tests run on every platform.
//! The WKWebView host is compiled only on macOS.

const builtin = @import("builtin");
const std = @import("std");

pub const WindowConfig = struct {
    title: []const u8 = "merjs",
    width: u32 = 1024,
    height: u32 = 720,
};

pub const Error = error{
    UnsupportedPlatform,
    InvalidPort,
    InvalidTitle,
    InvalidWindowSize,
    WrongThread,
    NativeRuntimeUnavailable,
};

fn validate(port: u16, config: WindowConfig) Error!void {
    if (port == 0) return error.InvalidPort;
    if (config.title.len == 0 or config.title.len > 255 or
        std.mem.indexOfScalar(u8, config.title, 0) != null or
        !std.unicode.utf8ValidateSlice(config.title))
    {
        return error.InvalidTitle;
    }
    if (config.width < 320 or config.width > 8192 or
        config.height < 240 or config.height > 8192)
    {
        return error.InvalidWindowSize;
    }
}

/// Run the platform event loop and show a native window for a loopback server.
/// Must be called from the process main thread. Returns after the user
/// terminates the app or closes its last window.
pub fn runLoopback(port: u16, config: WindowConfig) Error!void {
    try validate(port, config);
    if (comptime builtin.os.tag != .macos) return error.UnsupportedPlatform;
    return @import("native/macos.zig").run(port, config);
}

test "native window configuration rejects unsafe values" {
    try std.testing.expectError(error.InvalidPort, validate(0, .{}));
    try std.testing.expectError(error.InvalidTitle, validate(3000, .{ .title = "" }));
    try std.testing.expectError(error.InvalidTitle, validate(3000, .{ .title = "bad\x00title" }));
    try std.testing.expectError(error.InvalidTitle, validate(3000, .{ .title = &.{0xff} }));
    try std.testing.expectError(error.InvalidWindowSize, validate(3000, .{ .width = 100 }));
    try validate(3000, .{});
}

test "runLoopback rejects unsupported platforms at runtime on non-macOS" {
    if (builtin.os.tag == .macos) return;
    try std.testing.expectError(error.UnsupportedPlatform, runLoopback(3000, .{}));
}
