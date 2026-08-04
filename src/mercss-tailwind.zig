//! mercss-tailwind.zig - Tailwind-inspired design system for mercss
//!
//! Based on Tailwind CSS v4 defaults with improved visuals

const std = @import("std");
const mercss = @import("mercss.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// DESIGN TOKENS - Tailwind v4 Inspired
// ═══════════════════════════════════════════════════════════════════════════════

/// Border radius scale
pub const radius = struct {
    pub const none = "0px";
    pub const sm = "2px";
    pub const DEFAULT = "4px";
    pub const md = "6px";
    pub const lg = "8px";
    pub const xl = "12px";
    pub const xl2 = "16px";
    pub const xl3 = "24px";
    pub const full = "9999px";
};

/// Spacing scale
pub const spacing = struct {
    pub const px = "1px";
    pub const xs = "2px";
    pub const sm = "4px";
    pub const md = "6px";
    pub const base = "8px";
    pub const lg = "12px";
    pub const xl = "16px";
    pub const xl2 = "20px";
    pub const xl3 = "24px";
    pub const xl4 = "32px";
    pub const xl5 = "40px";
    pub const xl6 = "48px";
};

/// Font sizes
pub const font = struct {
    pub const xs = "12px";
    pub const sm = "14px";
    pub const base = "16px";
    pub const lg = "18px";
    pub const xl = "20px";
    pub const xl2 = "24px";
    pub const xl3 = "30px";
};

/// Box shadows
pub const shadow = struct {
    pub const sm = "0 1px 2px 0 rgb(0 0 0 / 0.05)";
    pub const DEFAULT = "0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1)";
    pub const md = "0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1)";
    pub const lg = "0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1)";
};

/// Color palette
pub const slate = struct {
    pub const c50 = "#f8fafc";
    pub const c100 = "#f1f5f9";
    pub const c200 = "#e2e8f0";
    pub const c300 = "#cbd5e1";
    pub const c400 = "#94a3b8";
    pub const c500 = "#64748b";
    pub const c600 = "#475569";
    pub const c700 = "#334155";
    pub const c800 = "#1e293b";
    pub const c900 = "#0f172a";
};

pub const gray = struct {
    pub const c50 = "#f9fafb";
    pub const c100 = "#f3f4f6";
    pub const c200 = "#e5e7eb";
    pub const c300 = "#d1d5db";
    pub const c400 = "#9ca3af";
    pub const c500 = "#6b7280";
    pub const c600 = "#4b5563";
    pub const c700 = "#374151";
    pub const c800 = "#1f2937";
    pub const c900 = "#111827";
};

pub const red = struct {
    pub const c50 = "#fef2f2";
    pub const c100 = "#fee2e2";
    pub const c200 = "#fecaca";
    pub const c300 = "#fca5a5";
    pub const c400 = "#f87171";
    pub const c500 = "#ef4444";
    pub const c600 = "#dc2626";
    pub const c700 = "#b91c1c";
    pub const c800 = "#991b1b";
    pub const c900 = "#7f1d1d";
};

pub const blue = struct {
    pub const c50 = "#eff6ff";
    pub const c100 = "#dbeafe";
    pub const c200 = "#bfdbfe";
    pub const c300 = "#93c5fd";
    pub const c400 = "#60a5fa";
    pub const c500 = "#3b82f6";
    pub const c600 = "#2563eb";
    pub const c700 = "#1d4ed8";
    pub const c800 = "#1e40af";
    pub const c900 = "#1e3a8a";
};

pub const emerald = struct {
    pub const c50 = "#ecfdf5";
    pub const c100 = "#d1fae5";
    pub const c200 = "#a7f3d0";
    pub const c300 = "#6ee7b7";
    pub const c400 = "#34d399";
    pub const c500 = "#10b981";
    pub const c600 = "#059669";
    pub const c700 = "#047857";
    pub const c800 = "#065f46";
    pub const c900 = "#064e3b";
};

// ═══════════════════════════════════════════════════════════════════════════════
// PRE-BUILT COMPONENTS - Polished defaults
// ═══════════════════════════════════════════════════════════════════════════════

/// Modern button with smooth transitions
pub const Button = mercss.ResponsiveComponent(.{
    .base = .{
        .display = "inline-flex",
        .align_items = "center",
        .justify_content = "center",
        .white_space = "nowrap",
        .border_radius = radius.md,
        .font_size = font.sm,
        .font_weight = "500",
        .line_height = "20px",
        .padding = "8px 16px",
        .background = blue.c600,
        .color = "white",
        .border = "1px solid transparent",
        .cursor = "pointer",
        .transition = "all 150ms cubic-bezier(0.4, 0, 0.2, 1)",
        .box_shadow = shadow.sm,
    },
    .md = .{
        .padding = "10px 20px",
        .font_size = font.base,
    },
});

/// Elegant card
pub const Card = mercss.ResponsiveComponent(.{
    .base = .{
        .background = "white",
        .border_radius = radius.lg,
        .border = "1px solid " ++ gray.c200,
        .padding = spacing.xl,
        .box_shadow = shadow.sm,
    },
    .md = .{
        .padding = spacing.xl3,
        .box_shadow = shadow.DEFAULT,
    },
    .lg = .{
        .padding = spacing.xl4,
        .box_shadow = shadow.md,
    },
});

/// Polished alert
pub const Alert = mercss.Component(.{
    .display = "flex",
    .align_items = "flex-start",
    .background = red.c50,
    .border_left = "4px solid " ++ red.c500,
    .border_radius = radius.md,
    .padding = spacing.lg ++ " " ++ spacing.xl,
    .color = red.c800,
    .font_size = font.sm,
    .max_width = "400px",
});

// Re-exports
pub const Component = mercss.Component;
pub const ResponsiveComponent = mercss.ResponsiveComponent;
