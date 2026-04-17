// kuri.zig — kuri browser automation sidecar for debug mode.
// Spawns Chrome + kuri and proxies /_mer/kuri/* requests to kuri's HTTP API.

const std = @import("std");
const log = std.log.scoped(.kuri);
pub const default_port: u16 = 9222;

fn threadSleep(ns: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
}

pub const Kuri = struct {
    port: u16,
    app_port: u16,
    allocator: std.mem.Allocator,

    pub fn spawn(allocator: std.mem.Allocator, app_port: u16, kuri_port: u16) Kuri {
        // TODO: Re-enable Chrome + kuri spawning once process.Child API migrated for 0.16.
        log.warn("kuri disabled in 0.16 migration — debug browser automation unavailable", .{});
        return .{ .port = kuri_port, .app_port = app_port, .allocator = allocator };
    }

    pub fn deinit(self: *Kuri) void { _ = self; }
    pub fn isRunning(self: *const Kuri) bool { _ = self; return false; }

    pub fn proxyRequest(
        self: *const Kuri,
        alloc: std.mem.Allocator,
        std_req: *std.http.Server.Request,
        raw_target: []const u8,
    ) !void {
        _ = self; _ = alloc; _ = raw_target;
        const body = "{\"error\":\"kuri disabled during 0.16 migration\"}";
        const fixed = [_]std.http.Header{ .{ .name = "content-type", .value = "application/json" } };
        std_req.respond(body, .{ .status = .service_unavailable, .extra_headers = &fixed }) catch {};
    }
};
