//! mercss.zig - Compile-time atomic CSS for merjs
//!
//! Inspired by Tailwind CSS but leveraging Zig's comptime:
//! - No build step (Zig IS the build)
//! - No purging (comptime knows all used styles)
//! - Type-safe design tokens
//! - Component-level style scoping

const std = @import("std");

/// Helper to generate CSS from style struct at comptime
fn generateCss(comptime styles: anytype) []const u8 {
    comptime {
        // Start with empty string
        var css: []const u8 = "";

        // Iterate over struct fields
        const T = @TypeOf(styles);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.fields) |field| {
                    const value = @field(styles, field.name);
                    const value_str = switch (@typeInfo(@TypeOf(value))) {
                        .@"enum" => @tagName(value),
                        .int, .comptime_int => std.fmt.comptimePrint("{d}px", .{value}),
                        else => value,
                    };

                    // Append CSS rule
                    const rule = std.fmt.comptimePrint(".mcss-{s}{{{s}:{s};}}", .{ field.name, field.name, value_str });
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
                    const name = std.fmt.comptimePrint("mcss-{s} ", .{field.name});
                    names = names ++ name;
                }
            },
            else => {},
        }

        // Remove trailing space
        return if (names.len > 0) names[0 .. names.len - 1] else "";
    }
}

/// Create a component with compile-time CSS
pub fn Component(comptime styles: anytype) type {
    return struct {
        pub const css = generateCss(styles);
        pub const classes = getClassNames(styles);
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
    // Should contain border_radius (field name becomes CSS property in this demo)
    try testing.expect(std.mem.indexOf(u8, Card.css, "border_radius") != null);
    // Should contain white background
    try testing.expect(std.mem.indexOf(u8, Card.css, "white") != null);
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
