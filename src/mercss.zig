//! mercss.zig - Compile-time atomic CSS for merjs
//!
//! Inspired by Tailwind CSS but leveraging Zig's comptime:
//! - No build step (Zig IS the build)
//! - No purging (comptime knows all used styles)
//! - Type-safe design tokens
//! - Component-level style scoping

const std = @import("std");

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

/// Stringify a style value at comptime.
///
/// - enums use their tag name (design-token enums),
/// - integers / floats become pixel values (`16` -> `16px`),
/// - everything else (string literals) is passed through verbatim.
fn styleValue(comptime value: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @tagName(value),
        .int, .comptime_int => std.fmt.comptimePrint("{d}px", .{value}),
        .float, .comptime_float => std.fmt.comptimePrint("{d}px", .{value}),
        else => value,
    };
}

/// Helper to generate CSS from style struct at comptime
fn generateCss(comptime styles: anytype) []const u8 {
    comptime {
        // Start with empty string
        var css: []const u8 = "";

        // Iterate over struct fields
        const T = @TypeOf(styles);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.field_names) |name| {
                    const value_str = styleValue(@field(styles, name));

                    // Convert property name to kebab-case for CSS
                    const css_property = toKebabCase(name);

                    // Append CSS rule
                    const rule = std.fmt.comptimePrint(".mcss-{s}{{{s}:{s};}}", .{ name, css_property, value_str });
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
                for (info.field_names) |field_name| {
                    const name = std.fmt.comptimePrint("mcss-{s} ", .{field_name});
                    names = names ++ name;
                }
            },
            else => {},
        }

        // Remove trailing space
        return if (names.len > 0) names[0 .. names.len - 1] else "";
    }
}

/// True when `config` uses the variant/responsive shape from yxlyx #92
/// (`.base`, `.sm`, `.hover`, `.dark`, …) rather than a flat style struct.
fn isVariantConfig(comptime config: anytype) bool {
    const T = @TypeOf(config);
    return @hasField(T, "base") or @hasField(T, "sm") or @hasField(T, "md") or
        @hasField(T, "lg") or @hasField(T, "xl") or @hasField(T, "xl2") or
        @hasField(T, "dark") or @hasField(T, "hover") or @hasField(T, "focus") or
        @hasField(T, "active");
}

/// Create a component with compile-time CSS.
///
/// Flat styles (existing API):
/// ```zig
/// const Button = mercss.Component(.{ .padding = "8px", .color = "white" });
/// ```
///
/// Variant config (yxlyx #92):
/// ```zig
/// const Button = mercss.Component(.{
///     .base = .{ .padding = "8px" },
///     .hover = .{ .background = "#2563eb" },
///     .dark = .{ .background = "#1e293b" },
/// });
/// ```
pub fn Component(comptime styles: anytype) type {
    if (comptime isVariantConfig(styles)) {
        return ResponsiveComponent(styles);
    }
    return struct {
        pub const css = generateCss(styles);
        pub const classes = getClassNames(styles);
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

        // Generate xl2 breakpoint (1536px+)
        if (@hasField(@TypeOf(config), "xl2")) {
            const xl2_css = generateBreakpointCss("xl2", config.xl2);
            css = css ++ "@media (min-width: 1536px){" ++ xl2_css ++ "}";
        }

        // Dark mode via prefers-color-scheme (yxlyx #92)
        if (@hasField(@TypeOf(config), "dark")) {
            const dark_css = generateBreakpointCss("dark", config.dark);
            if (dark_css.len > 0) {
                css = css ++ "@media (prefers-color-scheme: dark){" ++ dark_css ++ "}";
            }
        }

        // State variants — class is applied on the element, pseudo on the rule
        if (@hasField(@TypeOf(config), "hover")) {
            css = css ++ generateStateCss("hover", config.hover);
        }
        if (@hasField(@TypeOf(config), "focus")) {
            css = css ++ generateStateCss("focus", config.focus);
        }
        if (@hasField(@TypeOf(config), "active")) {
            css = css ++ generateStateCss("active", config.active);
        }

        return css;
    }
}

/// Generate `.mcss-{state}-{prop}:{state}{prop:val;}` rules for hover/focus/active.
fn generateStateCss(comptime state: []const u8, comptime styles: anytype) []const u8 {
    comptime {
        var css: []const u8 = "";

        const T = @TypeOf(styles);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.field_names) |name| {
                    const value_str = styleValue(@field(styles, name));
                    const css_property = toKebabCase(name);
                    const rule = std.fmt.comptimePrint(".mcss-{s}-{s}:{s}{{{s}:{s};}}", .{
                        state, name, state, css_property, value_str,
                    });
                    css = css ++ rule;
                }
            },
            else => {},
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
                for (info.field_names) |name| {
                    const value_str = styleValue(@field(styles, name));

                    const css_property = toKebabCase(name);

                    // Prefix class name with breakpoint
                    const rule = std.fmt.comptimePrint(".mcss-{s}-{s}{{{s}:{s};}}", .{ prefix, name, css_property, value_str });
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

        // xl2 classes
        if (@hasField(@TypeOf(config), "xl2")) {
            const xl2_names = getBreakpointClassNames("xl2", config.xl2);
            names = names ++ xl2_names ++ " ";
        }

        if (@hasField(@TypeOf(config), "dark")) {
            const dark_names = getBreakpointClassNames("dark", config.dark);
            names = names ++ dark_names ++ " ";
        }
        if (@hasField(@TypeOf(config), "hover")) {
            const hover_names = getBreakpointClassNames("hover", config.hover);
            names = names ++ hover_names ++ " ";
        }
        if (@hasField(@TypeOf(config), "focus")) {
            const focus_names = getBreakpointClassNames("focus", config.focus);
            names = names ++ focus_names ++ " ";
        }
        if (@hasField(@TypeOf(config), "active")) {
            const active_names = getBreakpointClassNames("active", config.active);
            names = names ++ active_names ++ " ";
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
                for (info.field_names) |field_name| {
                    const name = std.fmt.comptimePrint("mcss-{s}-{s} ", .{ prefix, field_name });
                    names = names ++ name;
                }
            },
            else => {},
        }

        // Remove trailing space
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
        pub const css = generateResponsiveCss(config);
        pub const classes = getResponsiveClassNames(config);
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// HASHED (CONTENT-ADDRESSED) ATOMIC CLASSES — shorter, deduplicated class names
// ═══════════════════════════════════════════════════════════════════════════════
//
// The default `Component` emits readable `.mcss-<property>` class names. For pages
// with many components those names get long and repeat the same atomic rule (e.g.
// two components both setting `background:#3b82f6` each ship a `.mcss-background`
// rule). `HashedComponent` instead derives a short, stable class name from the
// *content* of each atomic rule (`property:value`). Identical property/value pairs
// therefore collapse onto the same class name across components — true atomic CSS
// deduplication — while class names stay short (e.g. `.mc-1a2b3c`).
//
// This is opt-in: existing pages keep the stable, human-readable `mcss-*` names.

/// FNV-1a 32-bit hash of a byte string, evaluated at comptime.
fn fnv1a(comptime s: []const u8) u32 {
    comptime {
        var h: u32 = 2166136261;
        for (s) |c| {
            h ^= c;
            h *%= 16777619;
        }
        return h;
    }
}

/// Encode an unsigned integer as lowercase base36 (`0-9a-z`) at comptime.
fn base36(comptime n: u32) []const u8 {
    comptime {
        if (n == 0) return "0";
        const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
        var buf: [7]u8 = undefined; // ceil(log36(2^32)) == 7
        var i: usize = buf.len;
        var v: u32 = n;
        while (v > 0) {
            i -= 1;
            buf[i] = digits[v % 36];
            v /= 36;
        }
        return buf[i..];
    }
}

/// Content-addressed atomic class name for a `property:value` pair.
/// The same pair always yields the same class, enabling cross-component dedup.
fn atomicClass(comptime property: []const u8, comptime value: []const u8) []const u8 {
    return "mc-" ++ base36(fnv1a(property ++ ":" ++ value));
}

/// Generate hashed atomic CSS from a flat style struct at comptime.
fn generateHashedCss(comptime styles: anytype) []const u8 {
    comptime {
        var css: []const u8 = "";
        switch (@typeInfo(@TypeOf(styles))) {
            .@"struct" => |info| {
                for (info.field_names) |name| {
                    const value_str = styleValue(@field(styles, name));
                    const property = toKebabCase(name);
                    const cls = atomicClass(property, value_str);
                    css = css ++ "." ++ cls ++ "{" ++ property ++ ":" ++ value_str ++ ";}";
                }
            },
            else => {},
        }
        return css;
    }
}

/// Collect hashed atomic class names from a flat style struct at comptime.
fn getHashedClassNames(comptime styles: anytype) []const u8 {
    comptime {
        var names: []const u8 = "";
        switch (@typeInfo(@TypeOf(styles))) {
            .@"struct" => |info| {
                for (info.field_names) |name| {
                    const value_str = styleValue(@field(styles, name));
                    const property = toKebabCase(name);
                    names = names ++ atomicClass(property, value_str) ++ " ";
                }
            },
            else => {},
        }
        return if (names.len > 0) names[0 .. names.len - 1] else "";
    }
}

/// Create a component with short, content-addressed atomic class names.
///
/// Usage:
/// ```zig
/// const Button = mercss.HashedComponent(.{
///     .background = "#3b82f6",
///     .border_radius = "6px",
/// });
/// // Button.css     == ".mc-<hash>{background:#3b82f6;}.mc-<hash>{border-radius:6px;}"
/// // Button.classes == "mc-<hash> mc-<hash>"
/// ```
///
/// Class names are derived from `property:value`, so identical atomic rules
/// across components share one class name (and one rule when de-duplicated).
pub fn HashedComponent(comptime styles: anytype) type {
    return struct {
        pub const css = generateHashedCss(styles);
        pub const classes = getHashedClassNames(styles);
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
    try testing.expect(std.mem.indexOf(u8, Button.classes, "mcss-padding") != null);
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
    // Should contain media queries
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "@media") != null);
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "min-width") != null);

    // Should contain breakpoint classes
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "mcss-sm-") != null);
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "mcss-md-") != null);
}

test "Responsive component class names" {
    // Should contain base class
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.classes, "mcss-padding") != null);

    // Should contain breakpoint classes
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.classes, "mcss-sm-padding") != null);
    try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.classes, "mcss-md-padding") != null);
}

test "Responsive breakpoints structure" {
    comptime {
        // Raise branch quota for complex comptime string operations
        @setEvalBranchQuota(5000);

        // Base style should exist
        try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, ".mcss-padding{padding:16px;}") != null);

        // sm breakpoint (640px+)
        try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "@media (min-width: 640px)") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, ".mcss-sm-padding{padding:24px;}") != null);

        // md breakpoint (768px+)
        try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, "@media (min-width: 768px)") != null);
        try testing.expect(std.mem.indexOf(u8, ResponsiveContainer.css, ".mcss-md-padding{padding:32px;}") != null);
    }
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

/// Combine multiple components into one stylesheet (yxlyx #92).
pub fn generateStylesheet(comptime components: anytype) []const u8 {
    comptime {
        var result: []const u8 = "/* mercss generated stylesheet */\n";
        const T = @TypeOf(components);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.field_names) |name| {
                    const comp = @field(components, name);
                    result = result ++ "/* " ++ name ++ " */\n" ++ comp.css ++ "\n";
                }
            },
            else => {},
        }
        return result;
    }
}

/// Collect class names from multiple components (yxlyx #92).
pub fn getAllClasses(comptime components: anytype) []const u8 {
    comptime {
        var result: []const u8 = "";
        const T = @TypeOf(components);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.field_names) |name| {
                    const comp = @field(components, name);
                    if (comp.classes.len > 0) {
                        result = result ++ comp.classes ++ " ";
                    }
                }
            },
            else => {},
        }
        return if (result.len > 0) result[0 .. result.len - 1] else "";
    }
}

test "Component variant config: hover and dark" {
    comptime {
        @setEvalBranchQuota(8000);
        const Interactive = Component(.{
            .base = .{ .background = "#3b82f6" },
            .hover = .{ .background = "#2563eb" },
            .dark = .{ .background = "#1e293b", .color = "white" },
        });
        try testing.expect(std.mem.indexOf(u8, Interactive.css, ":hover") != null);
        try testing.expect(std.mem.indexOf(u8, Interactive.css, "prefers-color-scheme: dark") != null);
        try testing.expect(std.mem.indexOf(u8, Interactive.classes, "mcss-hover-background") != null);
        try testing.expect(std.mem.indexOf(u8, Interactive.classes, "mcss-dark-background") != null);
    }
}

test "Responsive component xl2 breakpoint" {
    comptime {
        @setEvalBranchQuota(8000);
        const Wide = ResponsiveComponent(.{
            .base = .{ .padding = "8px" },
            .xl2 = .{ .padding = "64px" },
        });
        try testing.expect(std.mem.indexOf(u8, Wide.css, "1536px") != null);
        try testing.expect(std.mem.indexOf(u8, Wide.classes, "mcss-xl2-padding") != null);
    }
}

test "generateStylesheet and getAllClasses" {
    comptime {
        const sheet = generateStylesheet(.{
            .button = Button,
            .card = Card,
        });
        try testing.expect(std.mem.indexOf(u8, sheet, "/* button */") != null);
        try testing.expect(std.mem.indexOf(u8, sheet, "/* card */") != null);
        const classes = getAllClasses(.{ .button = Button, .card = Card });
        try testing.expect(classes.len > 0);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TAILWIND-PARITY OUTPUT TESTS (#91) — assert exact generated CSS strings
// ═══════════════════════════════════════════════════════════════════════════════

test "#91.1 property-name mapping: snake_case field -> kebab-case CSS property" {
    comptime {
        // `border_radius` field must render as the `border-radius` CSS property,
        // exactly, in the generated rule.
        const Boxy = Component(.{ .border_radius = "6px", .background_color = "#fff" });
        try testing.expectEqualStrings(
            ".mcss-border_radius{border-radius:6px;}.mcss-background_color{background-color:#fff;}",
            Boxy.css,
        );
    }
}

test "#91.1 integer/float values become pixels via kebab property" {
    comptime {
        const Spaced = Component(.{ .margin_top = 12, .line_height = 1.5 });
        try testing.expect(std.mem.indexOf(u8, Spaced.css, "margin-top:12px;") != null);
        try testing.expect(std.mem.indexOf(u8, Spaced.css, "line-height:1.5px;") != null);
    }
}

test "#91.2 responsive prefix -> @media (min-width) block with kebab property" {
    comptime {
        @setEvalBranchQuota(8000);
        const Box = ResponsiveComponent(.{
            .base = .{ .padding = "8px" },
            .md = .{ .font_size = "18px" },
        });
        // base rule lives outside any media query
        try testing.expect(std.mem.indexOf(u8, Box.css, ".mcss-padding{padding:8px;}") != null);
        // md variant is wrapped in a min-width media query and uses kebab property
        try testing.expect(std.mem.indexOf(
            u8,
            Box.css,
            "@media (min-width: 768px){.mcss-md-font_size{font-size:18px;}}",
        ) != null);
    }
}

test "#91.3 state variant -> .cls:hover / :focus / :active selectors" {
    comptime {
        @setEvalBranchQuota(8000);
        const Btn = Component(.{
            .base = .{ .background = "#3b82f6" },
            .hover = .{ .background_color = "#2563eb" },
            .focus = .{ .outline = "2px solid #93c5fd" },
            .active = .{ .background = "#1d4ed8" },
        });
        try testing.expect(std.mem.indexOf(
            u8,
            Btn.css,
            ".mcss-hover-background_color:hover{background-color:#2563eb;}",
        ) != null);
        try testing.expect(std.mem.indexOf(u8, Btn.css, ".mcss-focus-outline:focus{") != null);
        try testing.expect(std.mem.indexOf(u8, Btn.css, ".mcss-active-background:active{") != null);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// HASHED CLASS-NAME TESTS (#91.4)
// ═══════════════════════════════════════════════════════════════════════════════

test "#91.4 hashed component emits short mc- classes with kebab properties" {
    comptime {
        const Btn = HashedComponent(.{ .background = "#3b82f6", .border_radius = "6px" });
        // Short, content-addressed class prefix
        try testing.expect(std.mem.indexOf(u8, Btn.classes, "mc-") != null);
        try testing.expect(std.mem.indexOf(u8, Btn.classes, "mcss-") == null);
        // Rules still use kebab-case CSS properties
        try testing.expect(std.mem.indexOf(u8, Btn.css, "border-radius:6px;") != null);
        try testing.expect(std.mem.indexOf(u8, Btn.css, "background:#3b82f6;") != null);
        // Hashed names are shorter than the readable equivalent for multi-word props
        try testing.expect(std.mem.indexOf(u8, Btn.classes, "mc-").? == 0);
    }
}

test "#91.4 identical property:value pairs collapse onto one hashed class" {
    comptime {
        // Same atomic rule in two different components -> same class name (dedup).
        const A = HashedComponent(.{ .background = "#3b82f6", .padding = "8px" });
        const B = HashedComponent(.{ .background = "#3b82f6", .color = "white" });
        const a_bg = atomicClass("background", "#3b82f6");
        try testing.expect(std.mem.indexOf(u8, A.classes, a_bg) != null);
        try testing.expect(std.mem.indexOf(u8, B.classes, a_bg) != null);
        // Different value -> different class
        const other = atomicClass("background", "#ef4444");
        try testing.expect(!std.mem.eql(u8, a_bg, other));
    }
}

test "#91.4 base36 / fnv1a hashing sanity" {
    comptime {
        try testing.expectEqualStrings("0", base36(0));
        try testing.expectEqualStrings("z", base36(35));
        try testing.expectEqualStrings("10", base36(36));
        // Deterministic and collision-stable for the two sample inputs
        try testing.expect(fnv1a("background:#3b82f6") != fnv1a("background:#ef4444"));
    }
}
