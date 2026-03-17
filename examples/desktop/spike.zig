/// #50 Research Spike — Zig 0.15 -> Objective-C bridge for AppKit + WebKit
///
/// QUESTION: @cImport or extern fn declarations?
///
/// FINDING:
///   @cImport(@cInclude("AppKit/AppKit.h")) does NOT work — ObjC-specific syntax
///   (@interface, @protocol) breaks translate-c.
///   @cImport(@cInclude("objc/runtime.h")) works but gives messy types + variadic
///   objc_msgSend that can't be called directly.
///
///   WINNING PATTERN: skip @cImport entirely. Declare the three ObjC runtime
///   primitives as `extern fn`. Cast objc_msgSend per call site. Define all
///   AppKit/WebKit constants as Zig consts. Zero headers required.
///
/// COMPILE-TIME:  extern fn declarations compile without errors.
/// LINK-TIME:     requires -framework AppKit -framework WebKit -framework Foundation + lc
/// RUNTIME:       objc_getClass("WKWebView") non-null once WebKit linked.
///                CGRect passes correctly on arm64 (no objc_msgSend_stret needed).
///
/// DOWNSTREAM contracts:
///   #55 frameworks: AppKit, WebKit, Foundation + libc
///   #52 wrapper shape: see send* helpers below
///   #53 threading: NSApp.run() MUST be main thread; HTTP server on std.Thread
const std = @import("std");

// ObjC runtime — extern, no @cImport needed
extern fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern fn objc_msgSend() void; // variadic; cast per call-site

// Types — defined manually, no AppKit.h
const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const CGFloat = f64;
const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };
const NSUInteger = c_ulong;
const NSInteger = c_long;
const BOOL = i8; // signed char; YES=1 NO=0

// AppKit constants — no @cImport of AppKit.h needed
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

// Typed objc_msgSend casts — one per distinct signature
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

pub fn main() void {
    std.debug.print("=== merjs desktop spike — Zig 0.15 ObjC bridge ===\n", .{});

    // [1/4] NSApplication
    const app = send(cls("NSApplication"), sel("sharedApplication"));
    if (app == null) @panic("NSApplication.sharedApplication returned nil");
    sendIntv(app, sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);
    std.debug.print("[1/4] NSApplication sharedApplication  OK\n", .{});

    // [2/4] NSWindow
    const frame = CGRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 1200, .height = 800 },
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
    if (window == null) @panic("NSWindow init returned nil");
    const title_str = sendStr(cls("NSString"), sel("stringWithUTF8String:"), "merjs Desktop");
    send1v(window, sel("setTitle:"), title_str);
    std.debug.print("[2/4] NSWindow initWithContentRect      OK\n", .{});

    // [3/4] WKWebView
    if (cls("WKWebView") == null) @panic("WKWebView class not found — check -framework WebKit");
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
    if (webview == null) @panic("WKWebView init returned nil");
    send1v(window, sel("setContentView:"), webview);
    std.debug.print("[3/4] WKWebView initWithFrame           OK\n", .{});

    // [4/4] Load URL (data URI — spike is self-contained, no server needed)
    const url_str = sendStr(
        cls("NSString"),
        sel("stringWithUTF8String:"),
        "data:text/html,<h1 style='font-family:system-ui;padding:40px'>merjs desktop spike works!</h1>",
    );
    const url = send1(cls("NSURL"), sel("URLWithString:"), url_str);
    const request = send1(cls("NSURLRequest"), sel("requestWithURL:"), url);
    _ = send1(webview, sel("loadRequest:"), request);
    std.debug.print("[4/4] WKWebView loadRequest             OK\n", .{});

    // Show window + run loop
    send1v(window, sel("makeKeyAndOrderFront:"), null);
    sendBoolv(app, sel("activateIgnoringOtherApps:"), YES);
    std.debug.print("Running NSApp event loop — close the window to quit.\n", .{});
    sendv(app, sel("run"));
}
