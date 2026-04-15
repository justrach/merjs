//! Badge component for merlion-ui
//! Copy this file to app/components/badge.zig

const std = @import("std");
const mer = @import("mer");
const h = mer.h;

pub const Variant = enum {
    default,
    secondary,
    destructive,
    outline,
};

pub const Props = struct {
    label: []const u8,
    variant: Variant = .default,
    class: ?[]const u8 = null,
};

fn variantClasses(v: Variant) []const u8 {
    return switch (v) {
        .default => "border-transparent bg-slate-900 text-slate-50",
        .secondary => "border-transparent bg-slate-100 text-slate-900",
        .destructive => "border-transparent bg-red-500 text-slate-50",
        .outline => "text-slate-950",
    };
}

pub fn render(props: Props) h.Node {
    const base_classes = "inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-semibold transition-colors focus:outline-none focus:ring-2 focus:ring-slate-950 focus:ring-offset-2";
    
    var class_buf: [512]u8 = undefined;
    const classes = std.fmt.bufPrint(&class_buf, "{s} {s} {s}", .{
        base_classes,
        variantClasses(props.variant),
        props.class orelse "",
    }) catch base_classes;
    
    return h.div(.{ .class = classes }, props.label);
}

// Convenience functions
pub fn default(label: []const u8) h.Node {
    return render(.{ .label = label, .variant = .default });
}

pub fn secondary(label: []const u8) h.Node {
    return render(.{ .label = label, .variant = .secondary });
}

pub fn destructive(label: []const u8) h.Node {
    return render(.{ .label = label, .variant = .destructive });
}

pub fn outline(label: []const u8) h.Node {
    return render(.{ .label = label, .variant = .outline });
}

// Example usage:
// const Badge = @import("components/badge.zig");
//
// pub fn page() h.Node {
//     return h.div(.{}, &.{
//         Badge.default("New"),
//         Badge.destructive("Alert"),
//         Badge.outline("Draft"),
//     });
// }
