//! Input component for merlion-ui
//! Copy this file to app/components/input.zig

const std = @import("std");
const mer = @import("mer");
const h = mer.h;

pub const Type = enum {
    text,
    email,
    password,
    number,
    tel,
    url,
    search,
    date,
    datetime_local,
    time,
};

pub const Props = struct {
    name: []const u8,
    type: Type = .text,
    placeholder: ?[]const u8 = null,
    value: ?[]const u8 = null,
    label: ?[]const u8 = null,
    description: ?[]const u8 = null,
    error: ?[]const u8 = null,
    required: bool = false,
    disabled: bool = false,
    id: ?[]const u8 = null,
    class: ?[]const u8 = null,
};

fn typeString(t: Type) []const u8 {
    return switch (t) {
        .text => "text",
        .email => "email",
        .password => "password",
        .number => "number",
        .tel => "tel",
        .url => "url",
        .search => "search",
        .date => "date",
        .datetime_local => "datetime-local",
        .time => "time",
    };
}

pub fn render(props: Props) h.Node {
    const base_classes = "flex h-10 w-full rounded-md border border-slate-300 bg-transparent px-3 py-2 text-sm placeholder:text-slate-400 focus:outline-none focus:ring-2 focus:ring-slate-400 focus:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50";
    
    const error_classes = if (props.error != null) " border-red-500 focus:ring-red-500" else "";
    
    var class_buf: [512]u8 = undefined;
    const classes = std.fmt.bufPrint(&class_buf, "{s}{s} {s}", .{
        base_classes,
        error_classes,
        props.class orelse "",
    }) catch base_classes;
    
    var attrs = std.ArrayList(h.Attribute).init(std.heap.page_allocator);
    defer attrs.deinit();
    
    attrs.append(.{ .name = "type", .value = typeString(props.type) }) catch {};
    attrs.append(.{ .name = "name", .value = props.name }) catch {};
    attrs.append(.{ .name = "class", .value = classes }) catch {};
    
    const id = props.id orelse props.name;
    attrs.append(.{ .name = "id", .value = id }) catch {};
    
    if (props.placeholder) |ph| {
        attrs.append(.{ .name = "placeholder", .value = ph }) catch {};
    }
    
    if (props.value) |val| {
        attrs.append(.{ .name = "value", .value = val }) catch {};
    }
    
    if (props.required) {
        attrs.append(.{ .name = "required", .value = "" }) catch {};
    }
    
    if (props.disabled) {
        attrs.append(.{ .name = "disabled", .value = "" }) catch {};
    }
    
    const input = h.input(.{ .attributes = attrs.items });
    
    // If no label, return just input
    if (props.label == null and props.description == null and props.error == null) {
        return input;
    }
    
    // Build wrapper with label
    var children = std.ArrayList(h.Node).init(std.heap.page_allocator);
    defer children.deinit();
    
    if (props.label) |label_text| {
        children.append(
            h.label(
                .{ .class = "text-sm font-medium leading-none", .for_attr = id },
                label_text,
            )
        ) catch {};
    }
    
    children.append(input) catch {};
    
    if (props.description) |desc| {
        children.append(
            h.p(.{ .class = "text-sm text-slate-500" }, desc)
        ) catch {};
    }
    
    if (props.error) |err| {
        children.append(
            h.p(.{ .class = "text-sm text-red-500" }, err)
        ) catch {};
    }
    
    return h.div(.{ .class = "space-y-2" }, children.items);
}

// Example usage:
// const Input = @import("components/input.zig");
//
// pub fn page() h.Node {
//     return Input.render(.{
//         .name = "email",
//         .type = .email,
//         .label = "Email",
//         .placeholder = "you@example.com",
//         .required = true,
//     });
// }
