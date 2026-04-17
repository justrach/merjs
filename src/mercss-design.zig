//! mercss-design.zig - The ultimate design system for merjs
//!
//! Better than Tailwind:
//! - Type-safe everything
//! - Compile-time theme validation
//! - Semantic color scales
//! - Motion/animation ready
//! - Accessible by default

const std = @import("std");
const mercss = @import("mercss.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// FOUNDATION - Primitive tokens that everything builds on
// ═══════════════════════════════════════════════════════════════════════════════

/// Base unit for all spacing (4px grid like Tailwind)
pub const UNIT = 4;

/// Generate spacing value from unit multiplier
fn spacingValue(comptime multiplier: comptime_int) []const u8 {
    return std.fmt.comptimePrint("{d}px", .{UNIT * multiplier});
}

/// Spacing scale - 4px base unit
pub const space = struct {
    pub const px = "1px";
    pub const xs = spacingValue(1); // 4px
    pub const sm = spacingValue(2); // 8px
    pub const md = spacingValue(3); // 12px
    pub const base = spacingValue(4); // 16px
    pub const lg = spacingValue(6); // 24px
    pub const xl = spacingValue(8); // 32px
    pub const xl2 = spacingValue(10); // 40px
    pub const xl3 = spacingValue(12); // 48px
    pub const xl4 = spacingValue(16); // 64px
    pub const xl5 = spacingValue(20); // 80px
    pub const xl6 = spacingValue(24); // 96px
};

/// Size scale for widths/heights
pub const size = struct {
    pub const auto = "auto";
    pub const full = "100%";
    pub const screen = "100vh";
    pub const xs = "20rem"; // 320px
    pub const sm = "24rem"; // 384px
    pub const md = "28rem"; // 448px
    pub const lg = "32rem"; // 512px
    pub const xl = "36rem"; // 576px
    pub const xl2 = "42rem"; // 672px
    pub const xl3 = "48rem"; // 768px
    pub const xl4 = "56rem"; // 896px
    pub const xl5 = "64rem"; // 1024px
    pub const xl6 = "72rem"; // 1152px
    pub const xl7 = "80rem"; // 1280px
};

/// Border radius - semantic scale
pub const radius = struct {
    pub const none = "0px";
    pub const xs = "2px";
    pub const sm = "4px"; // rounded-sm
    pub const md = "6px"; // rounded
    pub const lg = "8px"; // rounded-md
    pub const xl = "12px"; // rounded-lg
    pub const xl2 = "16px"; // rounded-xl
    pub const xl3 = "24px"; // rounded-2xl
    pub const full = "9999px"; // rounded-full
};

/// Z-index scale
pub const z = struct {
    pub const auto = "auto";
    pub const base = "0";
    pub const dropdown = "10";
    pub const sticky = "20";
    pub const fixed = "30";
    pub const overlay = "40";
    pub const modal = "50";
    pub const popover = "60";
    pub const tooltip = "70";
};

/// Opacity scale
pub const opacity = struct {
    pub const transparent = "0";
    pub const xs = "0.05";
    pub const sm = "0.1";
    pub const md = "0.25";
    pub const base = "0.5";
    pub const lg = "0.75";
    pub const xl = "0.9";
    pub const full = "1";
};

// ═══════════════════════════════════════════════════════════════════════════════
// TYPOGRAPHY - Beautiful, readable text
// ═══════════════════════════════════════════════════════════════════════════════

pub const font = struct {
    /// Font families
    pub const family = struct {
        pub const sans = "ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif";
        pub const serif = "ui-serif, Georgia, Cambria, 'Times New Roman', Times, serif";
        pub const mono = "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace";
    };

    /// Font sizes with perfect line-height ratios
    pub const size = struct {
        pub const xs = "12px";
        pub const sm = "14px";
        pub const base = "16px";
        pub const lg = "18px";
        pub const xl = "20px";
        pub const xl2 = "24px";
        pub const xl3 = "30px";
        pub const xl4 = "36px";
        pub const xl5 = "48px";
        pub const xl6 = "60px";
        pub const xl7 = "72px";
        pub const xl8 = "96px";
    };

    /// Line heights (leading)
    pub const leading = struct {
        pub const none = "1";
        pub const xs = "1.125";
        pub const sm = "1.25";
        pub const base = "1.5";
        pub const relaxed = "1.625";
        pub const loose = "2";
    };

    /// Font weights
    pub const weight = struct {
        pub const thin = "100";
        pub const extralight = "200";
        pub const light = "300";
        pub const normal = "400";
        pub const medium = "500";
        pub const semibold = "600";
        pub const bold = "700";
        pub const extrabold = "800";
        pub const black = "900";
    };

    /// Letter spacing (tracking)
    pub const tracking = struct {
        pub const tighter = "-0.05em";
        pub const tight = "-0.025em";
        pub const normal = "0";
        pub const wide = "0.025em";
        pub const wider = "0.05em";
        pub const widest = "0.1em";
    };
};

// ═══════════════════════════════════════════════════════════════════════════════
// COLORS - Modern, accessible palette
// ═══════════════════════════════════════════════════════════════════════════════

/// Generate color scale struct
fn ColorScale(comptime name: []const u8, comptime hex_50: []const u8, comptime hex_100: []const u8, comptime hex_200: []const u8, comptime hex_300: []const u8, comptime hex_400: []const u8, comptime hex_500: []const u8, comptime hex_600: []const u8, comptime hex_700: []const u8, comptime hex_800: []const u8, comptime hex_900: []const u8, comptime hex_950: []const u8) type {
    return struct {
        pub const c50 = hex_50;
        pub const c100 = hex_100;
        pub const c200 = hex_200;
        pub const c300 = hex_300;
        pub const c400 = hex_400;
        pub const c500 = hex_500;
        pub const c600 = hex_600;
        pub const c700 = hex_700;
        pub const c800 = hex_800;
        pub const c900 = hex_900;
        pub const c950 = hex_950;

        // Semantic aliases
        pub const lightest = c50;
        pub const lighter = c100;
        pub const light = c200;
        pub const DEFAULT = c500;
        pub const dark = c600;
        pub const darker = c700;
        pub const darkest = c900;
    };
}

/// Neutral grays
pub const slate = ColorScale("slate", "#f8fafc", "#f1f5f9", "#e2e8f0", "#cbd5e1", "#94a3b8", "#64748b", "#475569", "#334155", "#1e293b", "#0f172a", "#020617");
pub const gray = ColorScale("gray", "#f9fafb", "#f3f4f6", "#e5e7eb", "#d1d5db", "#9ca3af", "#6b7280", "#4b5563", "#374151", "#1f2937", "#111827", "#030712");
pub const zinc = ColorScale("zinc", "#fafafa", "#f4f4f5", "#e4e4e7", "#d4d4d8", "#a1a1aa", "#71717a", "#52525b", "#3f3f46", "#27272a", "#18181b", "#09090b");
pub const neutral = ColorScale("neutral", "#fafafa", "#f5f5f5", "#e5e5e5", "#d4d4d4", "#a3a3a3", "#737373", "#525252", "#404040", "#262626", "#171717", "#0a0a0a");
pub const stone = ColorScale("stone", "#fafaf9", "#f5f5f4", "#e7e5e4", "#d6d3d1", "#a8a29e", "#78716c", "#57534e", "#44403c", "#292524", "#1c1917", "#0c0a09");

/// Warm colors
pub const red = ColorScale("red", "#fef2f2", "#fee2e2", "#fecaca", "#fca5a5", "#f87171", "#ef4444", "#dc2626", "#b91c1c", "#991b1b", "#7f1d1d", "#450a0a");
pub const orange = ColorScale("orange", "#fff7ed", "#ffedd5", "#fed7aa", "#fdba74", "#fb923c", "#f97316", "#ea580c", "#c2410c", "#9a3412", "#7c2d12", "#431407");
pub const amber = ColorScale("amber", "#fffbeb", "#fef3c7", "#fde68a", "#fcd34d", "#fbbf24", "#f59e0b", "#d97706", "#b45309", "#92400e", "#78350f", "#451a03");
pub const yellow = ColorScale("yellow", "#fefce8", "#fef9c3", "#fef08a", "#fde047", "#facc15", "#eab308", "#ca8a04", "#a16207", "#854d0e", "#713f12", "#422006");

/// Green colors
pub const lime = ColorScale("lime", "#f7fee7", "#ecfccb", "#d9f99d", "#bef264", "#a3e635", "#84cc16", "#65a30d", "#4d7c0f", "#3f6212", "#365314", "#1a2e05");
pub const green = ColorScale("green", "#f0fdf4", "#dcfce7", "#bbf7d0", "#86efac", "#4ade80", "#22c55e", "#16a34a", "#15803d", "#166534", "#14532d", "#052e16");
pub const emerald = ColorScale("emerald", "#ecfdf5", "#d1fae5", "#a7f3d0", "#6ee7b7", "#34d399", "#10b981", "#059669", "#047857", "#065f46", "#064e3b", "#022c22");
pub const teal = ColorScale("teal", "#f0fdfa", "#ccfbf1", "#99f6e4", "#5eead4", "#2dd4bf", "#14b8a6", "#0d9488", "#0f766e", "#115e59", "#134e4a", "#042f2e");

/// Cool colors
pub const cyan = ColorScale("cyan", "#ecfeff", "#cffafe", "#a5f3fc", "#67e8f9", "#22d3ee", "#06b6d4", "#0891b2", "#0e7490", "#155e75", "#164e63", "#083344");
pub const sky = ColorScale("sky", "#f0f9ff", "#e0f2fe", "#bae6fd", "#7dd3fc", "#38bdf8", "#0ea5e9", "#0284c7", "#0369a1", "#075985", "#0c4a6e", "#082f49");
pub const blue = ColorScale("blue", "#eff6ff", "#dbeafe", "#bfdbfe", "#93c5fd", "#60a5fa", "#3b82f6", "#2563eb", "#1d4ed8", "#1e40af", "#1e3a8a", "#172554");
pub const indigo = ColorScale("indigo", "#eef2ff", "#e0e7ff", "#c7d2fe", "#a5b4fc", "#818cf8", "#6366f1", "#4f46e5", "#4338ca", "#3730a3", "#312e81", "#1e1b4b");

/// Purple & pink
pub const violet = ColorScale("violet", "#f5f3ff", "#ede9fe", "#ddd6fe", "#c4b5fd", "#a78bfa", "#8b5cf6", "#7c3aed", "#6d28d9", "#5b21b6", "#4c1d95", "#2e1065");
pub const purple = ColorScale("purple", "#faf5ff", "#f3e8ff", "#e9d5ff", "#d8b4fe", "#c084fc", "#a855f7", "#9333ea", "#7e22ce", "#6b21a8", "#581c87", "#3b0764");
pub const fuchsia = ColorScale("fuchsia", "#fdf4ff", "#fae8ff", "#f5d0fe", "#f0abfc", "#e879f9", "#d946ef", "#c026d3", "#a21caf", "#86198f", "#701a75", "#4a044e");
pub const pink = ColorScale("pink", "#fdf2f8", "#fce7f3", "#fbcfe8", "#f9a8d4", "#f472b6", "#ec4899", "#db2777", "#be185d", "#9d174d", "#831843", "#500724");
pub const rose = ColorScale("rose", "#fff1f2", "#ffe4e6", "#fecdd3", "#fda4af", "#fb7185", "#f43f5e", "#e11d48", "#be123c", "#9f1239", "#881337", "#4c0519");

/// Semantic color aliases
pub const primary = blue;
pub const secondary = slate;
pub const success = emerald;
pub const warning = amber;
pub const danger = red;
pub const info = sky;

// ═══════════════════════════════════════════════════════════════════════════════
// SHADOWS & EFFECTS
// ═══════════════════════════════════════════════════════════════════════════════

pub const shadow = struct {
    pub const none = "0 0 #0000";
    pub const xs = "0 1px 2px 0 rgb(0 0 0 / 0.05)";
    pub const sm = "0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1)";
    pub const md = "0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1)";
    pub const lg = "0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1)";
    pub const xl = "0 20px 25px -5px rgb(0 0 0 / 0.1), 0 8px 10px -6px rgb(0 0 0 / 0.1)";
    pub const xl2 = "0 25px 50px -12px rgb(0 0 0 / 0.25)";
    pub const inner = "inset 0 2px 4px 0 rgb(0 0 0 / 0.05)";
};

pub const blur = struct {
    pub const none = "0";
    pub const sm = "4px";
    pub const md = "8px";
    pub const lg = "12px";
    pub const xl = "16px";
    pub const xl2 = "24px";
    pub const xl3 = "32px";
};

/// Transitions & animations
pub const transition = struct {
    pub const fast = "all 100ms cubic-bezier(0.4, 0, 0.2, 1)";
    pub const base = "all 150ms cubic-bezier(0.4, 0, 0.2, 1)";
    pub const slow = "all 300ms cubic-bezier(0.4, 0, 0.2, 1)";
    pub const slower = "all 500ms cubic-bezier(0.4, 0, 0.2, 1)";

    pub const colors = "color, background-color, border-color, text-decoration-color, fill, stroke 150ms cubic-bezier(0.4, 0, 0.2, 1)";
    pub const transform = "transform 150ms cubic-bezier(0.4, 0, 0.2, 1)";
    pub const opacity = "opacity 150ms cubic-bezier(0.4, 0, 0.2, 1)";
    pub const shadow = "box-shadow 150ms cubic-bezier(0.4, 0, 0.2, 1)";
};

pub const ease = struct {
    pub const linear = "linear";
    pub const in = "cubic-bezier(0.4, 0, 1, 1)";
    pub const out = "cubic-bezier(0, 0, 0.2, 1)";
    pub const in_out = "cubic-bezier(0.4, 0, 0.2, 1)";
    pub const bounce = "cubic-bezier(0.68, -0.55, 0.265, 1.55)";
};

pub const duration = struct {
    pub const xs = "75ms";
    pub const sm = "100ms";
    pub const base = "150ms";
    pub const md = "200ms";
    pub const lg = "300ms";
    pub const xl = "500ms";
    pub const xl2 = "700ms";
    pub const xl3 = "1000ms";
};

// ═══════════════════════════════════════════════════════════════════════════════
// RE-EXPORTS FOR CONVENIENCE
// ═══════════════════════════════════════════════════════════════════════════════

pub const Component = mercss.Component;
pub const ResponsiveComponent = mercss.ResponsiveComponent;
