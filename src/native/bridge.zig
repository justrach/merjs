// bridge.zig — `window.mer.invoke` JS↔Zig bridge dispatch.
//
// Lands in P2: WKScriptMessageHandler glue + size/origin/permission guards +
// a comptime command registry shaped like src/dispatch.zig route tables.
//
// Contract (planned):
//   1. size limit  — reject payloads > 64 KB
//   2. origin check — caller origin ∈ command.origins (default 127.0.0.1 / mer://app)
//   3. permission   — ctx.hasPermission(command.permissions) ∧ manifest.permissions
//   4. dispatch     — command name → handler via comptime registry (Router.exact_map shape)
//   5. deny-default — unknown command → error.UnknownCommand

const std = @import("std");

/// Maximum inbound bridge payload size (keeps the ObjC string bridge bounded).
pub const max_payload_bytes: usize = 64 * 1024;

/// Bridge call context handed to registered handlers.
pub const Ctx = struct {
    allocator: std.mem.Allocator,
    permissions: []const []const u8,
};

/// A JSON value returned by a bridge handler.
pub const Json = []const u8;

/// Error set for bridge dispatch.
pub const BridgeError = error{
    UnknownCommand,
    PermissionDenied,
    OriginNotAllowed,
    PayloadTooLarge,
    OutOfMemory,
};

// P2: registry + dispatch land here. Until then this module is a no-op surface.
