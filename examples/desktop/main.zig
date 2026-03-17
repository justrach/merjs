/// merjs Desktop — native macOS app wrapper
///
/// Architecture (#53):
///   main thread  →  NSApp.run() (AppKit requires main thread)
///   bg thread    →  merjs HTTP server on port 0 (OS assigns free port)
///   sync         →  std.Thread.ResetEvent (server signals ready → main loads URL)
const std = @import("std");
const mer = @import("mer");
const merjs_internal = @import("merjs_internal");
const server_mod = merjs_internal.server;
const ssr = merjs_internal.ssr;

// ObjC runtime — no @cImport needed (proven in spike #50)
extern fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern fn objc_msgSend() void;

// Types
const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const CGFloat = f64;
const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };
const NSUInteger = c_ulong;
const NSInteger = c_long;
const BOOL = i8;

// AppKit constants
const NSWindowStyleMaskTitled: NSUInteger = 1;
const NSWindowStyleMaskClosable: NSUInteger = 2;
const NSWindowStyleMaskMiniaturizable: NSUInteger = 4;
const NSWindowStyleMaskResizable: NSUInteger = 8;
const NSBackingStoreBuffered: NSUInteger = 2;
const NSApplicationActivationPolicyRegular: NSInteger = 0;
const YES: BOOL = 1;
const NO: BOOL = 0;

fn cls(name: [*:0]const u8) Id {
    return objc_getClass(name);
}
fn sel(name: [*:0]const u8) Sel {
    return sel_registerName(name);
}

fn send(recv: Id, s: Sel) Id {
    const F = *const fn (Id, Sel) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s);
}
fn sendv(recv: Id, s: Sel) void {
    const F = *const fn (Id, Sel) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s);
}
fn send1(recv: Id, s: Sel, a: Id) Id {
    const F = *const fn (Id, Sel, Id) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn send1v(recv: Id, s: Sel, a: Id) void {
    const F = *const fn (Id, Sel, Id) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn sendStr(recv: Id, s: Sel, str: [*:0]const u8) Id {
    const F = *const fn (Id, Sel, [*:0]const u8) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, str);
}
fn sendIntv(recv: Id, s: Sel, a: NSInteger) void {
    const F = *const fn (Id, Sel, NSInteger) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn sendBoolv(recv: Id, s: Sel, a: BOOL) void {
    const F = *const fn (Id, Sel, BOOL) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn sendWindowInit(recv: Id, s: Sel, rect: CGRect, style: NSUInteger, backing: NSUInteger, defer_: BOOL) Id {
    const F = *const fn (Id, Sel, CGRect, NSUInteger, NSUInteger, BOOL) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, rect, style, backing, defer_);
}
fn sendWebViewInit(recv: Id, s: Sel, frame: CGRect, config: Id) Id {
    const F = *const fn (Id, Sel, CGRect, Id) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, frame, config);
}

// Server thread context
const ServerCtx = struct {
    ready: server_mod.ServerReady = .{},
    allocator: std.mem.Allocator,
};

fn runServer(ctx: *ServerCtx) void {
    var router = ssr.buildRouter(ctx.allocator);
    defer router.deinit();
    var srv = server_mod.Server.init(ctx.allocator, .{
        .host = "127.0.0.1",
        .port = 0, // OS assigns a free port
        .dev = false,
        .ready = &ctx.ready,
    }, &router, null);
    srv.listen() catch |err| {
        std.log.err("server listen failed: {}", .{err});
        ctx.ready.event.set(); // unblock main thread even on failure
    };
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Allocate server context on heap so the thread can outlive this stack frame
    const ctx = try allocator.create(ServerCtx);
    ctx.* = .{ .allocator = allocator };

    // Spawn HTTP server on background thread (#53)
    const thread = try std.Thread.spawn(.{}, runServer, .{ctx});
    thread.detach();

    // Block until server is bound and ready (#51)
    ctx.ready.event.wait();
    const port = ctx.ready.port;
    if (port == 0) return error.ServerFailed;
    std.log.info("merjs server ready on port {d}", .{port});

    // Build the URL string
    var url_buf: [64]u8 = undefined;
    const url_str = try std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}/", .{port});

    // ── AppKit setup (must run on main thread) (#52) ──────────────────────
    const app = send(cls("NSApplication"), sel("sharedApplication"));
    sendIntv(app, sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);

    const frame = CGRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 1280, .height = 820 },
    };
    const style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    const window = sendWindowInit(
        send(cls("NSWindow"), sel("alloc")),
        sel("initWithContentRect:styleMask:backing:defer:"),
        frame,
        style,
        NSBackingStoreBuffered,
        NO,
    );
    const title = sendStr(cls("NSString"), sel("stringWithUTF8String:"), "merjs");
    send1v(window, sel("setTitle:"), title);

    // WKWebView
    const wkconfig = send(
        send(cls("WKWebViewConfiguration"), sel("alloc")),
        sel("init"),
    );
    const webview = sendWebViewInit(
        send(cls("WKWebView"), sel("alloc")),
        sel("initWithFrame:configuration:"),
        frame,
        wkconfig,
    );
    send1v(window, sel("setContentView:"), webview);

    // Load the merjs server URL
    const ns_url_str = sendStr(cls("NSString"), sel("stringWithUTF8String:"), url_str.ptr);
    const url = send1(cls("NSURL"), sel("URLWithString:"), ns_url_str);
    const request = send1(cls("NSURLRequest"), sel("requestWithURL:"), url);
    _ = send1(webview, sel("loadRequest:"), request);

    // Show window and run event loop
    send1v(window, sel("makeKeyAndOrderFront:"), null);
    sendBoolv(app, sel("activateIgnoringOtherApps:"), YES);
    sendv(app, sel("run")); // blocks until window is closed
}
