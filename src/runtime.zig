const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.runtime);

/// Runtime Io instance with platform-conditional backend.
///
/// Selection order:
///   1. Linux: try Evented (io_uring) — best performance.
///      Falls back to Threaded if io_uring is unavailable
///      (old kernel, restricted seccomp, sandboxed container, …).
///      This makes the same binary deployable on every Linux host
///      regardless of io_uring support.
///   2. macOS/BSD/Other: Threaded (blocking syscalls).
///      Evented on macOS has a stdlib bug in deinit() (Dispatch.zig:584).
///
/// Override with build option `-Druntime=threaded` to force Threaded
/// (useful for benchmarking, or when you know io_uring won't help).
pub const Backend = enum { evented, threaded };

pub var threaded: std.Io.Threaded = undefined;
pub var io: std.Io = undefined;
var active: Backend = .threaded;

// Evented is only available on platforms where the stdlib provides it.
const evented_supported = blk: {
    if (!@hasDecl(std.Io, "Evented")) break :blk false;
    if (std.Io.Evented == void) break :blk false;
    // Only attempt Evented on Linux (io_uring). Other Evented backends are
    // either unavailable or buggy in stdlib 0.16.
    break :blk builtin.os.tag == .linux;
};

// Storage for the Evented instance — only allocated on supported platforms.
var evented: if (evented_supported) std.Io.Evented else void = undefined;

pub fn init(gpa: std.mem.Allocator) !void {
    if (evented_supported) {
        evented = undefined;
        if (std.Io.Evented.init(&evented, gpa, .{})) {
            io = evented.io();
            active = .evented;
            return;
        } else |err| {
            // io_uring not available — fall back to Threaded so we still boot.
            // Common causes: old kernel, restricted seccomp profile, sandboxed
            // container runtime (Docker default seccomp profile, gVisor, etc.).
            log.warn("io_uring init failed ({s}); falling back to Threaded backend", .{@errorName(err)});
        }
    }
    threaded = std.Io.Threaded.init(gpa, .{});
    io = threaded.io();
    active = .threaded;
}

pub fn deinit() void {
    switch (active) {
        .evented => if (evented_supported) evented.deinit(),
        .threaded => threaded.deinit(),
    }
}

/// Returns true if the active backend is Evented (io_uring).
pub fn isEvented() bool {
    return active == .evented;
}

/// Returns the active backend.
pub fn backend() Backend {
    return active;
}

/// Log which backend is active at startup.
pub fn logBackend() void {
    switch (active) {
        .evented => log.info("io backend: Evented (io_uring)", .{}),
        .threaded => log.info("io backend: Threaded (blocking syscalls)", .{}),
    }
}
