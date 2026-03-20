const std = @import("std");
const mer = @import("mer");

/// Type-safe response model.
const TimeResponse = struct {
    timestamp: i64,
    unit: []const u8,
    iso: []const u8,
};

pub fn render(req: mer.Request) mer.Response {
    const builtin = @import("builtin");
    const ts: i64 = if (builtin.target.cpu.arch != .wasm32)
        std.time.timestamp()
    else
        0; // WASM targets have no clock; return 0 as a placeholder.
    const iso = std.fmt.allocPrint(req.allocator, "unix+{d}s", .{ts}) catch "unknown";
    return mer.typedJson(req.allocator, TimeResponse{
        .timestamp = ts,
        .unit = "unix_seconds",
        .iso = iso,
    });
}
