//! Deprecated mercss demo declarations kept for source compatibility.
//!
//! Applications should define their own design tokens and components with
//! mercss.Component and mercss.ResponsiveComponent. This module is available
//! only as `mer.mercss_compat` and will be removed in 0.3.0.

pub fn declarations(comptime Component: anytype, comptime ResponsiveComponent: anytype, comptime InteractiveComponent: anytype) type {
    return struct {
        /// Deprecated: define application design tokens outside framework core.
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

        /// Deprecated: define application components with mercss.Component.
        pub const Button = Component(.{
            .padding = "8px 16px",
            .border_radius = "6px",
            .font_weight = "600",
            .cursor = "pointer",
            .transition = "all 0.2s",
            .background = DesignSystem.colors.primary,
        });

        /// Deprecated: define application components with mercss.Component.
        pub const Card = Component(.{
            .background = "white",
            .border_radius = "8px",
            .padding = "16px",
            .box_shadow = "0 1px 3px rgba(0,0,0,0.1)",
        });

        /// Deprecated: define application components with mercss.Component.
        pub const Alert = Component(.{
            .padding = "12px 16px",
            .border_radius = "6px",
            .font_weight = "500",
            .background = DesignSystem.colors.danger,
        });

        /// Deprecated: assemble application HTML outside framework core.
        pub fn getDemoHtml() []const u8 {
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

        /// Deprecated: assemble application CSS outside framework core.
        pub fn getAllCss() []const u8 {
            return Button.css ++ Card.css ++ Alert.css;
        }

        /// Deprecated: define responsive components in application code.
        pub const ResponsiveContainer = ResponsiveComponent(.{
            .base = .{ .padding = "16px" },
            .sm = .{ .padding = "24px" },
            .md = .{ .padding = "32px" },
            .lg = .{ .padding = "48px" },
        });

        /// Deprecated: define interactive components in application code.
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

        /// Deprecated: define responsive interactive components in application code.
        pub const ResponsiveInteractiveButton = InteractiveComponent(.{
            .base = .{
                .padding = "8px 16px",
                .background = "#3b82f6",
            },
            .hover = .{ .background = "#2563eb" },
            .sm = .{
                .base = .{ .padding = "12px 24px" },
                .hover = .{ .background = "#1d4ed8" },
            },
            .md = .{
                .base = .{ .padding = "16px 32px" },
                .hover = .{ .background = "#1e40af" },
            },
        });

        /// Deprecated: retained as a no-op for source compatibility.
        pub fn exampleUsage() void {}
    };
}
