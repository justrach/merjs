//! Button component for merlion-ui
//! Usage: const Button = @import("components/button.zig");

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

fn variantClasses(comptime variant: Variant) []const u8 {
    return switch (variant) {
        .primary => "bg-slate-900 text-white hover:bg-slate-800",
        .secondary => "bg-slate-100 text-slate-900 hover:bg-slate-200",
        .destructive => "bg-red-600 text-white hover:bg-red-700",
        .outline => "border border-slate-300 bg-transparent hover:bg-slate-100",
        .ghost => "hover:bg-slate-100",
        .link => "text-slate-900 underline-offset-4 hover:underline",
    };
}

fn sizeClasses(comptime size: Size) []const u8 {
    return switch (size) {
        .sm => "h-8 px-3 text-sm",
        .md => "h-10 px-4 py-2",
        .lg => "h-12 px-6 text-lg",
        .icon => "h-10 w-10 p-2",
    };
}

pub fn render(comptime props: Props) h.Node {
    const base_classes = "inline-flex items-center justify-center rounded-md font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-slate-400 disabled:pointer-events-none disabled:opacity-50";
    const variant_classes = comptime variantClasses(props.variant);
    const size_classes = comptime sizeClasses(props.size);
    const classes = base_classes ++ " " ++ variant_classes ++ " " ++
        size_classes ++ " " ++ (props.class orelse "");
    return h.button(.{
        .class = classes,
        .id = props.id,
        .type = props.type,
        .disabled = props.disabled,
        .extra = if (props.on_click) |on_click|
            &.{.{ .name = "onclick", .value = on_click }}
        else
            &.{},
    }, props.label);
}
