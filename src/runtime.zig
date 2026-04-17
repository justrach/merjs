const std = @import("std");

/// Single source of truth for the Io instance.
///
/// All code that needs an Io (for fs, net, sync, random) uses runtime.io.
/// This lets us flip between Threaded (today) and Evented (tomorrow for io_uring)
/// without touching call sites.
///
/// Initialize once in main(): runtime.init(gpa);
/// Clean up on exit: defer runtime.deinit();
pub var threaded: std.Io.Threaded = undefined;
pub var io: std.Io = undefined;

pub fn init(gpa: std.mem.Allocator) void {
    threaded = std.Io.Threaded.init(gpa, .{});
    io = threaded.io();
}

pub fn deinit() void {
    threaded.deinit();
}
