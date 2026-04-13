//! Alert component for merlion-ui
//! Usage: const Alert = @import("components/alert.zig");

const std = @import("std");
const mer = @import("mer");
const h = mer.h;

pub const Variant = enum {
    default,
    destructive,
};

pub const Props = struct {
    title: ?[]const u8 = null,
    description: []const u8,
    variant: Variant = .default,
};

pub fn render(props: Props) h.Node {
    const base_classes = "relative w-full rounded-lg border p-4";
    const variant_cls = switch (props.variant) {
        .default => "border-slate-200 bg-slate-50 text-slate-900",
        .destructive => "border-red-200 bg-red-50 text-red-900",
    };
    var class_buf: [256]u8 = undefined;
    const classes = std.fmt.bufPrint(&class_buf, "{s} {s}", .{
        base_classes,
        variant_cls,
    }) catch base_classes;
    return h.div(.{ .class = classes, .role = "alert" }, props.description);
}
