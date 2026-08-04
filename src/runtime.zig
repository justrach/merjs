const std = @import("std");

/// Runtime Io instance.
///
/// - All supported targets currently use Threaded (blocking syscalls).
/// - Zig 0.16's Evented/io_uring backend has stdlib error-set issues on Linux
///   and Dispatch deinit issues on macOS, so keep it disabled until upstream is fixed.
pub var threaded: std.Io.Threaded = undefined;
pub var io: std.Io = undefined;

// Compile Evented storage out for Zig 0.16 production builds until the stdlib
// backend issues above are fixed. Keep this as a comptime switch so re-enabling
// remains localized.
const use_evented = false;

// Evented storage only exists when supported
var evented: if (use_evented) std.Io.Evented else void = undefined;

pub fn init(gpa: std.mem.Allocator) !void {
    if (use_evented) {
        // Future: re-enable Evented/io_uring once Zig stdlib issues are fixed.
        evented = undefined;
        try std.Io.Evented.init(&evented, gpa, .{});
        io = evented.io();
    } else {
        // Zig 0.16: use Threaded on all supported targets.
        threaded = std.Io.Threaded.init(gpa, .{});
        io = threaded.io();
    }
}

pub fn deinit() void {
    if (use_evented) {
        evented.deinit();
    } else {
        threaded.deinit();
    }
}

/// Returns true if using Evented backend (io_uring).
pub fn isEvented() bool {
    return use_evented;
}

test "Zig 0.16 runtime uses threaded IO" {
    try std.testing.expect(!isEvented());
}

/// Log which backend is active at startup
pub fn logBackend() void {
    const log = std.log.scoped(.runtime);
    if (use_evented) {
        log.info("Using std.Io.Evented (io_uring)", .{});
    } else {
        log.info("Using std.Io.Threaded (blocking syscalls)", .{});
    }
}
