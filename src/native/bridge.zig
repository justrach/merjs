// bridge.zig — `window.mer.invoke` JS↔Zig bridge dispatch.
//
// Client side (injected JS shim, see macos.zig):
//   const path = await window.mer.invoke("dialog.openFile", { filters: ["*.md"] });
//
// The shim postMessages a JSON envelope to a WKScriptMessageHandler named
// "merInvoke". The ObjC IMP (macos.zig) pulls the body string and calls
// dispatch() here, which:
//   1. size limit  — reject payloads > max_payload_bytes
//   2. parse       — { cmd, args, id }
//   3. permission  — command.permission ∈ manifest.permissions (deny-default)
//   4. dispatch    — command name → handler via comptime registry
//                    (same shape as Router.exact_map in src/dispatch.zig)
//   5. resolve     — returns a `window.mer._resolve(<id>, ok, <json>)` JS
//                    string the IMP evaluates on the webview
//
// Origin note: the native shell only ever loads http://127.0.0.1:<port>, so the
// origin is trusted loopback by construction. Dynamic origin extraction from
// the WKScriptMessage frame is a future hardening step; for v0.2.6 the size +
// permission guards are the security boundary.

const std = @import("std");

/// Maximum inbound bridge payload size (keeps the ObjC string bridge bounded).
pub const max_payload_bytes: usize = 64 * 1024;

/// Bridge call context handed to registered handlers.
pub const Ctx = struct {
    allocator: std.mem.Allocator,
    permissions: []const []const u8,
};

/// A JSON value returned by a bridge handler (an owned string of JSON).
pub const Json = []const u8;

/// Error set for bridge dispatch.
pub const BridgeError = error{
    UnknownCommand,
    PermissionDenied,
    OriginNotAllowed,
    PayloadTooLarge,
    ParseError,
    HandlerError,
    OutOfMemory,
};

/// Result of a handler invocation.
pub const HandlerResult = union(enum) {
    ok: Json,
    err: BridgeError,
};

/// A handler takes the parsed `args` value and returns a JSON result or error.
pub const HandlerFn = *const fn (ctx: *Ctx, args: std.json.Value) HandlerResult;

/// A registered command: name, required permission, handler.
pub const Command = struct {
    name: []const u8,
    permission: []const u8,
    handler: HandlerFn,
};

/// The comptime command registry. Add commands here; matched by name in
/// dispatch(). Mirrors the static route table in src/dispatch.zig.
pub const registry = [_]Command{
    .{ .name = "mer.ping", .permission = "", .handler = ping },
    .{ .name = "mer.echo", .permission = "", .handler = echo },
    .{ .name = "dialog.openFile", .permission = "dialog", .handler = dialogOpenFile },
    .{ .name = "clipboard.write", .permission = "clipboard", .handler = clipboardWrite },
};

fn ping(_: *Ctx, _: std.json.Value) HandlerResult {
    return .{ .ok = "{\"pong\":true}" };
}

fn echo(_: *Ctx, _: std.json.Value) HandlerResult {
    // v0.2.6: static ack. Dynamic arg reflection (re-stringify args) needs a
    // JSON writer; the round-trip itself is proven by mer.ping.
    return .{ .ok = "{\"echo\":true}" };
}

fn dialogOpenFile(_: *Ctx, _: std.json.Value) HandlerResult {
    // NSOpenPanel wiring lands post-v0.2.6; surface a clear error.
    return .{ .err = error.HandlerError };
}

fn clipboardWrite(_: *Ctx, _: std.json.Value) HandlerResult {
    return .{ .err = error.HandlerError };
}

/// True if `perm` is granted by the manifest's permissions list. Empty perm
/// means the command is always allowed (e.g. mer.ping).
pub fn hasPermission(ctx: *Ctx, perm: []const u8) bool {
    if (perm.len == 0) return true;
    for (ctx.permissions) |p| {
        if (std.mem.eql(u8, p, perm)) return true;
    }
    return false;
}

const Envelope = struct {
    cmd: []const u8,
    args: std.json.Value = .null,
    id: i64 = 0,
};

/// Dispatch an inbound payload. Returns an owned JS string of the form
/// `window.mer._resolve(<id>,<ok>,<json>);` for the IMP to evaluate.
pub fn dispatch(ctx: *Ctx, payload: []const u8) BridgeError![]u8 {
    const alloc = ctx.allocator;

    if (payload.len > max_payload_bytes) {
        return resolveStr(alloc, 0, false, "\"PayloadTooLarge\"");
    }

    var parsed = std.json.parseFromSlice(Envelope, alloc, payload, .{}) catch {
        return resolveStr(alloc, 0, false, "\"ParseError\"");
    };
    defer parsed.deinit();
    const env = parsed.value;

    for (registry) |cmd| {
        if (std.mem.eql(u8, cmd.name, env.cmd)) {
            if (!hasPermission(ctx, cmd.permission)) {
                return resolveStr(alloc, env.id, false, "\"PermissionDenied\"");
            }
            const res = cmd.handler(ctx, env.args);
            switch (res) {
                .ok => |json| return resolveStr(alloc, env.id, true, json),
                .err => |e| return resolveStr(alloc, env.id, false, try quoteStr(alloc, @errorName(e))),
            }
        }
    }
    return resolveStr(alloc, env.id, false, try quoteStr(alloc, "UnknownCommand"));
}

/// Wrap a bare string as a JSON string literal (for error names).
fn quoteStr(alloc: std.mem.Allocator, s: []const u8) BridgeError![]const u8 {
    return std.fmt.allocPrint(alloc, "\"{s}\"", .{s}) catch error.OutOfMemory;
}

/// Format `window.mer._resolve(<id>,<ok>,<json>);` into an owned string.
fn resolveStr(alloc: std.mem.Allocator, id: i64, ok: bool, json: []const u8) BridgeError![]u8 {
    return std.fmt.allocPrint(alloc, "window.mer._resolve({d},{s},{s});", .{ id, if (ok) "true" else "false", json }) catch error.OutOfMemory;
}

// ── tests (standalone: bridge.zig only imports std) ─────────────────────────
const testing = std.testing;

fn newCtx(alloc: std.mem.Allocator, perms: []const []const u8) Ctx {
    return .{ .allocator = alloc, .permissions = perms };
}

test "dispatch: mer.ping resolves ok" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const js = try dispatch(&ctx, "{\"cmd\":\"mer.ping\",\"args\":null,\"id\":7}");
    try testing.expectEqualStrings("window.mer._resolve(7,true,{\"pong\":true});", js);
}

test "dispatch: unknown command denies by default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const js = try dispatch(&ctx, "{\"cmd\":\"nope\",\"args\":null,\"id\":1}");
    try testing.expectEqualStrings("window.mer._resolve(1,false,\"UnknownCommand\");", js);
}

test "dispatch: permission gate blocks unpermitted command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // manifest grants only "window"; dialog.openFile needs "dialog"
    var ctx = newCtx(alloc, &.{"window"});
    const js = try dispatch(&ctx, "{\"cmd\":\"dialog.openFile\",\"args\":{},\"id\":3}");
    try testing.expectEqualStrings("window.mer._resolve(3,false,\"PermissionDenied\");", js);
}

test "dispatch: permission gate allows permitted command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{ "window", "dialog" });
    const js = try dispatch(&ctx, "{\"cmd\":\"dialog.openFile\",\"args\":{},\"id\":3}");
    // dialog.openFile handler returns HandlerError
    try testing.expectEqualStrings("window.mer._resolve(3,false,\"HandlerError\");", js);
}

test "dispatch: oversized payload rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const big = try alloc.alloc(u8, max_payload_bytes + 1);
    @memset(big, 'x');
    const js = try dispatch(&ctx, big);
    try testing.expectEqualStrings("window.mer._resolve(0,false,\"PayloadTooLarge\");", js);
}

test "dispatch: malformed json yields ParseError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = newCtx(alloc, &.{});
    const js = try dispatch(&ctx, "not json");
    try testing.expectEqualStrings("window.mer._resolve(0,false,\"ParseError\");", js);
}

test "hasPermission: empty perm always allowed" {
    var ctx = newCtx(testing.allocator, &.{});
    try testing.expect(hasPermission(&ctx, ""));
}
