// macos.zig — macOS WebView shell backend (WKWebView + NSWindow).
//
// ObjC interop pattern (proven in examples/desktop/spike.zig, #50):
//   - extern fn declarations for the ObjC runtime primitives
//   - typed `objc_msgSend` casts per call-site
//   - NO @cImport (AppKit.h / WebKit.h Objective-C syntax breaks translate-c)
//   - AppKit/WebKit/Foundation linked as frameworks in build.zig
//
// P2 adds the `window.mer.invoke` JS↔Zig bridge:
//   - a WKUserScript injecting the `window.mer` shim at document start
//   - a dynamically-allocated delegate class (MerInvokeHandler) conforming to
//     WKScriptMessageHandler, with an IMP that calls bridge.dispatch()
//   - the IMP evaluates the returned `window.mer._resolve(...)` JS on the webview

const std = @import("std");
const manifest = @import("manifest.zig");
const bridge = @import("bridge.zig");

// ── ObjC runtime primitives ─────────────────────────────────────────────────
extern fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern fn objc_msgSend() void; // variadic; cast per call-site
extern fn objc_allocateClassPair(superclass: Id, name: [*:0]const u8, extra_bytes: usize) Id;
extern fn class_addMethod(cls: Id, name: Sel, imp: *const anyopaque, types: [*:0]const u8) BOOL;
extern fn objc_registerClassPair(cls: Id) void;

// ── C types ─────────────────────────────────────────────────────────────────
const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const CGFloat = f64;
const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };
const NSUInteger = c_ulong;
const NSInteger = c_long;
const BOOL = i8;

// AppKit / WebKit constants
const NSWindowStyleMaskTitled: NSUInteger = 1;
const NSWindowStyleMaskClosable: NSUInteger = 2;
const NSWindowStyleMaskMiniaturizable: NSUInteger = 4;
const NSWindowStyleMaskResizable: NSUInteger = 8;
const NSBackingStoreBuffered: NSUInteger = 2;
const NSApplicationActivationPolicyRegular: NSInteger = 0;
const YES: BOOL = 1;
const NO: BOOL = 0;
const WKUserScriptInjectionTimeAtDocumentStart: NSUInteger = 0;
const NSUTF8StringEncoding: NSUInteger = 4;
const WKNavigationActionPolicyCancel: NSInteger = 0;
const WKNavigationActionPolicyAllow: NSInteger = 1;

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
fn send2v(recv: Id, s: Sel, a1: Id, a2: Id) void {
    const F = *const fn (Id, Sel, Id, Id) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a1, a2);
}
fn sendMenuItemInit(recv: Id, s: Sel, title: Id, action: Sel, key: Id) Id {
    const F = *const fn (Id, Sel, Id, Sel, Id) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, title, action, key);
}
fn sendStr(recv: Id, s: Sel, str: [*:0]const u8) Id {
    const F = *const fn (Id, Sel, [*:0]const u8) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, str);
}
fn sendPtr(recv: Id, s: Sel) [*:0]const u8 {
    const F = *const fn (Id, Sel) callconv(.c) [*:0]const u8;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s);
}
fn sendInt(recv: Id, s: Sel) NSInteger {
    const F = *const fn (Id, Sel) callconv(.c) NSInteger;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s);
}
fn sendIntv(recv: Id, s: Sel, a: NSInteger) void {
    const F = *const fn (Id, Sel, NSInteger) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn sendUnsigned1(recv: Id, s: Sel, a: NSUInteger) NSUInteger {
    const F = *const fn (Id, Sel, NSUInteger) callconv(.c) NSUInteger;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn sendBoolv(recv: Id, s: Sel, a: BOOL) void {
    const F = *const fn (Id, Sel, BOOL) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn send1Bool(recv: Id, s: Sel, a: Id) bool {
    const F = *const fn (Id, Sel, Id) callconv(.c) BOOL;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, a) != NO;
}
fn sendWindowInit(recv: Id, s: Sel, rect: CGRect, style: NSUInteger, backing: NSUInteger, defer_: BOOL) Id {
    const F = *const fn (Id, Sel, CGRect, NSUInteger, NSUInteger, BOOL) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, rect, style, backing, defer_);
}
fn sendWebViewInit(recv: Id, s: Sel, frame: CGRect, config: Id) Id {
    const F = *const fn (Id, Sel, CGRect, Id) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, frame, config);
}
fn sendUserScriptInit(recv: Id, s: Sel, source: Id, time: NSUInteger, main: BOOL) Id {
    const F = *const fn (Id, Sel, Id, NSUInteger, BOOL) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, source, time, main);
}

fn nsStringZ(value: [*:0]const u8) Id {
    return sendStr(cls("NSString"), sel("stringWithUTF8String:"), value);
}

fn menuItem(title: [*:0]const u8, action_name: ?[*:0]const u8, key: [*:0]const u8) Id {
    return sendMenuItemInit(
        send(cls("NSMenuItem"), sel("alloc")),
        sel("initWithTitle:action:keyEquivalent:"),
        nsStringZ(title),
        if (action_name) |name| sel(name) else null,
        nsStringZ(key),
    );
}

fn addMenuItem(menu: Id, title: [*:0]const u8, action_name: ?[*:0]const u8, key: [*:0]const u8) void {
    send1v(menu, sel("addItem:"), menuItem(title, action_name, key));
}

fn addSeparator(menu: Id) void {
    send1v(menu, sel("addItem:"), send(cls("NSMenuItem"), sel("separatorItem")));
}

fn installMainMenu(app: Id, app_title: [*:0]const u8) void {
    const main_menu = send(send(cls("NSMenu"), sel("alloc")), sel("init"));

    const app_menu_item = menuItem("", null, "");
    send1v(main_menu, sel("addItem:"), app_menu_item);
    const app_menu = send1(send(cls("NSMenu"), sel("alloc")), sel("initWithTitle:"), nsStringZ(app_title));
    addMenuItem(app_menu, "Quit", "terminate:", "q");
    send2v(main_menu, sel("setSubmenu:forItem:"), app_menu, app_menu_item);

    const file_menu_item = menuItem("File", null, "");
    send1v(main_menu, sel("addItem:"), file_menu_item);
    const file_menu = send1(send(cls("NSMenu"), sel("alloc")), sel("initWithTitle:"), nsStringZ("File"));
    addMenuItem(file_menu, "Close Window", "performClose:", "w");
    send2v(main_menu, sel("setSubmenu:forItem:"), file_menu, file_menu_item);

    const edit_menu_item = menuItem("Edit", null, "");
    send1v(main_menu, sel("addItem:"), edit_menu_item);
    const edit_menu = send1(send(cls("NSMenu"), sel("alloc")), sel("initWithTitle:"), nsStringZ("Edit"));
    addMenuItem(edit_menu, "Undo", "undo:", "z");
    addMenuItem(edit_menu, "Redo", "redo:", "Z");
    addSeparator(edit_menu);
    addMenuItem(edit_menu, "Cut", "cut:", "x");
    addMenuItem(edit_menu, "Copy", "copy:", "c");
    addMenuItem(edit_menu, "Paste", "paste:", "v");
    addMenuItem(edit_menu, "Select All", "selectAll:", "a");
    send2v(main_menu, sel("setSubmenu:forItem:"), edit_menu, edit_menu_item);

    send1v(app, sel("setMainMenu:"), main_menu);
}

// ── Bridge globals (single-window app) ──────────────────────────────────────
var g_webview: Id = null;
var g_bridge_ctx: ?*bridge.Ctx = null;
var g_app_delegate: Id = null;
var g_nav_delegate: Id = null;

/// The `window.mer` shim injected at document start. Provides:
///   window.mer.invoke(cmd, args) -> Promise
///   window.mer._resolve(response_token, id, ok, value)  (called from Zig via evaluateJavaScript)
///
/// The native shell supplies a per-process random bridge token. It is captured in
/// this private closure and echoed in every message envelope, so direct message
/// posts from foreign frames or ad-hoc WebKit messages fail token verification
/// before any command handler is considered.
fn makeMerShim(alloc: std.mem.Allocator, token: []const u8) ![:0]u8 {
    const shim = try std.fmt.allocPrint(
        alloc,
        "(function(){{" ++
            "if(window.mer)return;" ++
            "var cb={{}},idc=0,t='{s}';" ++
            "window.mer={{" ++
            "invoke:function(c,a){{return new Promise(function(r,j){{" ++
            "if(typeof c!=='string'){{j('InvalidCommand');return;}}" ++
            "var id=++idc;cb[id]={{r:r,j:j}};" ++
            "try{{var p=JSON.stringify({{cmd:c,args:(a===undefined?null:a),id:id,token:t}});var n=(typeof TextEncoder==='function')?new TextEncoder().encode(p).length:encodeURIComponent(p).replace(/%[0-9A-F]{{2}}/g,'x').length;if(n>65536){{delete cb[id];j('PayloadTooLarge');return;}}window.webkit.messageHandlers.merInvoke.postMessage(p);}}" ++
            "catch(e){{delete cb[id];j('BridgeUnavailable');}}" ++
            "}});}}," ++
            "_resolve:function(rt,id,ok,v){{if(rt!==t)return;var h=cb[id];if(!h)return;delete cb[id];if(ok)h.r(v);else h.j(v);}}" ++
            "}};" ++
            "Object.defineProperty(window,'mer',{{value:Object.freeze(window.mer),writable:false,configurable:false}});" ++
            "}})();",
        .{token},
    );
    defer alloc.free(shim);
    return try alloc.dupeZ(u8, shim);
}

/// IMP for `-[MerInvokeHandler userContentController:didReceiveScriptMessage:]`.
/// Pulls the message body (the posted JSON envelope), runs bridge.dispatch, and
/// evaluates the returned `window.mer._resolve(...)` JS on the webview.
fn merInvokeIMP(self: Id, _cmd: Sel, ucc: Id, message: Id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = ucc;
    const wv = g_webview orelse return;
    const ctx = g_bridge_ctx orelse return;

    const body = send(message, sel("body")) orelse return;
    if (!send1Bool(body, sel("isKindOfClass:"), cls("NSString"))) {
        const js = bridge.rejectFromPayload(ctx, "", "ParseError") catch return;
        defer ctx.allocator.free(js);
        evalJs(ctx, wv, js);
        return;
    }
    const byte_len = sendUnsigned1(body, sel("lengthOfBytesUsingEncoding:"), NSUTF8StringEncoding);
    const cstr = sendPtr(body, sel("UTF8String"));
    const payload = std.mem.span(cstr);
    if (byte_len > bridge.max_payload_bytes) {
        const js = bridge.rejectFromPayload(ctx, "", "PayloadTooLarge") catch return;
        defer ctx.allocator.free(js);
        evalJs(ctx, wv, js);
        return;
    }
    if (payload.len != byte_len) {
        // A directly-posted NSString can contain embedded NUL bytes. Do not let
        // UTF8String/std.mem.span truncate the message or resolve an attacker-
        // chosen id from the prefix; reject as an unknown caller instead.
        const js = bridge.rejectFromPayload(ctx, "", "ParseError") catch return;
        defer ctx.allocator.free(js);
        evalJs(ctx, wv, js);
        return;
    }

    var origin_buf: [512]u8 = undefined;
    const origin = messageFrameOrigin(message, &origin_buf) orelse {
        // The caller has not proven an allowed origin, so never resolve a
        // payload-selected id. Otherwise forged messages could reject unrelated
        // in-flight promises in the trusted renderer.
        const js = bridge.rejectFromPayload(ctx, "", "OriginNotAllowed") catch return;
        defer ctx.allocator.free(js);
        evalJs(ctx, wv, js);
        return;
    };
    if (!bridge.isOriginAllowed(ctx, origin)) {
        const js = bridge.rejectFromPayload(ctx, "", "OriginNotAllowed") catch return;
        defer ctx.allocator.free(js);
        evalJs(ctx, wv, js);
        return;
    }

    ctx.current_origin = origin;
    defer ctx.current_origin = null;
    const js = bridge.dispatch(ctx, payload) catch return;
    defer ctx.allocator.free(js);
    evalJs(ctx, wv, js);
}

fn evalJs(ctx: *bridge.Ctx, webview: Id, js: []const u8) void {
    const js_z = ctx.allocator.dupeZ(u8, js) catch return;
    defer ctx.allocator.free(js_z);
    const ns_js = sendStr(cls("NSString"), sel("stringWithUTF8String:"), js_z.ptr);
    send2v(webview, sel("evaluateJavaScript:completionHandler:"), ns_js, null);
}

const BlockLiteral = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (Id, NSInteger) callconv(.c) void,
};

fn callDecisionHandler(handler: Id, policy: NSInteger) void {
    const h = handler orelse return;
    const block: *const BlockLiteral = @ptrCast(@alignCast(h));
    block.invoke(h, policy);
}

fn navigationActionUrl(action: Id) ?[]const u8 {
    const request = send(action, sel("request")) orelse return null;
    const url = send(request, sel("URL")) orelse return null;
    const absolute = send(url, sel("absoluteString")) orelse return null;
    const cstr = sendPtr(absolute, sel("UTF8String"));
    return std.mem.span(cstr);
}

fn navigationPolicyIMP(self: Id, _cmd: Sel, webview: Id, action: Id, decision_handler: Id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = webview;
    const ctx = g_bridge_ctx orelse {
        callDecisionHandler(decision_handler, WKNavigationActionPolicyCancel);
        return;
    };
    const url = navigationActionUrl(action) orelse {
        callDecisionHandler(decision_handler, WKNavigationActionPolicyCancel);
        return;
    };
    if (bridge.isOriginAllowed(ctx, url)) {
        callDecisionHandler(decision_handler, WKNavigationActionPolicyAllow);
    } else {
        callDecisionHandler(decision_handler, WKNavigationActionPolicyCancel);
    }
}

fn formatSecurityOrigin(buf: []u8, proto: []const u8, host: []const u8, port: NSInteger) ![]const u8 {
    const is_ipv6 = std.mem.indexOfScalar(u8, host, ':') != null;
    const url_host = if (is_ipv6 and host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    if (port > 0) {
        return if (is_ipv6)
            try std.fmt.bufPrint(buf, "{s}://[{s}]:{d}", .{ proto, url_host, port })
        else
            try std.fmt.bufPrint(buf, "{s}://{s}:{d}", .{ proto, host, port });
    }
    return if (is_ipv6)
        try std.fmt.bufPrint(buf, "{s}://[{s}]", .{ proto, url_host })
    else
        try std.fmt.bufPrint(buf, "{s}://{s}", .{ proto, host });
}

fn messageFrameOrigin(message: Id, buf: *[512]u8) ?[]const u8 {
    const frame_info = send(message, sel("frameInfo")) orelse return null;
    const security_origin = send(frame_info, sel("securityOrigin")) orelse return null;
    const proto_obj = send(security_origin, sel("protocol")) orelse return null;
    const host_obj = send(security_origin, sel("host")) orelse return null;
    const proto = std.mem.span(sendPtr(proto_obj, sel("UTF8String")));
    const host = std.mem.span(sendPtr(host_obj, sel("UTF8String")));
    if (proto.len == 0 or host.len == 0) return null;
    return formatSecurityOrigin(buf, proto, host, sendInt(security_origin, sel("port"))) catch null;
}

/// Allocate the MerInvokeHandler delegate class (NSObject + one instance method).
/// Idempotent: returns the existing class if already registered.
fn createMerHandlerClass() Id {
    if (cls("MerInvokeHandler")) |existing| return existing;
    const nsobject = cls("NSObject") orelse return null;
    const new_class = objc_allocateClassPair(nsobject, "MerInvokeHandler", 0);
    if (new_class == null) return null;
    // void userContentController:(id)didReceiveScriptMessage:(id)  →  "v@:@@"
    _ = class_addMethod(
        new_class,
        sel("userContentController:didReceiveScriptMessage:"),
        @ptrCast(&merInvokeIMP),
        "v@:@@",
    );
    objc_registerClassPair(new_class);
    return new_class;
}

fn createNavigationDelegateClass() Id {
    if (cls("MerNavigationDelegate")) |existing| return existing;
    const nsobject = cls("NSObject") orelse return null;
    const new_class = objc_allocateClassPair(nsobject, "MerNavigationDelegate", 0);
    if (new_class == null) return null;
    // void webView:(id)webView decidePolicyForNavigationAction:(id)action decisionHandler:(id)handler
    _ = class_addMethod(
        new_class,
        sel("webView:decidePolicyForNavigationAction:decisionHandler:"),
        @ptrCast(&navigationPolicyIMP),
        "v@:@@@",
    );
    objc_registerClassPair(new_class);
    return new_class;
}

fn appShouldTerminateAfterLastWindowClosed(self: Id, _cmd: Sel, app: Id) callconv(.c) BOOL {
    _ = self;
    _ = _cmd;
    _ = app;
    return YES;
}

fn createAppDelegateClass() Id {
    if (cls("MerAppDelegate")) |existing| return existing;
    const nsobject = cls("NSObject") orelse return null;
    const new_class = objc_allocateClassPair(nsobject, "MerAppDelegate", 0);
    if (new_class == null) return null;
    _ = class_addMethod(
        new_class,
        sel("applicationShouldTerminateAfterLastWindowClosed:"),
        @ptrCast(&appShouldTerminateAfterLastWindowClosed),
        "c@:@",
    );
    objc_registerClassPair(new_class);
    return new_class;
}

/// Inject the `window.mer` shim and register the merInvoke message handler on
/// the webview's userContentController. Safe to call once per webview.
fn setupBridge(webview: Id, ctx: *bridge.Ctx) void {
    g_webview = webview;
    g_bridge_ctx = ctx;

    // Reach the webview's shared userContentController via its configuration.
    const config = send(webview, sel("configuration"));
    const ucc = send(config, sel("userContentController"));

    // Enforce the same origin policy at navigation time, not only when a page
    // calls the bridge. Install this before any bridge-token checks so even a
    // fail-closed bridge setup keeps navigation constrained.
    if (createNavigationDelegateClass()) |delegate_class| {
        g_nav_delegate = send(send(delegate_class, sel("alloc")), sel("init"));
        send1v(webview, sel("setNavigationDelegate:"), g_nav_delegate);
    }

    // 1. Inject the shim at document start. A missing/invalid token means the
    // bridge is not installed; native WebView bridges must fail closed rather
    // than silently falling back to unauthenticated envelopes.
    const bridge_token = ctx.bridge_token orelse return;
    if (!bridge.isValidBridgeToken(bridge_token)) return;
    const shim_z = makeMerShim(ctx.allocator, bridge_token) catch return;
    defer ctx.allocator.free(shim_z);
    const ns_shim = sendStr(cls("NSString"), sel("stringWithUTF8String:"), shim_z.ptr);
    const user_script = sendUserScriptInit(
        send(cls("WKUserScript"), sel("alloc")),
        sel("initWithSource:injectionTime:forMainFrameOnly:"),
        ns_shim,
        WKUserScriptInjectionTimeAtDocumentStart,
        YES,
    );
    send1v(ucc, sel("addUserScript:"), user_script);

    // 2. Register the message handler.
    const handler_class = createMerHandlerClass() orelse return;
    const handler = send(send(handler_class, sel("alloc")), sel("init"));
    var name_buf: [32]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "merInvoke", .{}) catch return;
    const ns_name = sendStr(cls("NSString"), sel("stringWithUTF8String:"), name_z.ptr);
    send2v(ucc, sel("addScriptMessageHandler:name:"), handler, ns_name);
}

/// Open a native window hosting a WKWebView pointed at `url_z`. Blocks on the
/// NSApp event loop until the window is closed.
///
/// `url_z` must be NUL-terminated. `ctx` (if non-null) enables the
/// `window.mer.invoke` bridge.
pub fn openWindow(url_z: [*:0]const u8, win: manifest.WindowConfig, ctx: ?*bridge.Ctx) void {
    const app = send(cls("NSApplication"), sel("sharedApplication"));
    sendIntv(app, sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);
    var app_title_buf: [256]u8 = undefined;
    const app_title_z = std.fmt.bufPrintZ(&app_title_buf, "{s}", .{win.title}) catch "merjs";
    installMainMenu(app, app_title_z.ptr);
    if (createAppDelegateClass()) |delegate_class| {
        g_app_delegate = send(send(delegate_class, sel("alloc")), sel("init"));
        send1v(app, sel("setDelegate:"), g_app_delegate);
    }

    const frame = CGRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(win.width), .height = @floatFromInt(win.height) },
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

    var title_buf: [256]u8 = undefined;
    const title_z = std.fmt.bufPrintZ(&title_buf, "{s}", .{win.title}) catch "merjs";
    const title = nsStringZ(title_z.ptr);
    send1v(window, sel("setTitle:"), title);

    // WKWebView with a configuration we can reach for the bridge.
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

    // Bridge: inject shim + register handler before the first load.
    if (ctx) |c| setupBridge(webview, c);

    // Load the merjs server URL.
    const ns_url_str = sendStr(cls("NSString"), sel("stringWithUTF8String:"), url_z);
    const url = send1(cls("NSURL"), sel("URLWithString:"), ns_url_str);
    const request = send1(cls("NSURLRequest"), sel("requestWithURL:"), url);
    _ = send1(webview, sel("loadRequest:"), request);

    send1v(window, sel("makeKeyAndOrderFront:"), null);
    sendBoolv(app, sel("activateIgnoringOtherApps:"), YES);
    sendv(app, sel("run")); // blocks until window closed
}

test "WK frame origins bracket IPv6 authorities" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("http://[::1]:8080", try formatSecurityOrigin(&buf, "http", "::1", 8080));
    try std.testing.expectEqualStrings("http://[::1]", try formatSecurityOrigin(&buf, "http", "[::1]", 0));
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", try formatSecurityOrigin(&buf, "http", "127.0.0.1", 8080));
}
