//! mercss.zig - Compile-time atomic CSS for merjs
//!
//! Inspired by Tailwind CSS but leveraging Zig's comptime:
//! - No build step (Zig IS the build)
//! - No purging (comptime knows all used styles)
//! - Type-safe design tokens
//! - Component-level style scoping

const std = @import("std");

const safe_class = "mcss-safe";
const safe_css = ".mcss-safe{box-sizing:border-box;min-width:0;max-width:100%;overflow:hidden;overflow-wrap:anywhere;word-break:break-word;}";

/// Convert snake_case to kebab-case at comptime
fn toKebabCase(comptime str: []const u8) []const u8 {
    comptime {
        var result: [str.len * 2]u8 = undefined;
        var j: usize = 0;

        for (str, 0..) |c, i| {
            if (c == '_' and i > 0 and i < str.len - 1) {
                result[j] = '-';
                j += 1;
            } else if (c != '_') {
                result[j] = c;
                j += 1;
            }
        }

        return result[0..j];
    }
}

fn valueToString(comptime value: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @tagName(value),
        .int, .comptime_int => std.fmt.comptimePrint("{d}px", .{value}),
        else => value,
    };
}

fn classHash(comptime field_name: []const u8, comptime value_str: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100000);
        const key = field_name ++ ":" ++ value_str;
        return std.fmt.comptimePrint("{x}", .{std.hash.Wyhash.hash(0, key)});
    }
}

fn atomicClassName(comptime variant: []const u8, comptime field_name: []const u8, comptime value_str: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100000);
        const hash = classHash(field_name, value_str);
        if (variant.len == 0) {
            return std.fmt.comptimePrint("mcss-{s}-{s}", .{ field_name, hash });
        }

        return std.fmt.comptimePrint("mcss-{s}-{s}-{s}", .{ variant, field_name, hash });
    }
}

fn withSafeClassNames(comptime names: []const u8) []const u8 {
    comptime {
        if (names.len == 0) return safe_class;
        return safe_class ++ " " ++ names;
    }
}

/// Helper to generate CSS from style struct at comptime
fn generateCss(comptime styles: anytype) []const u8 {
    comptime {
        var css: []const u8 = "";

        const T = @TypeOf(styles);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.fields) |field| {
                    const value = @field(styles, field.name);
                    const value_str = valueToString(value);
                    const css_property = toKebabCase(field.name);
                    const class_name = atomicClassName("", field.name, value_str);
                    const rule = std.fmt.comptimePrint(".{s}{{{s}:{s};}}", .{ class_name, css_property, value_str });
                    css = css ++ rule;
                }
            },
            else => {},
        }

        return css;
    }
}

/// Get class names from style struct
fn getClassNames(comptime styles: anytype) []const u8 {
    comptime {
        var names: []const u8 = "";

        const T = @TypeOf(styles);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.fields) |field| {
                    const value = @field(styles, field.name);
                    const value_str = valueToString(value);
                    const name = std.fmt.comptimePrint("{s} ", .{atomicClassName("", field.name, value_str)});
                    names = names ++ name;
                }
            },
            else => {},
        }

        return if (names.len > 0) names[0 .. names.len - 1] else "";
    }
}

/// Create a component with compile-time CSS
pub fn Component(comptime styles: anytype) type {
    return struct {
        pub const css = safe_css ++ generateCss(styles);
        pub const classes = withSafeClassNames(getClassNames(styles));
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// RESPONSIVE COMPONENTS - Mobile-first breakpoints
// ═══════════════════════════════════════════════════════════════════════════════

/// Tailwind-compatible breakpoints
pub const Breakpoints = struct {
    pub const sm = 640; // 640px
    pub const md = 768; // 768px
    pub const lg = 1024; // 1024px
    pub const xl = 1280; // 1280px
    pub const xl2 = 1536; // 1536px (2xl)
};

/// Generate responsive CSS with media queries at comptime
fn generateResponsiveCss(comptime config: anytype) []const u8 {
    comptime {
        var css: []const u8 = "";

        // Generate base styles (mobile-first)
        if (@hasField(@TypeOf(config), "base")) {
            css = css ++ generateCss(config.base);
        }

        // Generate sm breakpoint (640px+)
        if (@hasField(@TypeOf(config), "sm")) {
            const sm_css = generateBreakpointCss("sm", config.sm);
            css = css ++ "@media (min-width: 640px){" ++ sm_css ++ "}";
        }

        // Generate md breakpoint (768px+)
        if (@hasField(@TypeOf(config), "md")) {
            const md_css = generateBreakpointCss("md", config.md);
            css = css ++ "@media (min-width: 768px){" ++ md_css ++ "}";
        }

        // Generate lg breakpoint (1024px+)
        if (@hasField(@TypeOf(config), "lg")) {
            const lg_css = generateBreakpointCss("lg", config.lg);
            css = css ++ "@media (min-width: 1024px){" ++ lg_css ++ "}";
        }

        // Generate xl breakpoint (1280px+)
        if (@hasField(@TypeOf(config), "xl")) {
            const xl_css = generateBreakpointCss("xl", config.xl);
            css = css ++ "@media (min-width: 1280px){" ++ xl_css ++ "}";
        }

        return css;
    }
}

/// Generate CSS for a specific breakpoint with prefixed class names
fn generateBreakpointCss(comptime prefix: []const u8, comptime styles: anytype) []const u8 {
    comptime {
        var css: []const u8 = "";

        const T = @TypeOf(styles);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.fields) |field| {
                    const value = @field(styles, field.name);
                    const value_str = valueToString(value);
                    const css_property = toKebabCase(field.name);
                    const class_name = atomicClassName(prefix, field.name, value_str);
                    const rule = std.fmt.comptimePrint(".{s}{{{s}:{s};}}", .{ class_name, css_property, value_str });
                    css = css ++ rule;
                }
            },
            else => {},
        }

        return css;
    }
}

/// Get responsive class names
fn getResponsiveClassNames(comptime config: anytype) []const u8 {
    comptime {
        var names: []const u8 = "";

        // Base classes
        if (@hasField(@TypeOf(config), "base")) {
            const base_names = getClassNames(config.base);
            names = names ++ base_names ++ " ";
        }

        // sm classes
        if (@hasField(@TypeOf(config), "sm")) {
            const sm_names = getBreakpointClassNames("sm", config.sm);
            names = names ++ sm_names ++ " ";
        }

        // md classes
        if (@hasField(@TypeOf(config), "md")) {
            const md_names = getBreakpointClassNames("md", config.md);
            names = names ++ md_names ++ " ";
        }

        // lg classes
        if (@hasField(@TypeOf(config), "lg")) {
            const lg_names = getBreakpointClassNames("lg", config.lg);
            names = names ++ lg_names ++ " ";
        }

        // xl classes
        if (@hasField(@TypeOf(config), "xl")) {
            const xl_names = getBreakpointClassNames("xl", config.xl);
            names = names ++ xl_names ++ " ";
        }

        // Remove trailing space
        return if (names.len > 0) names[0 .. names.len - 1] else "";
    }
}

/// Get class names for a specific breakpoint
fn getBreakpointClassNames(comptime prefix: []const u8, comptime styles: anytype) []const u8 {
    comptime {
        var names: []const u8 = "";

        const T = @TypeOf(styles);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.fields) |field| {
                    const value = @field(styles, field.name);
                    const value_str = valueToString(value);
                    const name = std.fmt.comptimePrint("{s} ", .{atomicClassName(prefix, field.name, value_str)});
                    names = names ++ name;
                }
            },
            else => {},
        }

        return if (names.len > 0) names[0 .. names.len - 1] else "";
    }
}

/// Create a responsive component with mobile-first breakpoints
///
/// Usage:
/// ```zig
/// const Button = mercss.ResponsiveComponent(.{
///     .base = .{ .padding = "8px" },
///     .sm = .{ .padding = "16px" },
///     .md = .{ .padding = "24px" },
/// });
/// ```
pub fn ResponsiveComponent(comptime config: anytype) type {
    return struct {
        pub const css = safe_css ++ generateResponsiveCss(config);
        pub const classes = withSafeClassNames(getResponsiveClassNames(config));
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// STATE VARIANTS - Hover, Focus, Active
// ═══════════════════════════════════════════════════════════════════════════════

/// State pseudo-classes for interactive components
pub const State = enum {
    hover,
    focus,
    active,
};

/// Generate CSS for state variants (hover:, focus:, active:)
fn generateStateCss(comptime prefix: []const u8, comptime styles: anytype) []const u8 {
    comptime {
        var css: []const u8 = "";

        const T = @TypeOf(styles);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.fields) |field| {
                    const value = @field(styles, field.name);
                    const value_str = valueToString(value);
                    const css_property = toKebabCase(field.name);
                    const class_name = atomicClassName(prefix, field.name, value_str);
                    const rule = std.fmt.comptimePrint(".{s}:{s}{{{s}:{s};}}", .{ class_name, prefix, css_property, value_str });
                    css = css ++ rule;
                }
            },
            else => {},
        }

        return css;
    }
}

/// Get class names for state variants
fn getStateClassNames(comptime prefix: []const u8, comptime styles: anytype) []const u8 {
    comptime {
        var names: []const u8 = "";

        const T = @TypeOf(styles);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.fields) |field| {
                    const value = @field(styles, field.name);
                    const value_str = valueToString(value);
                    const name = std.fmt.comptimePrint("{s} ", .{atomicClassName(prefix, field.name, value_str)});
                    names = names ++ name;
                }
            },
            else => {},
        }

        return if (names.len > 0) names[0 .. names.len - 1] else "";
    }
}

/// Generate responsive + state combined CSS (e.g., hover:md:)
fn generateResponsiveStateCss(comptime bp: []const u8, comptime state: []const u8, comptime styles: anytype) []const u8 {
    comptime {
        var css: []const u8 = "";

        const T = @TypeOf(styles);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.fields) |field| {
                    const value = @field(styles, field.name);
                    const value_str = valueToString(value);
                    const css_property = toKebabCase(field.name);
                    const variant = std.fmt.comptimePrint("{s}-{s}", .{ state, bp });
                    const class_name = atomicClassName(variant, field.name, value_str);
                    const rule = std.fmt.comptimePrint(".{s}:{s}{{{s}:{s};}}", .{ class_name, state, css_property, value_str });
                    css = css ++ rule;
                }
            },
            else => {},
        }

        return css;
    }
}

/// Generate CSS for an interactive component with states
fn generateInteractiveCss(comptime config: anytype) []const u8 {
    comptime {
        @setEvalBranchQuota(10000);
        var css: []const u8 = "";

        // Base styles
        if (@hasField(@TypeOf(config), "base")) {
            css = css ++ generateCss(config.base);
        }

        // Hover styles
        if (@hasField(@TypeOf(config), "hover")) {
            css = css ++ generateStateCss("hover", config.hover);
        }

        // Focus styles
        if (@hasField(@TypeOf(config), "focus")) {
            css = css ++ generateStateCss("focus", config.focus);
        }

        // Active styles
        if (@hasField(@TypeOf(config), "active")) {
            css = css ++ generateStateCss("active", config.active);
        }

        // Responsive breakpoints with states
        // Format: hover:sm:property = .mcss-hover-sm-property:hover inside @media

        // sm breakpoint (640px+) with states
        if (@hasField(@TypeOf(config), "sm")) {
            const sm_config = config.sm;
            var sm_css: []const u8 = "";

            if (@hasField(@TypeOf(sm_config), "base")) {
                sm_css = sm_css ++ generateBreakpointCss("sm", sm_config.base);
            }
            if (@hasField(@TypeOf(sm_config), "hover")) {
                sm_css = sm_css ++ generateResponsiveStateCss("sm", "hover", sm_config.hover);
            }
            if (@hasField(@TypeOf(sm_config), "focus")) {
                sm_css = sm_css ++ generateResponsiveStateCss("sm", "focus", sm_config.focus);
            }
            if (@hasField(@TypeOf(sm_config), "active")) {
                sm_css = sm_css ++ generateResponsiveStateCss("sm", "active", sm_config.active);
            }

            if (sm_css.len > 0) {
                css = css ++ "@media (min-width: 640px){" ++ sm_css ++ "}";
            }
        }

        // md breakpoint (768px+) with states
        if (@hasField(@TypeOf(config), "md")) {
            const md_config = config.md;
            var md_css: []const u8 = "";

            if (@hasField(@TypeOf(md_config), "base")) {
                md_css = md_css ++ generateBreakpointCss("md", md_config.base);
            }
            if (@hasField(@TypeOf(md_config), "hover")) {
                md_css = md_css ++ generateResponsiveStateCss("md", "hover", md_config.hover);
            }
            if (@hasField(@TypeOf(md_config), "focus")) {
                md_css = md_css ++ generateResponsiveStateCss("md", "focus", md_config.focus);
            }
            if (@hasField(@TypeOf(md_config), "active")) {
                md_css = md_css ++ generateResponsiveStateCss("md", "active", md_config.active);
            }

            if (md_css.len > 0) {
                css = css ++ "@media (min-width: 768px){" ++ md_css ++ "}";
            }
        }

        // lg breakpoint (1024px+) with states
        if (@hasField(@TypeOf(config), "lg")) {
            const lg_config = config.lg;
            var lg_css: []const u8 = "";

            if (@hasField(@TypeOf(lg_config), "base")) {
                lg_css = lg_css ++ generateBreakpointCss("lg", lg_config.base);
            }
            if (@hasField(@TypeOf(lg_config), "hover")) {
                lg_css = lg_css ++ generateResponsiveStateCss("lg", "hover", lg_config.hover);
            }
            if (@hasField(@TypeOf(lg_config), "focus")) {
                lg_css = lg_css ++ generateResponsiveStateCss("lg", "focus", lg_config.focus);
            }
            if (@hasField(@TypeOf(lg_config), "active")) {
                lg_css = lg_css ++ generateResponsiveStateCss("lg", "active", lg_config.active);
            }

            if (lg_css.len > 0) {
                css = css ++ "@media (min-width: 1024px){" ++ lg_css ++ "}";
            }
        }

        return css;
    }
}

/// Get class names for interactive component
fn getInteractiveClassNames(comptime config: anytype) []const u8 {
    comptime {
        @setEvalBranchQuota(5000);
        var names: []const u8 = "";

        // Base classes
        if (@hasField(@TypeOf(config), "base")) {
            const base_names = getClassNames(config.base);
            if (base_names.len > 0) {
                names = names ++ base_names ++ " ";
            }
        }

        // Hover classes
        if (@hasField(@TypeOf(config), "hover")) {
            const hover_names = getStateClassNames("hover", config.hover);
            if (hover_names.len > 0) {
                names = names ++ hover_names ++ " ";
            }
        }

        // Focus classes
        if (@hasField(@TypeOf(config), "focus")) {
            const focus_names = getStateClassNames("focus", config.focus);
            if (focus_names.len > 0) {
                names = names ++ focus_names ++ " ";
            }
        }

        // Active classes
        if (@hasField(@TypeOf(config), "active")) {
            const active_names = getStateClassNames("active", config.active);
            if (active_names.len > 0) {
                names = names ++ active_names ++ " ";
            }
        }

        // Responsive breakpoints with states
        if (@hasField(@TypeOf(config), "sm")) {
            const sm_config = config.sm;
            if (@hasField(@TypeOf(sm_config), "base")) {
                names = names ++ getBreakpointClassNames("sm", sm_config.base) ++ " ";
            }
            if (@hasField(@TypeOf(sm_config), "hover")) {
                names = names ++ getResponsiveStateClassNames("sm", "hover", sm_config.hover) ++ " ";
            }
            if (@hasField(@TypeOf(sm_config), "focus")) {
                names = names ++ getResponsiveStateClassNames("sm", "focus", sm_config.focus) ++ " ";
            }
            if (@hasField(@TypeOf(sm_config), "active")) {
                names = names ++ getResponsiveStateClassNames("sm", "active", sm_config.active) ++ " ";
            }
        }

        if (@hasField(@TypeOf(config), "md")) {
            const md_config = config.md;
            if (@hasField(@TypeOf(md_config), "base")) {
                names = names ++ getBreakpointClassNames("md", md_config.base) ++ " ";
            }
            if (@hasField(@TypeOf(md_config), "hover")) {
                names = names ++ getResponsiveStateClassNames("md", "hover", md_config.hover) ++ " ";
            }
            if (@hasField(@TypeOf(md_config), "focus")) {
                names = names ++ getResponsiveStateClassNames("md", "focus", md_config.focus) ++ " ";
            }
            if (@hasField(@TypeOf(md_config), "active")) {
                names = names ++ getResponsiveStateClassNames("md", "active", md_config.active) ++ " ";
            }
        }

        if (@hasField(@TypeOf(config), "lg")) {
            const lg_config = config.lg;
            if (@hasField(@TypeOf(lg_config), "base")) {
                names = names ++ getBreakpointClassNames("lg", lg_config.base) ++ " ";
            }
            if (@hasField(@TypeOf(lg_config), "hover")) {
                names = names ++ getResponsiveStateClassNames("lg", "hover", lg_config.hover) ++ " ";
            }
            if (@hasField(@TypeOf(lg_config), "focus")) {
                names = names ++ getResponsiveStateClassNames("lg", "focus", lg_config.focus) ++ " ";
            }
            if (@hasField(@TypeOf(lg_config), "active")) {
                names = names ++ getResponsiveStateClassNames("lg", "active", lg_config.active) ++ " ";
            }
        }

        // Remove trailing space
        return if (names.len > 0) names[0 .. names.len - 1] else "";
    }
}

/// Get class names for responsive state variants
fn getResponsiveStateClassNames(comptime bp: []const u8, comptime state: []const u8, comptime styles: anytype) []const u8 {
    comptime {
        var names: []const u8 = "";

        const T = @TypeOf(styles);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.fields) |field| {
                    const value = @field(styles, field.name);
                    const value_str = valueToString(value);
                    const variant = std.fmt.comptimePrint("{s}-{s}", .{ state, bp });
                    const name = std.fmt.comptimePrint("{s} ", .{atomicClassName(variant, field.name, value_str)});
                    names = names ++ name;
                }
            },
            else => {},
        }

        return if (names.len > 0) names[0 .. names.len - 1] else "";
    }
}

/// Create an interactive component with hover:, focus:, active: variants
///
/// Usage:
/// ```zig
/// const Button = mercss.InteractiveComponent(.{
///     .base = .{ .background = "#3b82f6" },
///     .hover = .{ .background = "#2563eb" },
///     .focus = .{ .box_shadow = "0 0 0 3px rgba(59,130,246,0.3)" },
///     .active = .{ .transform = "scale(0.98)" },
///     .sm = .{
///         .base = .{ .padding = "12px 24px" },
///         .hover = .{ .background = "#1d4ed8" },
///     },
/// });
/// ```
pub fn InteractiveComponent(comptime config: anytype) type {
    return struct {
        pub const css = safe_css ++ generateInteractiveCss(config);
        pub const classes = withSafeClassNames(getInteractiveClassNames(config));
    };
}

// Deprecated v0.2.5 demo declarations. Keep these aliases source-compatible
// until the documented 0.3.0 removal; new code should define app-owned tokens.
const legacy = @import("mercss_compat.zig").declarations(Component, ResponsiveComponent, InteractiveComponent);
pub const DesignSystem = legacy.DesignSystem;
pub const Button = legacy.Button;
pub const Card = legacy.Card;
pub const Alert = legacy.Alert;
pub const getDemoHtml = legacy.getDemoHtml;
pub const getAllCss = legacy.getAllCss;
pub const ResponsiveContainer = legacy.ResponsiveContainer;
pub const InteractiveButton = legacy.InteractiveButton;
pub const ResponsiveInteractiveButton = legacy.ResponsiveInteractiveButton;
pub const exampleUsage = legacy.exampleUsage;

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

const TestComponent = Component(.{
    .padding = "8px 16px",
    .border_radius = "6px",
    .width = 24,
});

const TestResponsiveComponent = ResponsiveComponent(.{
    .base = .{ .padding = "16px" },
    .sm = .{ .padding = "24px" },
    .md = .{ .padding = "32px" },
});

const TestInteractiveComponent = InteractiveComponent(.{
    .base = .{ .padding = "8px 16px", .background = "#3b82f6" },
    .hover = .{ .background = "#2563eb" },
    .focus = .{ .outline = "none" },
    .active = .{ .transform = "scale(0.98)" },
    .md = .{
        .base = .{ .padding = "16px 32px" },
        .hover = .{ .background = "#1e40af" },
    },
});

test "component CSS and class generation" {
    try testing.expect(std.mem.indexOf(u8, TestComponent.css, safe_css) != null);
    try testing.expect(std.mem.indexOf(u8, TestComponent.css, "padding:8px 16px;") != null);
    try testing.expect(std.mem.indexOf(u8, TestComponent.css, "border-radius:6px;") != null);
    try testing.expect(std.mem.indexOf(u8, TestComponent.classes, safe_class) != null);
}

test "kebab-case conversion" {
    comptime {
        try testing.expectEqualStrings("border-radius", toKebabCase("border_radius"));
        try testing.expectEqualStrings("background-color", toKebabCase("background_color"));
        try testing.expectEqualStrings("font-size", toKebabCase("font_size"));
    }
}

test "responsive component CSS and class generation" {
    comptime {
        @setEvalBranchQuota(50000);
        try testing.expect(std.mem.indexOf(u8, TestResponsiveComponent.css, "@media (min-width: 640px)") != null);
        try testing.expect(std.mem.indexOf(u8, TestResponsiveComponent.css, "@media (min-width: 768px)") != null);
        try testing.expect(std.mem.indexOf(u8, TestResponsiveComponent.css, "padding:24px;") != null);
        try testing.expect(std.mem.indexOf(u8, TestResponsiveComponent.classes, "mcss-sm-") != null);
        try testing.expect(std.mem.indexOf(u8, TestResponsiveComponent.classes, "mcss-md-") != null);
    }
}

test "interactive component preserves state and responsive variants" {
    comptime {
        @setEvalBranchQuota(100000);
        try testing.expect(std.mem.indexOf(u8, TestInteractiveComponent.css, ":hover{background:#2563eb;}") != null);
        try testing.expect(std.mem.indexOf(u8, TestInteractiveComponent.css, ":focus{outline:none;}") != null);
        try testing.expect(std.mem.indexOf(u8, TestInteractiveComponent.css, ":active{transform:scale(0.98);}") != null);
        try testing.expect(std.mem.indexOf(u8, TestInteractiveComponent.css, "@media (min-width: 768px)") != null);
        try testing.expect(std.mem.indexOf(u8, TestInteractiveComponent.css, ":hover{background:#1e40af;}") != null);
        try testing.expect(std.mem.indexOf(u8, TestInteractiveComponent.classes, "mcss-hover-md-") != null);
    }
}
