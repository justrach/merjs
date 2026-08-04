// commands.zig — bridge command type re-exports.
//
// Built-in handlers live in bridge.zig's static `registry` and are invoked via
// bridge.dispatch(). Each command is permission-gated by the manifest's
// top-level `permissions` list. App-level custom command registries are not a
// public extension point yet; they are a follow-up API design item.

const bridge = @import("bridge.zig");

pub const Ctx = bridge.Ctx;
pub const HandlerFn = bridge.HandlerFn;
pub const HandlerResult = bridge.HandlerResult;
pub const Command = bridge.Command;
