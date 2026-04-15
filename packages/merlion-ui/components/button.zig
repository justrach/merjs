//! Button component for merlion-ui
//! Copy this file to app/components/button.zig

const std = @import("std");
const mer = @import("mer");
const h = mer.h;

pub const Variant = enum {
    primary,
    secondary,
    destructive,
    outline,
    ghost,
    link,
};

pub const Size = enum {
    sm,
    md,
    lg,
    icon,
};

pub const Props = struct {
    label: []const u8,
    variant: Variant = .primary,
    size: Size = .md,
    disabled: bool = false,
    on_click: ?[]const u8 = null,
    class: ?[]const u8 = null,
    id: ?[]const u8 = null,
    type: []const u8 = "button",
};

fn variantClasses(variant: Variant) []const u8 {
    return switch (variant) {
        .primary => "bg-slate-900 text-white hover:bg-slate-800",
        .secondary => "bg-slate-100 text-slate-900 hover:bg-slate-200",
        .destructive => "bg-red-600 text-white hover:bg-red-700",
        .outline => "border border-slate-300 bg-transparent hover:bg-slate-100",
        .ghost => "hover:bg-slate-100",
        .link => "text-slate-900 underline-offset-4 hover:underline",
    };
}

fn sizeClasses(size: Size) []const u8 {
    return switch (size) {
        .sm => "h-8 px-3 text-sm",
        .md => "h-10 px-4 py-2",
        .lg => "h-12 px-6 text-lg",
        .icon => "h-10 w-10 p-2",
    };
}

pub fn render(props: Props) h.Node {
    const base_classes = "inline-flex items-center justify-center rounded-md font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-slate-400 disabled:pointer-events-none disabled:opacity-50";
    
    const variant_cls = variantClasses(props.variant);
    const size_cls = sizeClasses(props.size);
    
    var class_buf: [512]u8 = undefined;
    const classes = std.fmt.bufPrint(&class_buf, "{s} {s} {s} {s}", .{
        base_classes,
        variant_cls,
        size_cls,
        props.class orelse "",
    }) catch base_classes;
    
    var attrs = std.ArrayList(h.Attribute).init(std.heap.page_allocator);
    defer attrs.deinit();
    
    attrs.append(.{ .name = "class", .value = classes }) catch {};
    attrs.append(.{ .name = "type", .value = props.type }) catch {};
    
    if (props.id) |id| {
        attrs.append(.{ .name = "id", .value = id }) catch {};
    }
    
    if (props.disabled) {
        attrs.append(.{ .name = "disabled", .value = "" }) catch {};
    }
    
    if (props.on_click) |on_click| {
        attrs.append(.{ .name = "onclick", .value = on_click }) catch {};
    }
    
    return h.button(
        .{ .attributes = attrs.items },
        props.label,
    );
}

// Convenience functions for common variants
pub fn primary(props: Props) h.Node {
    return render(.{ .label = props.label, .variant = .primary });
}

pub fn secondary(props: Props) h.Node {
    return render(.{ .label = props.label, .variant = .secondary });
}

pub fn destructive(props: Props) h.Node {
    return render(.{ .label = props.label, .variant = .destructive });
}

pub fn outline(props: Props) h.Node {
    return render(.{ .label = props.label, .variant = .outline });
}

// Example usage:
// const Button = @import("components/button.zig");
// 
// pub fn page() h.Node {
//     return Button.render(.{
//         .label = "Submit",
//         .variant = .primary,
//         .on_click = "submitForm()",
//     });
// }
