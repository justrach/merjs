//! Badge component for merlion-ui
//! Usage: const Badge = @import("components/badge.zig");

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
};

pub fn render(comptime props: Props) h.Node {
    const base_classes = "inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-semibold";
    const variant_cls = switch (props.variant) {
        .default => "border-transparent bg-slate-900 text-slate-50",
        .secondary => "border-transparent bg-slate-100 text-slate-900",
        .destructive => "border-transparent bg-red-500 text-slate-50",
        .outline => "text-slate-950",
    };
    return h.div(.{ .class = base_classes ++ " " ++ variant_cls }, props.label);
}
