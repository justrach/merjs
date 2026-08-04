//! macOS WKWebView host using the Objective-C runtime directly.
//! AppKit headers are intentionally not translated: their Objective-C syntax
//! is not accepted by Zig's C importer.

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const BOOL = i8;
const CGFloat = f64;
const NSInteger = c_long;
const NSUInteger = c_ulong;
const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };

extern fn objc_getClass(name: [*:0]const u8) Id;
extern fn sel_registerName(name: [*:0]const u8) Sel;
extern fn objc_msgSend() void;
extern fn objc_allocateClassPair(superclass: Id, name: [*:0]const u8, extra_bytes: usize) Id;
extern fn class_addMethod(cls: Id, name: Sel, imp: *const anyopaque, types: [*:0]const u8) BOOL;
extern fn objc_registerClassPair(cls: Id) void;

const NSWindowStyleMaskTitled: NSUInteger = 1;
const NSWindowStyleMaskClosable: NSUInteger = 2;
const NSWindowStyleMaskMiniaturizable: NSUInteger = 4;
const NSWindowStyleMaskResizable: NSUInteger = 8;
const NSBackingStoreBuffered: NSUInteger = 2;
const NSApplicationActivationPolicyRegular: NSInteger = 0;
const YES: BOOL = 1;
const NO: BOOL = 0;

var app_delegate: Id = null;

fn cls(name: [*:0]const u8) Id {
    return objc_getClass(name);
}

fn sel(name: [*:0]const u8) Sel {
    return sel_registerName(name);
}

fn send(recv: Id, selector: Sel) Id {
    const F = *const fn (Id, Sel) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, selector);
}

fn sendVoid(recv: Id, selector: Sel) void {
    const F = *const fn (Id, Sel) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, selector);
}

fn sendOne(recv: Id, selector: Sel, arg: Id) Id {
    const F = *const fn (Id, Sel, Id) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, selector, arg);
}

fn sendOneVoid(recv: Id, selector: Sel, arg: Id) void {
    const F = *const fn (Id, Sel, Id) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, selector, arg);
}

fn sendIntegerVoid(recv: Id, selector: Sel, value: NSInteger) void {
    const F = *const fn (Id, Sel, NSInteger) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, selector, value);
}

fn sendBoolVoid(recv: Id, selector: Sel, value: BOOL) void {
    const F = *const fn (Id, Sel, BOOL) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, selector, value);
}

fn initWindow(recv: Id, selector: Sel, frame: CGRect, style: NSUInteger) Id {
    const F = *const fn (Id, Sel, CGRect, NSUInteger, NSUInteger, BOOL) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(
        recv,
        selector,
        frame,
        style,
        NSBackingStoreBuffered,
        NO,
    );
}

fn initWebView(recv: Id, selector: Sel, frame: CGRect, config: Id) Id {
    const F = *const fn (Id, Sel, CGRect, Id) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, selector, frame, config);
}

fn shouldTerminateAfterLastWindow(_: Id, _: Sel, _: Id) callconv(.c) BOOL {
    return YES;
}

fn createAppDelegate() Id {
    const class = cls("MerNativeAppDelegate") orelse blk: {
        const superclass = cls("NSObject") orelse return null;
        const new_class = objc_allocateClassPair(superclass, "MerNativeAppDelegate", 0) orelse return null;
        if (class_addMethod(
            new_class,
            sel("applicationShouldTerminateAfterLastWindowClosed:"),
            @ptrCast(&shouldTerminateAfterLastWindow),
            "c@:@",
        ) == NO) return null;
        objc_registerClassPair(new_class);
        break :blk new_class;
    };
    return send(send(class, sel("alloc")), sel("init"));
}

pub fn run(port: u16, config: anytype) error{NativeRuntimeUnavailable}!void {
    const pool_class = cls("NSAutoreleasePool") orelse return error.NativeRuntimeUnavailable;
    const pool = send(send(pool_class, sel("alloc")), sel("init")) orelse
        return error.NativeRuntimeUnavailable;
    defer sendVoid(pool, sel("drain"));

    const app_class = cls("NSApplication") orelse return error.NativeRuntimeUnavailable;
    const app = send(app_class, sel("sharedApplication")) orelse
        return error.NativeRuntimeUnavailable;
    sendIntegerVoid(app, sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);

    app_delegate = createAppDelegate() orelse return error.NativeRuntimeUnavailable;
    sendOneVoid(app, sel("setDelegate:"), app_delegate);

    const frame = CGRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{
            .width = @floatFromInt(config.width),
            .height = @floatFromInt(config.height),
        },
    };
    const style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    const window_class = cls("NSWindow") orelse return error.NativeRuntimeUnavailable;
    const window = initWindow(
        send(window_class, sel("alloc")),
        sel("initWithContentRect:styleMask:backing:defer:"),
        frame,
        style,
    ) orelse return error.NativeRuntimeUnavailable;

    var title_buffer: [256]u8 = undefined;
    @memcpy(title_buffer[0..config.title.len], config.title);
    title_buffer[config.title.len] = 0;
    const string_class = cls("NSString") orelse return error.NativeRuntimeUnavailable;
    const title = sendOne(string_class, sel("stringWithUTF8String:"), @ptrCast(&title_buffer)) orelse
        return error.NativeRuntimeUnavailable;
    sendOneVoid(window, sel("setTitle:"), title);

    const webview_class = cls("WKWebView") orelse return error.NativeRuntimeUnavailable;
    const webview_config_class = cls("WKWebViewConfiguration") orelse
        return error.NativeRuntimeUnavailable;
    const webview_config = send(send(webview_config_class, sel("alloc")), sel("init")) orelse
        return error.NativeRuntimeUnavailable;
    const webview = initWebView(
        send(webview_class, sel("alloc")),
        sel("initWithFrame:configuration:"),
        frame,
        webview_config,
    ) orelse return error.NativeRuntimeUnavailable;
    sendOneVoid(window, sel("setContentView:"), webview);

    var url_buffer: [64]u8 = undefined;
    const std = @import("std");
    const url = std.fmt.bufPrintZ(&url_buffer, "http://127.0.0.1:{d}/", .{port}) catch
        return error.NativeRuntimeUnavailable;
    const url_class = cls("NSURL") orelse return error.NativeRuntimeUnavailable;
    const ns_url = sendOne(url_class, sel("URLWithString:"), @ptrCast(url.ptr)) orelse
        return error.NativeRuntimeUnavailable;
    const request_class = cls("NSURLRequest") orelse return error.NativeRuntimeUnavailable;
    const request = sendOne(request_class, sel("requestWithURL:"), ns_url) orelse
        return error.NativeRuntimeUnavailable;
    _ = sendOne(webview, sel("loadRequest:"), request);

    sendVoid(window, sel("center"));
    sendOneVoid(window, sel("makeKeyAndOrderFront:"), null);
    sendBoolVoid(app, sel("activateIgnoringOtherApps:"), YES);
    sendVoid(app, sel("run"));
}
