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

// ═══════════════════════════════════════════════════════════════════════════════
// DEMO: Design System & Components
// ═══════════════════════════════════════════════════════════════════════════════

pub const DesignSystem = struct {
    pub const colors = .{
        .primary = "#3b82f6",
        .secondary = "#64748b",
        .danger = "#ef4444",
        .success = "#22c55e",
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
pub const Button = Component(.{
    .padding = "8px 16px",
    .border_radius = "6px",
    .font_weight = "600",
    .cursor = "pointer",
    .transition = "all 0.2s",
    .background = DesignSystem.colors.primary,
});

/// Card component
pub const Card = Component(.{
    .background = "white",
    .border_radius = "8px",
    .padding = "16px",
    .box_shadow = "0 1px 3px rgba(0,0,0,0.1)",
});

/// Alert component
pub const Alert = Component(.{
    .padding = "12px 16px",
    .border_radius = "6px",
    .font_weight = "500",
    .background = DesignSystem.colors.danger,
});

/// Demo: Generate complete HTML page with inline CSS
pub fn getDemoHtml() []const u8 {
    comptime {
        return "<!DOCTYPE html><html><head><style>" ++
            Button.css ++
            Card.css ++
            Alert.css ++
            "</style></head><body>" ++
            "<button class='" ++ Button.classes ++ "'>Click me</button>" ++
            "<div class='" ++ Card.classes ++ "'>Card content here</div>" ++
            "<div class='" ++ Alert.classes ++ "'>Alert message!</div>" ++
            "</body></html>";
    }
}

/// Get just the CSS for all components
pub fn getAllCss() []const u8 {
    comptime {
        return Button.css ++ Card.css ++ Alert.css;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "Button CSS generation" {
    // Should contain padding rule
    try testing.expect(std.mem.indexOf(u8, Button.css, "padding") != null);
    // Should contain primary color
    try testing.expect(std.mem.indexOf(u8, Button.css, "#3b82f6") != null);
}

test "Card CSS generation" {
    // Should contain border-radius (kebab-case conversion)
    try testing.expect(std.mem.indexOf(u8, Card.css, "border-radius") != null);
    // Should contain white background
    try testing.expect(std.mem.indexOf(u8, Card.css, "white") != null);
}

test "kebab-case conversion" {
    // Test snake_case to kebab-case conversion
    comptime {
        try testing.expectEqualStrings("border-radius", toKebabCase("border_radius"));
        try testing.expectEqualStrings("background-color", toKebabCase("background_color"));
        try testing.expectEqualStrings("font-size", toKebabCase("font_size"));
    }
}

test "Button class names" {
    // Should have mcss- prefix
    try testing.expect(std.mem.indexOf(u8, Button.classes, "mcss-") != null);
    // Should contain padding class
    try testing.expect(std.mem.indexOf(u8, Button.classes, "mcss-padding-") != null);
}

test "components include safe boundary class" {
    try testing.expect(std.mem.indexOf(u8, Button.classes, safe_class) != null);
    try testing.expect(std.mem.indexOf(u8, Button.css, safe_css) != null);
}

test "different values generate different classes" {
    const rounded = Component(.{ .border_radius = "4px" });
    const pill = Component(.{ .border_radius = "9999px" });

    try testing.expect(!std.mem.eql(u8, rounded.classes, pill.classes));
    try testing.expect(std.mem.indexOf(u8, rounded.css, "border-radius:4px;") != null);
    try testing.expect(std.mem.indexOf(u8, pill.css, "border-radius:9999px;") != null);
}

test "Complete HTML generation" {
    const html = comptime getDemoHtml();

    // Has all structure
    try testing.expect(std.mem.indexOf(u8, html, "<!DOCTYPE html>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<style>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "</style>") != null);

    // Has components
    try testing.expect(std.mem.indexOf(u8, html, "<button") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<div") != null);

    // Has CSS rules
    try testing.expect(std.mem.indexOf(u8, html, "mcss-") != null);
}

test "CSS deduplication concept" {
    // In real usage, you'd only include each component's CSS once
    // This test shows the CSS strings are compile-time constants
    const css1 = Button.css;
    const css2 = Button.css;

    // Both point to same comptime-generated string
    try testing.expect(css1.len == css2.len);
    try testing.expect(std.mem.eql(u8, css1, css2));
}

// ═══════════════════════════════════════════════════════════════════════════════
// RESPONSIVE COMPONENT TESTS
// ═══════════════════════════════════════════════════════════════════════════════

/// Demo: Responsive container component
pub const ResponsiveContainer = ResponsiveComponent(.{
    .base = .{ .padding = "16px" },
    .sm = .{ .padding = "24px" },
    .md = .{ .padding = "32px" },
    .lg = .{ .padding = "48px" },
});

test "Responsive component CSS generation" {
    comptime {
        @setEvalBranchQuota(50000);
    }

    // Should contain media queries
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "@media") != null);
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "min-width") != null);

    // Should contain breakpoint classes
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "mcss-sm-") != null);
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "mcss-md-") != null);
}

test "Responsive component class names" {
    comptime {
        @setEvalBranchQuota(50000);
    }

    // Should contain base class
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.classes, "mcss-padding-") != null);

    // Should contain breakpoint classes
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.classes, "mcss-sm-padding-") != null);
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.classes, "mcss-md-padding-") != null);
}

test "Responsive breakpoints structure" {
    comptime {
        // Raise branch quota for complex comptime string operations
        @setEvalBranchQuota(5000);

        // Base style should exist
        try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, ".mcss-padding-") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "padding:16px;}") != null);

        // sm breakpoint (640px+)
        try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "@media (min-width: 640px)") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, ".mcss-sm-padding-") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "padding:24px;}") != null);

        // md breakpoint (768px+)
        try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "@media (min-width: 768px)") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, ".mcss-md-padding-") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "padding:32px;}") != null);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// INTERACTIVE COMPONENT TESTS
// ═══════════════════════════════════════════════════════════════════════════════

/// Demo: Interactive button with hover, focus, and active states
pub const InteractiveButton = InteractiveComponent(.{
    .base = .{
        .padding = "12px 24px",
        .background = "#3b82f6",
        .color = "white",
        .border_radius = "6px",
        .cursor = "pointer",
        .transition = "all 0.2s",
    },
    .hover = .{
        .background = "#2563eb",
        .transform = "translateY(-1px)",
    },
    .focus = .{
        .box_shadow = "0 0 0 3px rgba(59,130,246,0.3)",
        .outline = "none",
    },
    .active = .{
        .transform = "scale(0.98)",
        .background = "#1d4ed8",
    },
});

test "Interactive component CSS generation" {
    comptime {
        @setEvalBranchQuota(100000);

        // Base styles
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ".mcss-padding-") != null);
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, "padding:12px 24px;}") != null);
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ".mcss-background-") != null);
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, "background:#3b82f6;}") != null);

        // Hover pseudo-class
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ".mcss-hover-background-") != null);
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ":hover{background:#2563eb;}") != null);
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ".mcss-hover-transform-") != null);
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ":hover{transform:translateY(-1px);}") != null);

        // Focus pseudo-class
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ".mcss-focus-box_shadow-") != null);
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ":focus{box-shadow:") != null);
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ".mcss-focus-outline-") != null);
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ":focus{outline:none;}") != null);

        // Active pseudo-class
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ".mcss-active-transform-") != null);
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ":active{transform:scale(0.98);}") != null);
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ".mcss-active-background-") != null);
        try testing.expect(std.mem.indexOf(u8, InteractiveButton.css, ":active{background:#1d4ed8;}") != null);
    }
}

test "Interactive component class names" {
    comptime {
        @setEvalBranchQuota(50000);
    }

    // Should contain base classes
    try testing.expect(std.mem.indexOf(u8, InteractiveButton.classes, "mcss-padding-") != null);
    try testing.expect(std.mem.indexOf(u8, InteractiveButton.classes, "mcss-background-") != null);

    // Should contain hover classes
    try testing.expect(std.mem.indexOf(u8, InteractiveButton.classes, "mcss-hover-background-") != null);
    try testing.expect(std.mem.indexOf(u8, InteractiveButton.classes, "mcss-hover-transform-") != null);

    // Should contain focus classes
    try testing.expect(std.mem.indexOf(u8, InteractiveButton.classes, "mcss-focus-box_shadow-") != null);

    // Should contain active classes
    try testing.expect(std.mem.indexOf(u8, InteractiveButton.classes, "mcss-active-transform-") != null);
}

/// Demo: Interactive component with responsive state variants
pub const ResponsiveInteractiveButton = InteractiveComponent(.{
    .base = .{
        .padding = "8px 16px",
        .background = "#3b82f6",
    },
    .hover = .{
        .background = "#2563eb",
    },
    .sm = .{
        .base = .{ .padding = "12px 24px" },
        .hover = .{ .background = "#1d4ed8" },
    },
    .md = .{
        .base = .{ .padding = "16px 32px" },
        .hover = .{ .background = "#1e40af" },
    },
});

test "Responsive interactive component" {
    comptime {
        @setEvalBranchQuota(100000);

        // Base styles
        try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.css, ".mcss-padding-") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.css, "padding:8px 16px;}") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.css, ".mcss-hover-background-") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.css, ":hover{background:#2563eb;}") != null);

        // sm breakpoint with hover
        try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.css, "@media (min-width: 640px)") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.css, ".mcss-hover-sm-background-") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.css, ":hover{background:#1d4ed8;}") != null);

        // md breakpoint with hover
        try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.css, "@media (min-width: 768px)") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.css, ".mcss-hover-md-background-") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.css, ":hover{background:#1e40af;}") != null);
    }
}

test "Responsive interactive class names" {
    comptime {
        @setEvalBranchQuota(50000);
    }

    // Base classes
    try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.classes, "mcss-padding-") != null);
    try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.classes, "mcss-hover-background-") != null);

    // Responsive hover classes
    try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.classes, "mcss-hover-sm-background-") != null);
    try testing.expect(std.mem.indexOf(u8, ResponsiveInteractiveButton.classes, "mcss-hover-md-background-") != null);
}

// ═══════════════════════════════════════════════════════════════════════════════
// EXAMPLE: How this would work in a real page
// ═══════════════════════════════════════════════════════════════════════════════

pub fn exampleUsage() void {
    // In a real page handler:
    //
    // pub fn render(req: mer.Request) mer.Response {
    //     // CSS is generated at comptime - zero runtime cost!
    //     const css = Button.css ++ Card.css;
    //
    //     return mer.html(
    //         "<style>" ++ css ++ "</style>" ++
    //         "<button class='" ++ Button.classes ++ "'>Click</button>"
    //     );
    // }
    _ = {};
}
