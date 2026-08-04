/// merjs Desktop — native macOS app wrapper.
///
/// AppKit owns the main thread. The merjs loopback server runs on a detached
/// background thread for the lifetime of the desktop process.
const std = @import("std");
const mer = @import("mer");
const runtime = @import("runtime");

const ServerCtx = struct {
    ready: mer.ServerReady = .{},
    allocator: std.mem.Allocator,
};

fn runServer(ctx: *ServerCtx) void {
    var router = mer.Router.fromGenerated(ctx.allocator, @import("routes"));
    defer router.deinit();
    var server = mer.Server.init(ctx.allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .dev = false,
        .ready = &ctx.ready,
    }, &router, null);
    server.listen() catch |err| {
        std.log.err("server listen failed: {}", .{err});
        ctx.ready.set();
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    try runtime.init(allocator);

    const ctx = try allocator.create(ServerCtx);
    ctx.* = .{ .allocator = allocator };
    const server_thread = try std.Thread.spawn(.{}, runServer, .{ctx});
    server_thread.detach();

    ctx.ready.wait();
    if (ctx.ready.port == 0) return error.ServerFailed;
    std.log.info("merjs server ready on port {d}", .{ctx.ready.port});

    try mer.native.runLoopback(ctx.ready.port, .{
        .title = "merjs",
        .width = 1024,
        .height = 720,
    });

    // Server.listen currently has process-lifetime semantics. Exit without
    // unwinding allocator state still owned by its detached thread.
    std.process.exit(0);
}
