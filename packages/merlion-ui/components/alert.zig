//! Alert component for merlion-ui
//! Copy this file to app/components/alert.zig

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
    class: ?[]const u8 = null,
};

fn variantClasses(v: Variant) []const u8 {
    return switch (v) {
        .default => "border-slate-200 bg-slate-50 text-slate-900",
        .destructive => "border-red-200 bg-red-50 text-red-900",
    };
}

fn iconColor(v: Variant) []const u8 {
    return switch (v) {
        .default => "text-slate-900",
        .destructive => "text-red-900",
    };
}

pub fn render(props: Props) h.Node {
    const base_classes = "relative w-full rounded-lg border p-4";
    
    var class_buf: [512]u8 = undefined;
    const classes = std.fmt.bufPrint(&class_buf, "{s} {s} {s}", .{
        base_classes,
        variantClasses(props.variant),
        props.class orelse "",
    }) catch base_classes;
    
    var children = std.ArrayList(h.Node).init(std.heap.page_allocator);
    defer children.deinit();
    
    // Alert icon (simple SVG circle with exclamation)
    const icon_svg = \\\\<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="{s}"><circle cx="12" cy="12" r="10"></circle><line x1="12" y1="8" x2="12" y2="12"></line><line x1="12" y1="16" x2="12.01" y2="16"></line></svg>
    ;
    
    var icon_buf: [512]u8 = undefined;
    const icon = std.fmt.bufPrint(&icon_buf, icon_svg, .{iconColor(props.variant)}) catch "";
    
    var content_children = std.ArrayList(h.Node).init(std.heap.page_allocator);
    defer content_children.deinit();
    
    if (props.title) |title| {
        content_children.append(
            h.h5(.{ .class = "mb-1 font-medium leading-none tracking-tight" }, title)
        ) catch {};
    }
    
    content_children.append(
        h.div(.{ .class = "text-sm" }, props.description)
    ) catch {};
    
    children.append(
        h.raw(icon)
    ) catch {};
    
    children.append(
        h.div(.{ .class = "ml-3" }, content_children.items)
    ) catch {};
    
    return h.div(
        .{ .class = classes, .role = "alert" },
        h.div(.{ .class = "flex items-start" }, children.items),
    );
}

// Convenience functions
pub fn info(description: []const u8) h.Node {
    return render(.{ .description = description, .variant = .default });
}

pub fn errorAlert(title: []const u8, description: []const u8) h.Node {
    return render(.{
        .title = title,
        .description = description,
        .variant = .destructive,
    });
}

// Example usage:
// const Alert = @import("components/alert.zig");
//
// pub fn page() h.Node {
//     return Alert.render(.{
//         .title = "Error",
//         .description = "Something went wrong. Please try again.",
//         .variant = .destructive,
//     });
// }
