//! Card component for merlion-ui
//! Usage: const Card = @import("components/card.zig");

const mer = @import("mer");
const h = mer.h;

pub const Props = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    children: []const h.Node = &.{},
    footer: ?[]const h.Node = null,
    class: ?[]const u8 = null,
};

pub fn render(comptime props: Props) h.Node {
    const base_classes = "rounded-lg border border-slate-200 bg-white shadow-sm";
    const classes = base_classes ++ " " ++ (props.class orelse "");
    return h.div(.{ .class = classes }, props.children);
}
