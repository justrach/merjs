const mer = @import("mer");
const h = mer.h;

// ═══════════════════════════════════════════════════════════════════════════════
// mercss INTEGRATION DEMO - Real merjs page with compile-time CSS
// ═══════════════════════════════════════════════════════════════════════════════

// Access mercss through mer module
const mercss = mer.mercss;

// Define component styles at compile time
const Button = mercss.Component(.{
    .background = "#3b82f6",
    .color = "white",
    .padding = "12px 24px",
    .border_radius = "8px",
    .font_weight = "600",
    .cursor = "pointer",
    .border = "none",
});

const Card = mercss.Component(.{
    .background = "white",
    .border_radius = "12px",
    .padding = "24px",
    .box_shadow = "0 4px 6px rgba(0,0,0,0.1)",
    .max_width = "400px",
});

const Alert = mercss.Component(.{
    .background = "#fee2e2",
    .border_left = "4px solid #dc2626",
    .padding = "16px",
    .color = "#dc2626",
    .border_radius = "6px",
});

// Compile-time generated CSS - zero runtime cost!
const page_css =
    Button.css ++
    Card.css ++
    Alert.css ++
    "body{background:#f3f4f6;padding:40px;font-family:system-ui;}" ++
    ".container{max-width:800px;margin:0 auto;display:flex;flex-direction:column;gap:20px;}" ++
    "h1{margin:0 0 16px 0;color:#1f2937;}" ++
    "p{margin:0 0 16px 0;color:#4b5563;line-height:1.6;}" ++
    "ol{margin:0;padding-left:20px;}" ++
    "li{margin-bottom:8px;color:#4b5563;}";

pub const meta: mer.Meta = .{
    .title = "mercss Demo - Compile-time CSS",
    .description = "Type-safe CSS generated at compile time by Zig",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    const page_node = h.div(.{ .class = "container" }, .{

        // Card component with mercss classes
        h.div(.{ .class = Card.classes }, .{
            h.h1(.{}, "mercss Demo"),
            h.p(.{}, "This page uses compile-time generated atomic CSS from Zig structs."),
            h.p(.{}, "The CSS is type-safe, generated at comptime, and only includes used styles."),

            // Button with mercss classes (using raw HTML for onclick)
            h.raw("<button class='" ++ Button.classes ++ "' onclick='alert(&quot;Clicked!&quot;)'>" ++
                "Click Me</button>"),
        }),

        // Alert component with mercss classes
        h.div(.{ .class = Alert.classes }, .{
            h.strong(.{}, "Alert: "),
            h.text(" This alert's styles were generated at compile time!"),
        }),

        // Info section
        h.div(.{ .class = Card.classes }, .{
            h.h1(.{}, "How it works"),
            h.ol(.{}, .{
                h.li(.{}, "Define styles as Zig structs"),
                h.li(.{}, "mercss generates atomic CSS at compile time"),
                h.li(.{}, "Only used styles exist - no purging needed"),
                h.li(.{}, "Type-safe design tokens"),
            }),
        }),
    });

    return mer.render(req.allocator, page_node);
}
