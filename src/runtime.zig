const std = @import("std");
const builtin = @import("builtin");

/// Runtime Io instance with platform-conditional backend.
///
/// - Linux: Uses Evented (io_uring) for best performance
/// - macOS/BSD: Uses Threaded (blocking syscalls) - Evented has a stdlib bug in 0.16
/// - Other: Uses Threaded as safe fallback
pub var threaded: std.Io.Threaded = undefined;
pub var io: std.Io = undefined;

// Evented is only defined on platforms where it's supported
const use_evented = blk: {
    if (!@hasDecl(std.Io, "Evented")) break :blk false;
    if (std.Io.Evented == void) break :blk false;
    // Only use Evented on Linux where Uring (io_uring) is available
    // macOS Dispatch has a bug in deinit() (Dispatch.zig:584)
    break :blk builtin.os.tag == .linux;
};

// Evented storage only exists when supported
var evented: if (use_evented) std.Io.Evented else void = undefined;

pub fn init(gpa: std.mem.Allocator) !void {
    if (use_evented) {
        // Linux: Use Evented (io_uring)
        evented = undefined;
        try std.Io.Evented.init(&evented, gpa, .{});
        io = evented.io();
    } else {
        // macOS/Other: Use Threaded (Evented has bugs or isn't available)
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

/// Returns true if using Evented backend (io_uring)
pub fn isEvented() bool {
    return use_evented;
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
