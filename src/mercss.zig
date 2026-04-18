//! mercss.zig - Compile-time atomic CSS for merjs
//!
//! Tailwind-compatible utility-first CSS system leveraging Zig's comptime:
//! - Responsive prefixes (sm:, md:, lg:, xl:)
//! - State variants (hover:, focus:, active:)
//! - Dark mode (dark: prefix)
//! - Hash-based short class names
//! - Type-safe design tokens
//! - Zero runtime cost

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════════
// HASHING - Short class name generation
// ═══════════════════════════════════════════════════════════════════════════════

/// FNV-1a 32-bit hash for comptime class name generation
fn fnv1a32(comptime data: []const u8) u32 {
    comptime {
        var hash: u32 = 2166136261;
        const prime: u32 = 16777619;
        for (data) |byte| {
            hash ^= byte;
            hash = hash *% prime;
        }
        return hash;
    }
}

/// Base62 character set for short class names
const base62_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

/// Convert a hash to a short base62 string at comptime
fn hashToShortName(comptime hash: u32) [6]u8 {
    comptime {
        var buf: [6]u8 = undefined;
        var h = hash;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            buf[i] = base62_chars[h % 62];
            h /= 62;
        }
        return buf;
    }
}

/// Generate a short hash-based class name
fn shortClassName(comptime prefix: []const u8, comptime prop: []const u8, comptime val: []const u8) [7]u8 {
    comptime {
        const input = prefix ++ "-" ++ prop ++ "-" ++ val;
        const hash = fnv1a32(input);
        const short = hashToShortName(hash);
        var result: [7]u8 = undefined;
        result[0] = 'm';
        for (short, 0..) |c, i| {
            result[i + 1] = c;
        }
        return result;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PROPERTY CONVERSION
// ═══════════════════════════════════════════════════════════════════════════════

/// Convert snake_case to kebab-case at comptime
fn toKebabCase(comptime str: []const u8) []const u8 {
    comptime {
        var count: usize = 0;
        for (str) |c| {
            if (c == '_') count += 1;
        }
        var result: [str.len]u8 = undefined;
        var j: usize = 0;
        for (str) |c| {
            if (c == '_') {
                result[j] = '-';
            } else {
                result[j] = c;
            }
            j += 1;
        }
        return result[0..str.len];
    }
}

/// Convert a CSS property value to a string representation
fn valueToString(comptime value: anytype) []const u8 {
    comptime {
        const T = @TypeOf(value);
        return switch (@typeInfo(T)) {
            .@"enum" => @tagName(value),
            .int, .comptime_int => std.fmt.comptimePrint("{d}px", .{value}),
            .float, .comptime_float => std.fmt.comptimePrint("{d}px", .{value}),
            .bool => if (value) "1" else "0",
            .pointer => value,
            .array => &value,
            else => std.fmt.comptimePrint("{any}", .{value}),
        };
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// CSS GENERATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Generate CSS rules from a style struct
fn generateStyleBlock(comptime prefix: []const u8, comptime styles: anytype) []const u8 {
    comptime {
        var result: []const u8 = "";
        const T = @TypeOf(styles);
        const info = @typeInfo(T);

        if (info != .@"struct") return result;
        const struct_info = info.@"struct";

        for (struct_info.fields) |field| {
            const value = @field(styles, field.name);
            const value_str = valueToString(value);
            const css_prop = toKebabCase(field.name);
            const short_name_arr = shortClassName(prefix, field.name, value_str);
            const short_name = short_name_arr[0..];

            const rule = std.fmt.comptimePrint(".{s}{{{s}:{s};}}", .{ short_name, css_prop, value_str });
            result = result ++ rule;
        }

        return result;
    }
}

/// Generate a media query block for responsive styles
fn generateMediaQuery(comptime min_width: []const u8, comptime bp: []const u8, comptime styles: anytype) []const u8 {
    comptime {
        const T = @TypeOf(styles);
        const info = @typeInfo(T);

        if (info != .@"struct") return "";
        const struct_info = info.@"struct";
        if (struct_info.fields.len == 0) return "";

        const inner = generateStyleBlock(bp, styles);
        if (inner.len == 0) return "";

        return std.fmt.comptimePrint("@media(min-width:{s}){{{s}}}", .{ min_width, inner });
    }
}

/// Generate dark mode styles
fn generateDarkStyles(comptime styles: anytype) []const u8 {
    comptime {
        const T = @TypeOf(styles);
        const info = @typeInfo(T);

        if (info != .@"struct") return "";
        const struct_info = info.@"struct";
        if (struct_info.fields.len == 0) return "";

        const inner = generateStyleBlock("dark", styles);
        if (inner.len == 0) return "";

        return std.fmt.comptimePrint("@media(prefers-color-scheme:dark){{{s}}}", .{inner});
    }
}

/// Generate state variant styles
fn generateStateStyles(comptime state: []const u8, comptime styles: anytype) []const u8 {
    comptime {
        const T = @TypeOf(styles);
        const info = @typeInfo(T);

        if (info != .@"struct") return "";
        const struct_info = info.@"struct";
        if (struct_info.fields.len == 0) return "";

        const inner = generateStyleBlock(state, styles);
        if (inner.len == 0) return "";

        return std.fmt.comptimePrint(".{s}\\:{s}{{{s}}}", .{ state, inner, inner });
    }
}

/// Collect class names from styles
fn collectClassNames(comptime prefix: []const u8, comptime styles: anytype) []const u8 {
    comptime {
        var result: []const u8 = "";
        const T = @TypeOf(styles);
        const info = @typeInfo(T);

        if (info != .@"struct") return result;
        const struct_info = info.@"struct";

        for (struct_info.fields) |field| {
            const value = @field(styles, field.name);
            const value_str = valueToString(value);
            const short_name_arr = shortClassName(prefix, field.name, value_str);
            const short_name = short_name_arr[0..];

            result = result ++ short_name ++ " ";
        }

        return result;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// COMPONENT BUILDER
// ═══════════════════════════════════════════════════════════════════════════════

/// Create a reusable component with compile-time styles
pub fn Component(comptime config: anytype) type {
    return struct {
        pub const css = blk: {
            var result: []const u8 = "";
            if (@hasField(@TypeOf(config), "base")) result = result ++ generateStyleBlock("", config.base);
            if (@hasField(@TypeOf(config), "sm")) result = result ++ generateMediaQuery("640px", "sm", config.sm);
            if (@hasField(@TypeOf(config), "md")) result = result ++ generateMediaQuery("768px", "md", config.md);
            if (@hasField(@TypeOf(config), "lg")) result = result ++ generateMediaQuery("1024px", "lg", config.lg);
            if (@hasField(@TypeOf(config), "xl")) result = result ++ generateMediaQuery("1280px", "xl", config.xl);
            if (@hasField(@TypeOf(config), "xl2")) result = result ++ generateMediaQuery("1536px", "xl2", config.xl2);
            if (@hasField(@TypeOf(config), "dark")) result = result ++ generateDarkStyles(config.dark);
            if (@hasField(@TypeOf(config), "hover")) result = result ++ generateStateStyles("hover", config.hover);
            if (@hasField(@TypeOf(config), "focus")) result = result ++ generateStateStyles("focus", config.focus);
            if (@hasField(@TypeOf(config), "active")) result = result ++ generateStateStyles("active", config.active);
            break :blk result;
        };

        pub const classes = blk: {
            var result: []const u8 = "";
            if (@hasField(@TypeOf(config), "base")) result = result ++ collectClassNames("", config.base);
            if (@hasField(@TypeOf(config), "sm")) result = result ++ collectClassNames("sm", config.sm);
            if (@hasField(@TypeOf(config), "md")) result = result ++ collectClassNames("md", config.md);
            if (@hasField(@TypeOf(config), "lg")) result = result ++ collectClassNames("lg", config.lg);
            if (@hasField(@TypeOf(config), "xl")) result = result ++ collectClassNames("xl", config.xl);
            if (@hasField(@TypeOf(config), "xl2")) result = result ++ collectClassNames("xl2", config.xl2);
            if (@hasField(@TypeOf(config), "dark")) result = result ++ collectClassNames("dark", config.dark);
            if (@hasField(@TypeOf(config), "hover")) result = result ++ collectClassNames("hover", config.hover);
            if (@hasField(@TypeOf(config), "focus")) result = result ++ collectClassNames("focus", config.focus);
            if (@hasField(@TypeOf(config), "active")) result = result ++ collectClassNames("active", config.active);
            break :blk result;
        };
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// UTILITY FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Generate a complete stylesheet from multiple components
pub fn generateStylesheet(comptime components: anytype) []const u8 {
    comptime {
        var result: []const u8 = "/* mercss generated stylesheet */\n";
        const T = @TypeOf(components);
        const info = @typeInfo(T);

        if (info != .@"struct") return result;
        const struct_info = info.@"struct";

        for (struct_info.fields) |field| {
            const comp = @field(components, field.name);
            result = result ++ "/* " ++ field.name ++ " */\n" ++ comp.css ++ "\n";
        }

        return result;
    }
}

/// Get all class names from multiple components
pub fn getAllClasses(comptime components: anytype) []const u8 {
    comptime {
        var result: []const u8 = "";
        const T = @TypeOf(components);
        const info = @typeInfo(T);

        if (info != .@"struct") return result;
        const struct_info = info.@"struct";

        for (struct_info.fields) |field| {
            const comp = @field(components, field.name);
            if (comp.classes.len > 0) {
                result = result ++ comp.classes ++ " ";
            }
        }

        if (result.len > 0 and result[result.len - 1] == ' ') {
            result = result[0 .. result.len - 1];
        }

        return result;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "toKebabCase: basic conversion" {
    comptime {
        if (!std.mem.eql(u8, toKebabCase("border_radius"), "border-radius")) @compileError("border_radius failed");
        if (!std.mem.eql(u8, toKebabCase("background_color"), "background-color")) @compileError("background_color failed");
        if (!std.mem.eql(u8, toKebabCase("font_size"), "font-size")) @compileError("font_size failed");
    }
}

test "toKebabCase: no underscores" {
    comptime {
        if (!std.mem.eql(u8, toKebabCase("color"), "color")) @compileError("color failed");
        if (!std.mem.eql(u8, toKebabCase("padding"), "padding")) @compileError("padding failed");
    }
}

test "toKebabCase: empty string" {
    comptime {
        if (!std.mem.eql(u8, toKebabCase(""), "")) @compileError("empty failed");
    }
}

test "hashToShortName: deterministic output" {
    comptime {
        const hash1 = fnv1a32("test-input");
        const hash2 = fnv1a32("test-input");
        if (hash1 != hash2) @compileError("hashes not equal");

        const name1 = hashToShortName(hash1);
        const name2 = hashToShortName(hash2);
        if (!std.mem.eql(u8, &name1, &name2)) @compileError("names not equal");
    }
}

test "hashToShortName: different inputs produce different hashes" {
    comptime {
        const hash1 = fnv1a32("input-a");
        const hash2 = fnv1a32("input-b");
        if (hash1 == hash2) @compileError("hashes should differ");
    }
}

test "shortClassName: generates short names" {
    comptime {
        const name = shortClassName("", "padding", "16px");
        if (name[0] != 'm') @compileError("name should start with m");
    }
}

test "Component: creates reusable styled component" {
    comptime {
        const Button = Component(.{
            .base = .{
                .padding = "8px 16px",
                .background = "#3b82f6",
                .color = "white",
                .border_radius = "6px",
            },
        });

        if (Button.css.len == 0) @compileError("css empty");
        if (Button.classes.len == 0) @compileError("classes empty");
        if (std.mem.indexOf(u8, Button.css, "padding") == null) @compileError("no padding");
        if (std.mem.indexOf(u8, Button.css, "background") == null) @compileError("no background");
    }
}

test "Component: responsive breakpoints" {
    comptime {
        const Card = Component(.{
            .base = .{ .padding = "16px" },
            .md = .{ .padding = "32px" },
            .lg = .{ .padding = "48px" },
        });

        if (std.mem.indexOf(u8, Card.css, "@media") == null) @compileError("no media query");
        if (std.mem.indexOf(u8, Card.css, "768px") == null) @compileError("no 768px");
        if (std.mem.indexOf(u8, Card.css, "1024px") == null) @compileError("no 1024px");
    }
}

test "Component: dark mode styles" {
    comptime {
        const Theme = Component(.{
            .base = .{ .background = "white", .color = "black" },
            .dark = .{ .background = "#1a1a2e", .color = "white" },
        });

        if (std.mem.indexOf(u8, Theme.css, "prefers-color-scheme:dark") == null) @compileError("no dark mode");
    }
}

test "Component: hover state styles" {
    comptime {
        const Button = Component(.{
            .base = .{ .background = "#3b82f6" },
            .hover = .{ .background = "#2563eb" },
        });

        if (std.mem.indexOf(u8, Button.css, "hover") == null) @compileError("no hover");
    }
}

test "generateStylesheet: combines multiple components" {
    comptime {
        const Button = Component(.{
            .base = .{ .padding = "8px" },
        });
        const Card = Component(.{
            .base = .{ .padding = "16px" },
        });

        const sheet = generateStylesheet(.{
            .button = Button,
            .card = Card,
        });

        if (std.mem.indexOf(u8, sheet, "/* button */") == null) @compileError("no button");
        if (std.mem.indexOf(u8, sheet, "/* card */") == null) @compileError("no card");
    }
}

test "getAllClasses: collects all class names" {
    comptime {
        const Button = Component(.{
            .base = .{ .padding = "8px" },
        });
        const Card = Component(.{
            .base = .{ .padding = "16px" },
        });

        const classes = getAllClasses(.{
            .button = Button,
            .card = Card,
        });

        if (classes.len == 0) @compileError("no classes");
    }
}

test "Edge case: empty component" {
    comptime {
        const Empty = Component(.{
            .base = .{},
        });

        if (Empty.css.len != 0) @compileError("css not empty");
        if (Empty.classes.len != 0) @compileError("classes not empty");
    }
}

test "Edge case: deeply nested responsive config" {
    comptime {
        @setEvalBranchQuota(10000);

        const Complex = Component(.{
            .base = .{ .padding = "4px" },
            .sm = .{ .padding = "8px" },
            .md = .{ .padding = "16px" },
            .lg = .{ .padding = "24px" },
            .xl = .{ .padding = "32px" },
            .xl2 = .{ .padding = "48px" },
        });

        if (Complex.css.len == 0) @compileError("css empty");
        if (std.mem.indexOf(u8, Complex.css, "640px") == null) @compileError("no 640px");
        if (std.mem.indexOf(u8, Complex.css, "768px") == null) @compileError("no 768px");
        if (std.mem.indexOf(u8, Complex.css, "1024px") == null) @compileError("no 1024px");
        if (std.mem.indexOf(u8, Complex.css, "1280px") == null) @compileError("no 1280px");
        if (std.mem.indexOf(u8, Complex.css, "1536px") == null) @compileError("no 1536px");
    }
}

test "Edge case: all state variants combined" {
    comptime {
        const Interactive = Component(.{
            .base = .{ .background = "white" },
            .hover = .{ .background = "#f0f0f0" },
            .focus = .{ .outline = "2px solid blue" },
            .active = .{ .background = "#e0e0e0" },
        });

        if (std.mem.indexOf(u8, Interactive.css, "hover") == null) @compileError("no hover");
        if (std.mem.indexOf(u8, Interactive.css, "focus") == null) @compileError("no focus");
        if (std.mem.indexOf(u8, Interactive.css, "active") == null) @compileError("no active");
    }
}

test "Edge case: special characters in values" {
    comptime {
        const Special = Component(.{
            .base = .{
                .background = "linear-gradient(135deg, #667eea 0%, #764ba2 100%)",
                .box_shadow = "0 10px 15px -3px rgba(0, 0, 0, 0.1)",
                .font_family = "'Inter', -apple-system, sans-serif",
            },
        });

        if (std.mem.indexOf(u8, Special.css, "linear-gradient") == null) @compileError("no gradient");
        if (std.mem.indexOf(u8, Special.css, "rgba") == null) @compileError("no rgba");
    }
}

test "Edge case: numeric values" {
    comptime {
        const Numeric = Component(.{
            .base = .{
                .padding = 16,
                .margin = 8,
                .border_radius = 4,
            },
        });

        if (std.mem.indexOf(u8, Numeric.css, "16px") == null) @compileError("no 16px");
        if (std.mem.indexOf(u8, Numeric.css, "8px") == null) @compileError("no 8px");
        if (std.mem.indexOf(u8, Numeric.css, "4px") == null) @compileError("no 4px");
    }
}

test "Edge case: boolean values" {
    comptime {
        const BoolStyle = Component(.{
            .base = .{
                .display_none = false,
                .visibility = true,
            },
        });

        if (std.mem.indexOf(u8, BoolStyle.css, "0") == null) @compileError("no 0");
        if (std.mem.indexOf(u8, BoolStyle.css, "1") == null) @compileError("no 1");
    }
}

test "Edge case: very long property names" {
    comptime {
        @setEvalBranchQuota(10000);

        const LongProps = Component(.{
            .base = .{
                .webkit_user_select = "none",
                .moz_user_select = "none",
                .ms_user_select = "none",
            },
        });

        if (LongProps.css.len == 0) @compileError("css empty");
    }
}

test "Edge case: unicode values" {
    comptime {
        const Unicode = Component(.{
            .base = .{
                .content = "'\\2022'",
                .font_family = "'Noto Sans', sans-serif",
            },
        });

        if (std.mem.indexOf(u8, Unicode.css, "2022") == null) @compileError("no unicode");
    }
}

test "Edge case: zero values" {
    comptime {
        const Zero = Component(.{
            .base = .{
                .margin = 0,
                .padding = 0,
                .border_width = 0,
            },
        });

        if (std.mem.indexOf(u8, Zero.css, "0px") == null) @compileError("no 0px");
    }
}

test "Edge case: negative values" {
    comptime {
        const Negative = Component(.{
            .base = .{
                .margin_top = -8,
                .margin_left = -16,
            },
        });

        if (std.mem.indexOf(u8, Negative.css, "-8px") == null) @compileError("no -8px");
        if (std.mem.indexOf(u8, Negative.css, "-16px") == null) @compileError("no -16px");
    }
}

test "Edge case: percentage values" {
    comptime {
        const Percent = Component(.{
            .base = .{
                .width = "50%",
                .height = "100%",
                .max_width = "75%",
            },
        });

        if (std.mem.indexOf(u8, Percent.css, "50%") == null) @compileError("no 50%");
        if (std.mem.indexOf(u8, Percent.css, "100%") == null) @compileError("no 100%");
    }
}

test "Edge case: viewport units" {
    comptime {
        const Viewport = Component(.{
            .base = .{
                .width = "100vw",
                .height = "100vh",
                .font_size = "2vmin",
            },
        });

        if (std.mem.indexOf(u8, Viewport.css, "100vw") == null) @compileError("no 100vw");
        if (std.mem.indexOf(u8, Viewport.css, "100vh") == null) @compileError("no 100vh");
    }
}

test "Edge case: calc() values" {
    comptime {
        const Calc = Component(.{
            .base = .{
                .width = "calc(100% - 2rem)",
                .height = "calc(100vh - 64px)",
            },
        });

        if (std.mem.indexOf(u8, Calc.css, "calc") == null) @compileError("no calc");
    }
}

test "Edge case: multiple components with same property" {
    comptime {
        const Button1 = Component(.{
            .base = .{ .padding = "8px" },
        });
        const Button2 = Component(.{
            .base = .{ .padding = "8px" },
        });

        if (!std.mem.eql(u8, Button1.classes, Button2.classes)) @compileError("classes differ");
    }
}

test "Edge case: component with only responsive styles" {
    comptime {
        const ResponsiveOnly = Component(.{
            .base = .{},
            .md = .{ .padding = "16px" },
            .lg = .{ .padding = "24px" },
        });

        if (ResponsiveOnly.css.len == 0) @compileError("css empty");
        if (std.mem.indexOf(u8, ResponsiveOnly.css, "@media") == null) @compileError("no media");
    }
}

test "Edge case: component with only dark mode styles" {
    comptime {
        const DarkOnly = Component(.{
            .base = .{},
            .dark = .{ .background = "#1a1a2e" },
        });

        if (DarkOnly.css.len == 0) @compileError("css empty");
        if (std.mem.indexOf(u8, DarkOnly.css, "prefers-color-scheme") == null) @compileError("no dark");
    }
}

test "Edge case: component with only hover styles" {
    comptime {
        const HoverOnly = Component(.{
            .base = .{},
            .hover = .{ .background = "#f0f0f0" },
        });

        if (HoverOnly.css.len == 0) @compileError("css empty");
        if (std.mem.indexOf(u8, HoverOnly.css, "hover") == null) @compileError("no hover");
    }
}

test "Edge case: generateStylesheet with empty components" {
    comptime {
        const Empty1 = Component(.{ .base = .{} });
        const Empty2 = Component(.{ .base = .{} });

        const sheet = generateStylesheet(.{
            .empty1 = Empty1,
            .empty2 = Empty2,
        });

        if (std.mem.indexOf(u8, sheet, "/* mercss generated stylesheet */") == null) @compileError("no header");
    }
}

test "Edge case: getAllClasses with empty components" {
    comptime {
        const Empty1 = Component(.{ .base = .{} });
        const Empty2 = Component(.{ .base = .{} });

        const classes = getAllClasses(.{
            .empty1 = Empty1,
            .empty2 = Empty2,
        });

        if (classes.len != 0) @compileError("Expected empty classes");
    }
}
