//! Input component for merlion-ui
//! Usage: const Input = @import("components/input.zig");

const std = @import("std");
const mer = @import("mer");
const h = mer.h;

pub const Props = struct {
    name: []const u8,
    type: []const u8 = "text",
    placeholder: ?[]const u8 = null,
    value: ?[]const u8 = null,
    label: ?[]const u8 = null,
    class: ?[]const u8 = null,
};

pub fn render(props: Props) h.Node {
    const base_classes = "flex h-10 w-full rounded-md border border-slate-300 bg-transparent px-3 py-2 text-sm placeholder:text-slate-400 focus:outline-none focus:ring-2 focus:ring-slate-400";
    var class_buf: [256]u8 = undefined;
    const classes = std.fmt.bufPrint(&class_buf, "{s} {s}", .{
        base_classes,
        props.class orelse "",
    }) catch base_classes;
    return h.input(.{
        .class = classes,
        .name = props.name,
        .type_attr = props.type,
        .placeholder = props.placeholder,
        .value = props.value,
    });
}
