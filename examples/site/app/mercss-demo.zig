const mer = @import("mer");
const h = mer.h;
const design = mer.design;

// ═══════════════════════════════════════════════════════════════════════════════
// mercss DESIGN SYSTEM DEMO - Polished visuals
// ═══════════════════════════════════════════════════════════════════════════════

// Primary action button
const PrimaryButton = design.ResponsiveComponent(.{
    .base = .{
        .display = "inline-flex",
        .align_items = "center",
        .justify_content = "center",
        .padding = design.space.md ++ " " ++ design.space.lg,
        .background = design.primary.c600,
        .color = "white",
        .font_size = design.font.size.sm,
        .font_weight = design.font.weight.medium,
        .border_radius = design.radius.md,
        .border = "none",
        .cursor = "pointer",
        .box_shadow = design.shadow.sm,
        .transition = design.transition.base,
    },
    .md = .{
        .padding = design.space.base ++ " " ++ design.space.xl2,
        .font_size = design.font.size.base,
    },
});

// Hero card - solid color instead of gradient
const HeroCard = design.ResponsiveComponent(.{
    .base = .{
        .background = design.indigo.c600,
        .color = "white",
        .padding = design.space.xl3,
        .border_radius = design.radius.xl,
        .box_shadow = design.shadow.xl,
    },
    .md = .{
        .padding = design.space.xl5,
    },
    .lg = .{
        .padding = design.space.xl6,
    },
});

// Feature card
const FeatureCard = design.ResponsiveComponent(.{
    .base = .{
        .background = "white",
        .border_radius = design.radius.lg,
        .padding = design.space.xl2,
        .border = "1px solid " ++ design.slate.c200,
        .box_shadow = design.shadow.sm,
    },
    .md = .{
        .padding = design.space.xl3,
        .box_shadow = design.shadow.md,
    },
});

// Alert variants
const SuccessAlert = design.Component(.{
    .background = design.success.c50,
    .border_left = "4px solid " ++ design.success.c500,
    .color = design.success.c800,
    .padding = design.space.md ++ " " ++ design.space.lg,
    .border_radius = design.radius.md,
    .font_size = design.font.size.sm,
    .max_width = "600px",
});

const WarningAlert = design.Component(.{
    .background = design.warning.c50,
    .border_left = "4px solid " ++ design.warning.c500,
    .color = design.warning.c800,
    .padding = design.space.md ++ " " ++ design.space.lg,
    .border_radius = design.radius.md,
    .font_size = design.font.size.sm,
    .max_width = "600px",
});

const InfoAlert = design.Component(.{
    .background = design.info.c50,
    .border_left = "4px solid " ++ design.info.c500,
    .color = design.info.c800,
    .padding = design.space.md ++ " " ++ design.space.lg,
    .border_radius = design.radius.md,
    .font_size = design.font.size.sm,
    .max_width = "600px",
});

// Input field
const Input = design.Component(.{
    .width = "100%",
    .height = "40px",
    .padding = "0 " ++ design.space.md,
    .background = "white",
    .border = "1px solid " ++ design.slate.c300,
    .border_radius = design.radius.md,
    .font_size = design.font.size.base,
    .color = design.slate.c900,
    .transition = design.transition.colors,
});

// Page CSS - all the generated CSS concatenated
const page_css =
    PrimaryButton.css ++
    HeroCard.css ++
    FeatureCard.css ++
    SuccessAlert.css ++
    WarningAlert.css ++
    InfoAlert.css ++
    Input.css ++
    // Additional custom styles for layout and typography
    "body{font-family:" ++ design.font.family.sans ++ ";background:" ++ design.slate.c50 ++ ";margin:0;padding:0;line-height:1.6;color:" ++ design.slate.c900 ++ ";}" ++
    ".page{max-width:1200px;margin:0 auto;padding:" ++ design.space.xl3 ++ ";}" ++
    ".hero-title{font-size:" ++ design.font.size.xl4 ++ ";font-weight:" ++ design.font.weight.bold ++ ";margin:0 0 " ++ design.space.lg ++ ";line-height:1.2;}" ++
    ".hero-subtitle{font-size:" ++ design.font.size.xl ++ ";opacity:0.9;margin:0 0 " ++ design.space.xl ++ ";line-height:1.5;}" ++
    ".section-title{font-size:" ++ design.font.size.xl2 ++ ";font-weight:" ++ design.font.weight.semibold ++ ";color:" ++ design.slate.c900 ++ ";margin:" ++ design.space.xl4 ++ " 0 " ++ design.space.lg ++ ";}" ++
    ".grid{display:grid;gap:" ++ design.space.xl ++ ";}" ++
    ".grid-3{grid-template-columns:repeat(auto-fit,minmax(300px,1fr));}" ++
    ".feature-icon{width:48px;height:48px;border-radius:" ++ design.radius.lg ++ ";display:flex;align-items:center;justify-content:center;font-size:24px;margin-bottom:" ++ design.space.md ++ ";}" ++
    ".feature-title{font-size:" ++ design.font.size.lg ++ ";font-weight:" ++ design.font.weight.semibold ++ ";color:" ++ design.slate.c900 ++ ";margin:0 0 " ++ design.space.sm ++ ";}" ++
    ".feature-desc{font-size:" ++ design.font.size.base ++ ";color:" ++ design.slate.c600 ++ ";line-height:1.6;margin:0;}" ++
    ".alert-title{font-weight:" ++ design.font.weight.semibold ++ ";margin-bottom:" ++ design.space.xs ++ ";font-size:" ++ design.font.size.base ++ ";}" ++
    ".alert-text{font-size:" ++ design.font.size.sm ++ ";line-height:1.5;}" ++
    ".demo-section{margin-bottom:" ++ design.space.xl4 ++ ";}" ++
    "input.mcss-width:focus{outline:none;border-color:" ++ design.primary.c500 ++ ";box-shadow:0 0 0 3px " ++ design.primary.c100 ++ ";}";

pub const meta: mer.Meta = .{
    .title = "mercss Design System - The Best in Town",
    .description = "A stunning design system for Zig/merjs - better than Tailwind",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    const page_node = h.div(.{ .class = "page" }, .{

        // HERO SECTION
        h.div(.{ .class = HeroCard.classes }, .{
            h.h1(.{ .class = "hero-title" }, "mercss Design System"),
            h.p(.{ .class = "hero-subtitle" }, "The best design system in town. Type-safe. Compile-time. Beautiful."),
            h.raw("<button class='" ++ PrimaryButton.classes ++ "' onclick='alert(&quot;Coming soon!&quot;)'>Get Started</button>"),
        }),

        // ALERTS SECTION
        h.div(.{ .class = "demo-section" }, .{
            h.h2(.{ .class = "section-title" }, "Alert Variants"),
            h.div(.{ .class = SuccessAlert.classes }, .{
                h.div(.{ .class = "alert-title" }, "Success!"),
                h.div(.{ .class = "alert-text" }, "Your changes have been saved successfully."),
            }),
            h.br(),
            h.div(.{ .class = WarningAlert.classes }, .{
                h.div(.{ .class = "alert-title" }, "Warning"),
                h.div(.{ .class = "alert-text" }, "Please review your settings before continuing."),
            }),
            h.br(),
            h.div(.{ .class = InfoAlert.classes }, .{
                h.div(.{ .class = "alert-title" }, "Info"),
                h.div(.{ .class = "alert-text" }, "New features are available in the latest version."),
            }),
        }),

        // FEATURES GRID
        h.div(.{ .class = "demo-section" }, .{
            h.h2(.{ .class = "section-title" }, "Features"),
            h.div(.{ .class = "grid grid-3" }, .{
                h.div(.{ .class = FeatureCard.classes }, .{
                    h.div(.{ .class = "feature-icon", .style = "background:" ++ design.primary.c100 ++ ";color:" ++ design.primary.c600 }, "🎨"),
                    h.h3(.{ .class = "feature-title" }, "17 Color Scales"),
                    h.p(.{ .class = "feature-desc" }, "Complete palette from slate to rose. 11 shades each."),
                }),

                h.div(.{ .class = FeatureCard.classes }, .{
                    h.div(.{ .class = "feature-icon", .style = "background:" ++ design.success.c100 ++ ";color:" ++ design.success.c600 }, "⚡"),
                    h.h3(.{ .class = "feature-title" }, "Compile-Time"),
                    h.p(.{ .class = "feature-desc" }, "Zero runtime cost. CSS generated at Zig compilation."),
                }),

                h.div(.{ .class = FeatureCard.classes }, .{
                    h.div(.{ .class = "feature-icon", .style = "background:" ++ design.warning.c100 ++ ";color:" ++ design.warning.c600 }, "🔒"),
                    h.h3(.{ .class = "feature-title" }, "Type-Safe"),
                    h.p(.{ .class = "feature-desc" }, "Wrong color? Compile error. No runtime surprises."),
                }),

                h.div(.{ .class = FeatureCard.classes }, .{
                    h.div(.{ .class = "feature-icon", .style = "background:" ++ design.info.c100 ++ ";color:" ++ design.info.c600 }, "📱"),
                    h.h3(.{ .class = "feature-title" }, "Responsive"),
                    h.p(.{ .class = "feature-desc" }, "Mobile-first breakpoints. sm:, md:, lg:, xl:."),
                }),

                h.div(.{ .class = FeatureCard.classes }, .{
                    h.div(.{ .class = "feature-icon", .style = "background:" ++ design.pink.c100 ++ ";color:" ++ design.pink.c600 }, "✨"),
                    h.h3(.{ .class = "feature-title" }, "Beautiful"),
                    h.p(.{ .class = "feature-desc" }, "Polished defaults. Perfect shadows. Smooth transitions."),
                }),

                h.div(.{ .class = FeatureCard.classes }, .{
                    h.div(.{ .class = "feature-icon", .style = "background:" ++ design.purple.c100 ++ ";color:" ++ design.purple.c600 }, "🚀"),
                    h.h3(.{ .class = "feature-title" }, "Fast"),
                    h.p(.{ .class = "feature-desc" }, "No build step. No purging. Just compile and ship."),
                }),
            }),
        }),

        // FORM DEMO
        h.div(.{ .class = "demo-section" }, .{
            h.h2(.{ .class = "section-title" }, "Form Components"),
            h.div(.{ .class = FeatureCard.classes, .style = "max-width:400px;" }, .{
                h.raw("<input class='" ++ Input.classes ++ "' type='text' placeholder='Type something...' />"),
                h.raw("<input class='" ++ Input.classes ++ "' type='email' placeholder='email@example.com' style='margin-top:" ++ design.space.md ++ ";' />"),
                h.raw("<button class='" ++ PrimaryButton.classes ++ "' style='margin-top:" ++ design.space.lg ++ ";'>Submit</button>"),
            }),
        }),
    });

    return mer.render(req.allocator, page_node);
}
