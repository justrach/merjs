const mer = @import("mer");
const css = mer.css;

pub const meta: mer.Meta = .{
    .title = "CSS Demo",
    .description = "merjs comptime CSS helpers",
};

pub fn render(_: mer.Request) mer.Response {
    return mer.html(page);
}

const page =
    "<!DOCTYPE html><html><head><meta charset=\"UTF-8\"><title>CSS-in-Zig</title>" ++
    "<style>body{font-family:-apple-system,system-ui,monospace;background:#1a1a2e;color:#e0e0e0;padding:2em}</style>" ++
    "</head><body>" ++
    "<div style=\"" ++ css.style(.{ .max_width = "640px", .margin = "0 auto" }) ++ "\">" ++
    "<h1 style=\"" ++ css.style(.{ .color = "#64ffda", .margin_bottom = "1rem" }) ++ "\">CSS-in-Zig</h1>" ++
    "<p style=\"" ++ css.style(.{ .color = "#aaa", .margin_bottom = "2rem" }) ++ "\">Comptime struct &rarr; inline CSS. Zero runtime cost.</p>" ++
    // Card
    "<div style=\"" ++ css.style(.{
        .background = "#222244",
        .border_radius = "12px",
        .padding = "1.5rem",
        .border = "1px solid #333",
        .margin_bottom = "1rem",
    }) ++ "\">" ++
    "<h2 style=\"" ++ css.style(.{ .color = "#82b1ff", .margin_bottom = "0.5rem" }) ++ "\">Styled Card</h2>" ++
    "<p>This card is styled with <code style=\"" ++ css.style(.{
        .background = "#1a1a2e",
        .padding = "2px 8px",
        .border_radius = "4px",
        .color = "#64ffda",
        .font_size = "13px",
    }) ++ "\">mer.css.style()</code></p>" ++
    "</div>" ++
    // Class names demo
    "<div class=\"" ++ css.cx(.{ "demo-box", "active", "p-4" }) ++ "\">" ++
    "<p>Classes via <code>css.cx()</code>: \"demo-box active p-4\"</p>" ++
    "</div>" ++
    // Show the generated CSS
    "<h2 style=\"" ++ css.style(.{ .color = "#82b1ff", .margin_top = "2rem" }) ++ "\">What it generates</h2>" ++
    "<pre style=\"" ++ css.style(.{
        .background = "#222244",
        .padding = "1rem",
        .border_radius = "8px",
        .overflow_x = "auto",
        .font_size = "13px",
    }) ++ "\">" ++
    "css.style(.{ .border_radius = \"12px\", .padding = \"1.5rem\" })\n" ++
    "  &darr;\n" ++
    "\"" ++ css.style(.{ .border_radius = "12px", .padding = "1.5rem" }) ++ "\"" ++
    "</pre>" ++
    "</div></body></html>";
