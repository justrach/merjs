//! Card component for merlion-ui
//! Copy this file to app/components/card.zig

const std = @import("std");
const mer = @import("mer");
const h = mer.h;

pub const Props = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    children: []const h.Node = &.{},
    footer: ?[]const h.Node = null,
    class: ?[]const u8 = null,
};

pub fn render(props: Props) h.Node {
    var class_buf: [256]u8 = undefined;
    const classes = std.fmt.bufPrint(&class_buf, "rounded-lg border border-slate-200 bg-white shadow-sm {s}", .{
        props.class orelse "",
    }) catch "rounded-lg border border-slate-200 bg-white shadow-sm";
    
    var children = std.ArrayList(h.Node).init(std.heap.page_allocator);
    defer children.deinit();
    
    // Header
    if (props.title != null or props.description != null) {
        var header_children = std.ArrayList(h.Node).init(std.heap.page_allocator);
        defer header_children.deinit();
        
        if (props.title) |title| {
            header_children.append(
                h.h3(.{ .class = "text-lg font-semibold leading-none tracking-tight" }, title)
            ) catch {};
        }
        
        if (props.description) |desc| {
            header_children.append(
                h.p(.{ .class = "text-sm text-slate-500" }, desc)
            ) catch {};
        }
        
        children.append(
            h.div(.{ .class = "flex flex-col space-y-1.5 p-6" }, header_children.items)
        ) catch {};
    }
    
    // Content
    if (props.children.len > 0) {
        children.append(
            h.div(.{ .class = "p-6 pt-0" }, props.children)
        ) catch {};
    }
    
    // Footer
    if (props.footer) |footer| {
        children.append(
            h.div(.{ .class = "flex items-center p-6 pt-0" }, footer)
        ) catch {};
    }
    
    return h.div(.{ .class = classes }, children.items);
}

// Helper for card header only
pub fn header(title: []const u8, description: ?[]const u8) h.Node {
    var children = std.ArrayList(h.Node).init(std.heap.page_allocator);
    defer children.deinit();
    
    children.append(
        h.h3(.{ .class = "text-lg font-semibold leading-none tracking-tight" }, title)
    ) catch {};
    
    if (description) |desc| {
        children.append(
            h.p(.{ .class = "text-sm text-slate-500" }, desc)
        ) catch {};
    }
    
    return h.div(.{ .class = "flex flex-col space-y-1.5 p-6" }, children.items);
}

// Helper for card content
pub fn content(children: []const h.Node) h.Node {
    return h.div(.{ .class = "p-6 pt-0" }, children);
}

// Helper for card footer
pub fn footer(children: []const h.Node) h.Node {
    return h.div(.{ .class = "flex items-center p-6 pt-0" }, children);
}

// Example usage:
// const Card = @import("components/card.zig");
// 
// pub fn page() h.Node {
//     return Card.render(.{
//         .title = "Notifications",
//         .description = "You have 3 unread messages.",
//         .children = &.{
//             h.p(.{}, "Your content here..."),
//         },
//     });
// }
