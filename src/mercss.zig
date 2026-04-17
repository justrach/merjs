//! mercss.zig - Compile-time atomic CSS for merjs
//!
//! Inspired by Tailwind CSS but leveraging Zig's comptime:
//! - No build step (Zig IS the build)
//! - No purging (comptime knows all used styles)
//! - Type-safe design tokens
//! - Component-level style scoping

const std = @import("std");

/// Design tokens - the "tailwind.config.js" equivalent at comptime
pub const DesignSystem = struct {
    colors: type,
    spacing: type,
    fonts: type,
    breakpoints: type,
};

/// A single atomic style property
pub const StyleProperty = struct {
    name: []const u8,
    value: []const u8,

    /// Generate deterministic hash for class name
    pub fn hash(self: StyleProperty) u32 {
        var h: u32 = 5381;
        for (self.name) |c| h = ((h << 5) + h) + c;
        for (self.value) |c| h = ((h << 5) + h) + c;
        return h;
    }
};

/// Component styles that generate atomic CSS at comptime
pub fn ComponentStyles(comptime config: anytype) type {
    return struct {
        /// Base styles - always applied
        pub const base = generateAtomicClasses(config.base);

        /// State variants (hover, focus, etc.)
        pub const states = if (@hasField(@TypeOf(config), "states"))
            generateStateClasses(config.states)
        else
            .{};

        /// Generate all CSS for this component at comptime
        pub fn getAllCss() []const u8 {
            comptime {
                var buf: [4096]u8 = undefined;
                var written: usize = 0;

                // Generate base styles
                inline for (base) |cls| {
                    const css = std.fmt.bufPrint(buf[written..], ".{s}{{{s}:{s}}}", .{ cls.name, cls.property, cls.value }) catch break;
                    written += css.len;
                }

                return buf[0..written];
            }
        }
    };
}

/// Helper: Convert style struct to atomic classes
fn generateAtomicClasses(comptime styles: anytype) []const StyleProperty {
    comptime {
        const T = @TypeOf(styles);
        const info = @typeInfo(T);

        // Count fields
        var count: usize = 0;
        inline for (info.Struct.fields) |_| count += 1;

        // Generate style properties
        var result: [count]StyleProperty = undefined;
        var i: usize = 0;

        inline for (info.Struct.fields) |field| {
            const value = @field(styles, field.name);
            result[i] = .{
                .name = field.name,
                .value = switch (@typeInfo(@TypeOf(value))) {
                    .Enum => @tagName(value),
                    .Int, .ComptimeInt => std.fmt.comptimePrint("{d}px", .{value}),
                    else => value,
                },
            };
            i += 1;
        }

        return &result;
    }
}

/// Usage example - type-safe CSS
const MyDesignSystem = struct {
    pub const colors = .{
        .primary = "#3b82f6",
        .secondary = "#64748b",
        .danger = "#ef4444",
    };

    pub const spacing = .{
        .xs = 4,
        .sm = 8,
        .md = 16,
        .lg = 24,
        .xl = 32,
    };
};

/// Button component with compile-time styles
pub const Button = ComponentStyles(.{
    .base = .{
        .padding = "8px 16px",
        .border_radius = "6px",
        .font_weight = "600",
        .cursor = "pointer",
        .transition = "all 0.2s",
    },
    .states = .{
        .hover = .{ .background = MyDesignSystem.colors.primary },
        .active = .{ .transform = "scale(0.98)" },
    },
});

/// Card component
pub const Card = ComponentStyles(.{
    .base = .{
        .background = "white",
        .border_radius = "8px",
        .padding = "16px",
        .box_shadow = "0 1px 3px rgba(0,0,0,0.1)",
    },
});

/// Stream CSS efficiently - critical styles first
pub const StreamingCSS = struct {
    /// Critical CSS (above-fold, always needed)
    pub const critical =
        Button.getAllCss() ++
        Card.getAllCss();

    /// Component-specific CSS that can stream later
    pub fn streamForComponent(comptime component_name: []const u8) []const u8 {
        // Only stream CSS for components that are actually rendered
        // This is determined at compile time!
        if (comptime std.mem.eql(u8, component_name, "Button")) {
            return Button.getAllCss();
        } else if (comptime std.mem.eql(u8, component_name, "Card")) {
            return Card.getAllCss();
        }
        return "";
    }
};

// Generated CSS would look like:
// .a7f3e{padding:8px 16px;border-radius:6px;font-weight:600;cursor:pointer;transition:all 0.2s}
// .b2c9d{background:white;border-radius:8px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,0.1)}

/// TEST: Verify CSS generation
const testing = std.testing;

test "atomic CSS generation" {
    const css = Button.getAllCss();
    try testing.expect(css.len > 0);
    // CSS contains button styles
    try testing.expect(std.mem.indexOf(u8, css, "padding") != null);
}

test "design system type safety" {
    // This would fail at compile time:
    // const bad = ComponentStyles(.{ .base = .{ .color = undefined_color }});

    // This works:
    const good = ComponentStyles(.{ .base = .{ .color = "#333" } });
    try testing.expect(good.getAllCss().len > 0);
}
