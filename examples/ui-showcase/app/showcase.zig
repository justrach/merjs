//! UI Component Showcase for merlion-ui
const mer = @import("mer");
const h = mer.h;
const Button = @import("components/button.zig");
const Card = @import("components/card.zig");
const Input = @import("components/input.zig");
const Badge = @import("components/badge.zig");
const Alert = @import("components/alert.zig");

pub const meta: mer.Meta = .{
    .title = "merlion-ui Component Showcase",
    .description = "Beautiful UI components for merlionjs",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    
    return mer.html(
        h.div(.{ .class = "max-w-4xl mx-auto p-8 space-y-12" }, &.{
            // Header
            h.h1(.{ .class = "text-4xl font-bold mb-4" }, "merlion-ui Showcase"),
            h.p(.{ .class = "text-slate-600 mb-8" }, "Beautiful, copy-pasteable UI components for merlionjs. Like shadcn/ui, but for Zig."),
            
            // Button Section
            h.section(.{ .class = "space-y-4" }, &.{
                h.h2(.{ .class = "text-2xl font-semibold" }, "Buttons"),
                h.div(.{ .class = "flex flex-wrap gap-4" }, &.{
                    Button.render(.{ .label = "Primary", .variant = .primary }),
                    Button.render(.{ .label = "Secondary", .variant = .secondary }),
                    Button.render(.{ .label = "Destructive", .variant = .destructive }),
                    Button.render(.{ .label = "Outline", .variant = .outline }),
                    Button.render(.{ .label = "Ghost", .variant = .ghost }),
                    Button.render(.{ .label = "Link", .variant = .link }),
                }),
            }),
            
            // Card Section
            h.section(.{ .class = "space-y-4" }, &.{
                h.h2(.{ .class = "text-2xl font-semibold" }, "Cards"),
                Card.render(.{
                    .children = &.{
                        h.h3(.{ .class = "text-lg font-medium mb-2" }, "Card Title"),
                        h.p(.{ .class = "text-slate-600" }, "This is a card component with content inside."),
                    },
                }),
            }),
            
            // Input Section
            h.section(.{ .class = "space-y-4" }, &.{
                h.h2(.{ .class = "text-2xl font-semibold" }, "Inputs"),
                h.div(.{ .class = "max-w-md space-y-4" }, &.{
                    Input.render(.{ .name = "email", .type = .email, .label = "Email", .placeholder = "you@example.com" }),
                    Input.render(.{ .name = "password", .type = .password, .label = "Password", .placeholder = "••••••••" }),
                }),
            }),
            
            // Badge Section
            h.section(.{ .class = "space-y-4" }, &.{
                h.h2(.{ .class = "text-2xl font-semibold" }, "Badges"),
                h.div(.{ .class = "flex flex-wrap gap-4" }, &.{
                    Badge.render(.{ .label = "Default", .variant = .default }),
                    Badge.render(.{ .label = "Secondary", .variant = .secondary }),
                    Badge.render(.{ .label = "Destructive", .variant = .destructive }),
                    Badge.render(.{ .label = "Outline", .variant = .outline }),
                }),
            }),
            
            // Alert Section
            h.section(.{ .class = "space-y-4" }, &.{
                h.h2(.{ .class = "text-2xl font-semibold" }, "Alerts"),
                h.div(.{ .class = "space-y-4" }, &.{
                    Alert.render(.{ .title = "Info", .description = "This is a default alert message.", .variant = .default }),
                    Alert.render(.{ .title = "Error", .description = "Something went wrong! This is a destructive alert.", .variant = .destructive }),
                }),
            }),
        }),
    );
}
