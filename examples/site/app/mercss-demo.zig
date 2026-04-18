const mer = @import("mer");
const h = mer.h;
const design = mer.design;
const mercss = mer.mercss;

pub const meta: mer.Meta = .{
    .title = "mercss Demo",
    .description = "Showcase of mercss compile-time atomic CSS system with responsive breakpoints, state variants, and dark mode.",
    .extra_head = "<style>" ++ page_css ++ "</style>" ++ mercss_css,
};

const Button = mercss.Component(.{
    .base = .{
        .padding = design.space.base,
        .background_color = design.primary.DEFAULT,
        .color = "#ffffff",
        .border_radius = design.radius.md,
        .font_size = design.font.size.base,
        .font_weight = design.font.weight.medium,
        .border = "none",
        .cursor = "pointer",
        .transition = design.transition.base,
    },
    .hover = .{
        .background_color = design.primary.dark,
    },
    .active = .{
        .background_color = design.primary.darker,
    },
    .focus = .{
        .outline = "2px solid " ++ design.primary.light,
        .outline_offset = "2px",
    },
});

const Card = mercss.Component(.{
    .base = .{
        .padding = design.space.xl,
        .background_color = "#ffffff",
        .border_radius = design.radius.lg,
        .box_shadow = design.shadow.md,
        .margin_bottom = design.space.lg,
    },
    .md = .{
        .padding = design.space.xl2,
    },
    .lg = .{
        .padding = design.space.xl3,
    },
});

const DarkCard = mercss.Component(.{
    .base = .{
        .padding = design.space.xl,
        .background_color = design.slate.c100,
        .border_radius = design.radius.lg,
        .margin_bottom = design.space.lg,
    },
    .dark = .{
        .background_color = design.slate.c800,
        .color = design.slate.c100,
    },
});

const mercss_css = Button.css ++ Card.css ++ DarkCard.css;

const page_node = page();
comptime {
    mer.lint.check(page_node);
}

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn page() h.Node {
    return h.div(.{ .class = "mercss-demo" }, .{
        h.h1(.{ .class = "demo-title" }, "mercss Demo"),
        h.p(.{ .class = "demo-subtitle" }, "Compile-time atomic CSS with responsive breakpoints, state variants, and dark mode."),

        h.hr(.{ .class = "rule" }),

        h.h2(.{ .class = "section-title" }, "Responsive Cards"),
        h.p(.{ .class = "section-desc" }, "Cards that adapt padding at different breakpoints (sm, md, lg)."),
        h.div(.{ .class = "card-grid" }, .{
            h.div(.{ .class = Card.classes }, .{
                h.h3(.{ .class = "card-title" }, "Base Card"),
                h.p(.{ .class = "card-text" }, "This card uses the base padding of " ++ design.space.xl ++ "."),
            }),
            h.div(.{ .class = Card.classes }, .{
                h.h3(.{ .class = "card-title" }, "Responsive Card"),
                h.p(.{ .class = "card-text" }, "Padding increases at md (" ++ design.space.xl2 ++ ") and lg (" ++ design.space.xl3 ++ ") breakpoints."),
            }),
        }),

        h.hr(.{ .class = "rule" }),

        h.h2(.{ .class = "section-title" }, "Interactive Button"),
        h.p(.{ .class = "section-desc" }, "Button with hover, active, and focus states generated at compile time."),
        h.div(.{ .class = "button-row" }, .{
            h.button(.{ .class = Button.classes, .type = "button" }, "Click Me"),
            h.button(.{ .class = Button.classes, .type = "button" }, "Hover Me"),
            h.button(.{ .class = Button.classes, .type = "button" }, "Focus Me"),
        }),

        h.hr(.{ .class = "rule" }),

        h.h2(.{ .class = "section-title" }, "Dark Mode Support"),
        h.p(.{ .class = "section-desc" }, "Cards that automatically adapt to dark mode via prefers-color-scheme."),
        h.div(.{ .class = "dark-card-grid" }, .{
            h.div(.{ .class = DarkCard.classes }, .{
                h.h3(.{ .class = "card-title" }, "Dark Mode Card"),
                h.p(.{ .class = "card-text" }, "This card changes background and text color in dark mode."),
            }),
        }),

        h.hr(.{ .class = "rule" }),

        h.h2(.{ .class = "section-title" }, "Design System Tokens"),
        h.p(.{ .class = "section-desc" }, "Type-safe design tokens for spacing, typography, colors, and more."),
        h.div(.{ .class = "token-grid" }, .{
            tokenCard("Spacing", "4px base grid (xs to xl6)"),
            tokenCard("Typography", "DM Sans + DM Serif Display"),
            tokenCard("Colors", "17 scales, 11 shades each"),
            tokenCard("Shadows", "xs to xl2 + inner"),
            tokenCard("Transitions", "Fast to slower with easing"),
            tokenCard("Border Radius", "none to full (9999px)"),
        }),

        h.hr(.{ .class = "rule" }),

        h.div(.{ .class = "code-section" }, .{
            h.h2(.{ .class = "section-title" }, "Generated CSS"),
            h.p(.{ .class = "section-desc" }, "All CSS is generated at compile time — zero runtime overhead."),
            h.pre(.{ .class = "code-block" }, .{h.raw(escapeHtml(mercss_css))}),
        }),
    });
}

fn tokenCard(title: []const u8, desc: []const u8) h.Node {
    return h.div(.{ .class = "token-card" }, .{
        h.h3(.{ .class = "token-title" }, title),
        h.p(.{ .class = "token-desc" }, desc),
    });
}

fn escapeHtml(comptime input: []const u8) []const u8 {
    comptime {
        var len: usize = 0;
        for (input) |c| {
            len += switch (c) {
                '<' => 4,
                '>' => 4,
                '&' => 5,
                '"' => 6,
                else => 1,
            };
        }
        var buf: [len]u8 = undefined;
        var i: usize = 0;
        for (input) |c| {
            switch (c) {
                '<' => {
                    buf[i] = '&';
                    buf[i + 1] = 'l';
                    buf[i + 2] = 't';
                    buf[i + 3] = ';';
                    i += 4;
                },
                '>' => {
                    buf[i] = '&';
                    buf[i + 1] = 'g';
                    buf[i + 2] = 't';
                    buf[i + 3] = ';';
                    i += 4;
                },
                '&' => {
                    buf[i] = '&';
                    buf[i + 1] = 'a';
                    buf[i + 2] = 'm';
                    buf[i + 3] = 'p';
                    buf[i + 4] = ';';
                    i += 5;
                },
                '"' => {
                    buf[i] = '&';
                    buf[i + 1] = '#';
                    buf[i + 2] = '3';
                    buf[i + 3] = '4';
                    buf[i + 4] = ';';
                    i += 5;
                },
                else => {
                    buf[i] = c;
                    i += 1;
                },
            }
        }
        return buf[0..len];
    }
}

const page_css =
    \\.mercss-demo { max-width: 800px; margin: 0 auto; padding: 40px 20px; }
    \\.demo-title { font-family: 'DM Serif Display', Georgia, serif; font-size: 36px; margin-bottom: 8px; }
    \\.demo-subtitle { font-size: 16px; color: var(--muted); margin-bottom: 32px; }
    \\.rule { border: none; border-top: 1px solid var(--border); margin: 40px 0; }
    \\.section-title { font-family: 'DM Serif Display', Georgia, serif; font-size: 24px; margin-bottom: 8px; }
    \\.section-desc { font-size: 14px; color: var(--muted); margin-bottom: 24px; }
    \\.card-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 20px; }
    \\.card-title { font-family: 'DM Serif Display', Georgia, serif; font-size: 18px; margin-bottom: 8px; }
    \\.card-text { font-size: 14px; color: var(--muted); line-height: 1.6; }
    \\.button-row { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 20px; }
    \\.dark-card-grid { display: grid; grid-template-columns: 1fr; gap: 20px; }
    \\.token-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; }
    \\.token-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 16px; }
    \\.token-title { font-size: 14px; font-weight: 600; margin-bottom: 4px; }
    \\.token-desc { font-size: 13px; color: var(--muted); }
    \\.code-section { margin-top: 20px; }
    \\.code-block { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 16px; font-size: 12px; overflow-x: auto; white-space: pre-wrap; word-break: break-all; max-height: 400px; overflow-y: auto; }
    \\@media (max-width: 600px) {
    \\  .mercss-demo { padding: 20px 12px; }
    \\  .demo-title { font-size: 28px; }
    \\  .card-grid { grid-template-columns: 1fr; }
    \\  .token-grid { grid-template-columns: 1fr; }
    \\}
;
