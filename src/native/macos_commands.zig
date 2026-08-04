// macos_commands.zig — macOS implementations for built-in native bridge commands.
//
// Keep bridge.zig platform-neutral: it owns dispatch, permissions, and JSON
// envelopes. This file owns AppKit/Foundation command plumbing used by bridge
// handlers on macOS.

const std = @import("std");

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const BOOL = i8;
const YES: BOOL = 1;
const NO: BOOL = 0;
const NSInteger = c_long;
const NSModalResponseOK: NSInteger = 1;

extern fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern fn objc_msgSend() void;

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

fn send1(recv: Id, s: Sel, a: Id) Id {
    const F = *const fn (Id, Sel, Id) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}

fn send1Bool(recv: Id, s: Sel, a: Id) bool {
    const F = *const fn (Id, Sel, Id) callconv(.c) BOOL;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, a) != NO;
}

fn send2Bool(recv: Id, s: Sel, a: Id, b: Id) bool {
    const F = *const fn (Id, Sel, Id, Id) callconv(.c) BOOL;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, a, b) != NO;
}

fn sendPtr(recv: Id, s: Sel) [*:0]const u8 {
    const F = *const fn (Id, Sel) callconv(.c) [*:0]const u8;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s);
}

fn send1v(recv: Id, s: Sel, a: Id) void {
    const F = *const fn (Id, Sel, Id) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}

fn sendBoolv(recv: Id, s: Sel, a: BOOL) void {
    const F = *const fn (Id, Sel, BOOL) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}

fn sendInt(recv: Id, s: Sel) NSInteger {
    const F = *const fn (Id, Sel) callconv(.c) NSInteger;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s);
}

fn sendStr(recv: Id, s: Sel, value: [*:0]const u8) Id {
    const F = *const fn (Id, Sel, [*:0]const u8) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, value);
}

fn nsStringZ(value: [*:0]const u8) Id {
    return sendStr(cls("NSString"), sel("stringWithUTF8String:"), value);
}

fn nsString(text: []const u8) !Id {
    const text_z = try std.heap.page_allocator.dupeZ(u8, text);
    defer std.heap.page_allocator.free(text_z);
    return nsStringZ(text_z.ptr) orelse error.HandlerError;
}

fn pasteboardTypeString() Id {
    return nsStringZ("public.utf8-plain-text");
}

/// Return pasteboard text, or "" when no plain text exists.
pub fn clipboardRead() ![]const u8 {
    const pasteboard = send(cls("NSPasteboard"), sel("generalPasteboard")) orelse return error.HandlerError;
    const value = send1(pasteboard, sel("stringForType:"), pasteboardTypeString()) orelse return "";
    return std.mem.span(sendPtr(value, sel("UTF8String")));
}

pub fn clipboardWrite(text: []const u8) !void {
    const pasteboard = send(cls("NSPasteboard"), sel("generalPasteboard")) orelse return error.HandlerError;
    _ = send(pasteboard, sel("clearContents"));
    const value = try nsString(text);
    if (!send2Bool(pasteboard, sel("setString:forType:"), value, pasteboardTypeString())) return error.HandlerError;
}

pub const OpenPanelOptions = struct {
    title: []const u8,
    can_choose_files: bool,
    can_choose_directories: bool,
    can_create_directories: bool = false,
};

pub fn openPanel(alloc: std.mem.Allocator, options: OpenPanelOptions) !?[]const u8 {
    const panel = send(cls("NSOpenPanel"), sel("openPanel")) orelse return error.HandlerError;
    sendBoolv(panel, sel("setCanChooseFiles:"), if (options.can_choose_files) YES else NO);
    sendBoolv(panel, sel("setCanChooseDirectories:"), if (options.can_choose_directories) YES else NO);
    sendBoolv(panel, sel("setCanCreateDirectories:"), if (options.can_create_directories) YES else NO);
    sendBoolv(panel, sel("setAllowsMultipleSelection:"), NO);
    send1v(panel, sel("setTitle:"), try nsString(options.title));

    const response = sendInt(panel, sel("runModal"));
    if (response != NSModalResponseOK) return null;

    const url = send(panel, sel("URL")) orelse return null;
    const path = send(url, sel("path")) orelse return null;
    return try alloc.dupe(u8, std.mem.span(sendPtr(path, sel("UTF8String"))));
}

pub fn openUrl(url: []const u8) !void {
    const ns_url = send1(cls("NSURL"), sel("URLWithString:"), try nsString(url)) orelse return error.HandlerError;
    const workspace = send(cls("NSWorkspace"), sel("sharedWorkspace")) orelse return error.HandlerError;
    if (!send1Bool(workspace, sel("openURL:"), ns_url)) return error.HandlerError;
}

pub fn openPath(path: []const u8) !void {
    const workspace = send(cls("NSWorkspace"), sel("sharedWorkspace")) orelse return error.HandlerError;
    if (!send1Bool(workspace, sel("openFile:"), try nsString(path))) return error.HandlerError;
}

pub fn setWindowTitle(title: []const u8) !void {
    const app = send(cls("NSApplication"), sel("sharedApplication")) orelse return error.HandlerError;
    const window = send(app, sel("keyWindow")) orelse return error.HandlerError;
    send1v(window, sel("setTitle:"), try nsString(title));
}

pub fn closeWindow() !void {
    const app = send(cls("NSApplication"), sel("sharedApplication")) orelse return error.HandlerError;
    const window = send(app, sel("keyWindow")) orelse return error.HandlerError;
    _ = send1(window, sel("performClose:"), null);
}
