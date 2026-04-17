const mer = @import("mer");
const h = mer.h;
const design = mer.design;

// ═══════════════════════════════════════════════════════════════════════════════
// mercss DESIGN SYSTEM - Stunning Modern Demo
// ═══════════════════════════════════════════════════════════════════════════════

// Primary interactive button with states
const PrimaryButton = design.InteractiveComponent(.{
    .base = .{
        .display = "inline-flex",
        .align_items = "center",
        .justify_content = "center",
        .gap = "8px",
        .padding = design.space.md ++ " " ++ design.space.lg,
        .background = design.violet.c600,
        .color = "white",
        .font_size = design.font.size.sm,
        .font_weight = design.font.weight.semibold,
        .border_radius = design.radius.lg,
        .border = "none",
        .cursor = "pointer",
        .box_shadow = "0 4px 14px 0 rgba(124, 58, 237, 0.39)",
        .transition = "all 0.2s ease",
        .letter_spacing = "0.025em",
    },
    .hover = .{
        .background = design.violet.c700,
        .transform = "translateY(-2px)",
        .box_shadow = "0 6px 20px 0 rgba(124, 58, 237, 0.45)",
    },
    .focus = .{
        .outline = "none",
        .box_shadow = "0 0 0 3px " ++ design.violet.c300,
    },
    .active = .{
        .transform = "translateY(0)",
        .background = design.violet.c800,
    },
    .md = .{
        .base = .{ .padding = design.space.base ++ " " ++ design.space.xl2 },
    },
});

// Secondary button (ghost style)
const SecondaryButton = design.InteractiveComponent(.{
    .base = .{
        .display = "inline-flex",
        .align_items = "center",
        .justify_content = "center",
        .padding = design.space.md ++ " " ++ design.space.lg,
        .background = "transparent",
        .color = design.slate.c700,
        .font_size = design.font.size.sm,
        .font_weight = design.font.weight.medium,
        .border_radius = design.radius.lg,
        .border = "1px solid " ++ design.slate.c300,
        .cursor = "pointer",
        .transition = "all 0.2s ease",
    },
    .hover = .{
        .background = design.slate.c100,
        .border_color = design.slate.c400,
        .color = design.slate.c900,
    },
    .focus = .{
        .outline = "none",
        .border_color = design.violet.c500,
        .box_shadow = "0 0 0 3px " ++ design.violet.c100,
    },
});

// Danger button
const DangerButton = design.InteractiveComponent(.{
    .base = .{
        .display = "inline-flex",
        .align_items = "center",
        .justify_content = "center",
        .padding = design.space.md ++ " " ++ design.space.lg,
        .background = design.rose.c600,
        .color = "white",
        .font_size = design.font.size.sm,
        .font_weight = design.font.weight.semibold,
        .border_radius = design.radius.lg,
        .border = "none",
        .cursor = "pointer",
        .box_shadow = "0 4px 14px 0 rgba(225, 29, 72, 0.39)",
        .transition = "all 0.2s ease",
    },
    .hover = .{
        .background = design.rose.c700,
        .transform = "translateY(-2px)",
        .box_shadow = "0 6px 20px 0 rgba(225, 29, 72, 0.45)",
    },
    .focus = .{
        .outline = "none",
        .box_shadow = "0 0 0 3px " ++ design.rose.c300,
    },
});

// Feature cards with hover lift
const FeatureCard = design.InteractiveComponent(.{
    .base = .{
        .background = "white",
        .border_radius = design.radius.xl,
        .padding = design.space.xl3,
        .border = "1px solid " ++ design.slate.c200,
        .box_shadow = design.shadow.sm,
        .transition = "all 0.3s ease",
        .position = "relative",
        .overflow = "hidden",
    },
    .hover = .{
        .transform = "translateY(-4px)",
        .box_shadow = design.shadow.xl,
        .border_color = design.violet.c300,
    },
});

// Code block component
const CodeBlock = design.Component(.{
    .background = design.slate.c900,
    .color = design.slate.c50,
    .padding = design.space.xl3,
    .border_radius = design.radius.lg,
    .font_family = design.font.family.mono,
    .font_size = design.font.size.sm,
    .line_height = "1.6",
    .overflow = "auto",
});

// Alert variants
const SuccessAlert = design.Component(.{
    .background = design.emerald.c50,
    .border = "1px solid " ++ design.emerald.c200,
    .border_left = "4px solid " ++ design.emerald.c500,
    .color = design.emerald.c900,
    .padding = design.space.base ++ " " ++ design.space.lg,
    .border_radius = design.radius.lg,
    .font_size = design.font.size.sm,
});

const InfoAlert = design.Component(.{
    .background = design.violet.c50,
    .border = "1px solid " ++ design.violet.c200,
    .border_left = "4px solid " ++ design.violet.c500,
    .color = design.violet.c900,
    .padding = design.space.base ++ " " ++ design.space.lg,
    .border_radius = design.radius.lg,
    .font_size = design.font.size.sm,
});

// Input field with focus state
const Input = design.InteractiveComponent(.{
    .base = .{
        .width = "100%",
        .height = "44px",
        .padding = "0 " ++ design.space.base,
        .background = "white",
        .border = "1px solid " ++ design.slate.c300,
        .border_radius = design.radius.lg,
        .font_size = design.font.size.base,
        .color = design.slate.c900,
        .transition = "all 0.2s ease",
    },
    .focus = .{
        .outline = "none",
        .border_color = design.violet.c500,
        .box_shadow = "0 0 0 3px " ++ design.violet.c100,
    },
});

// Badge component
const Badge = design.Component(.{
    .display = "inline-flex",
    .align_items = "center",
    .padding = design.space.xs ++ " " ++ design.space.sm,
    .background = design.violet.c100,
    .color = design.violet.c700,
    .font_size = design.font.size.xs,
    .font_weight = design.font.weight.semibold,
    .border_radius = design.radius.full,
    .text_transform = "uppercase",
    .letter_spacing = "0.05em",
});

// Page CSS
const page_css =
    PrimaryButton.css ++
    SecondaryButton.css ++
    DangerButton.css ++
    FeatureCard.css ++
    CodeBlock.css ++
    SuccessAlert.css ++
    InfoAlert.css ++
    Input.css ++
    Badge.css ++

    // Base styles
    "*{box-sizing:border-box;}" ++
    "body{font-family:" ++ design.font.family.sans ++ ";background:" ++ design.slate.c50 ++ ";margin:0;padding:0;line-height:1.6;color:" ++ design.slate.c800 ++ ";-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale;}" ++

    // Container
    ".page{max-width:1280px;margin:0 auto;padding:" ++ design.space.xl4 ++ " " ++ design.space.xl3 ++ ";}" ++

    // Hero section with elegant gradient background using solid colors
    ".hero{background:linear-gradient(145deg," ++ design.slate.c900 ++ " 0%," ++ design.violet.c900 ++ " 50%," ++ design.purple.c900 ++ " 100%);color:white;padding:" ++ design.space.xl6 ++ " " ++ design.space.xl4 ++ ";text-align:center;border-radius:" ++ design.radius.xl2 ++ ";margin-bottom:" ++ design.space.xl5 ++ ";box-shadow:" ++ design.shadow.xl2 ++ ";position:relative;overflow:hidden;}" ++
    ".hero::before{content:'';position:absolute;top:0;left:0;right:0;bottom:0;background:radial-gradient(circle at 30% 50%,rgba(124,58,237,0.3) 0%,transparent 50%),radial-gradient(circle at 70% 50%,rgba(168,85,247,0.2) 0%,transparent 50%);pointer-events:none;}" ++

    // Hero content (relative to appear above pseudo-elements)
    ".hero-content{position:relative;z-index:1;}" ++

    // Hero badge
    ".hero-badge{display:inline-flex;align-items:center;gap:" ++ design.space.sm ++ ";background:rgba(255,255,255,0.1);backdrop-filter:blur(10px);padding:" ++ design.space.sm ++ " " ++ design.space.base ++ ";border-radius:" ++ design.radius.full ++ ";font-size:" ++ design.font.size.sm ++ ";font-weight:" ++ design.font.weight.medium ++ ";margin-bottom:" ++ design.space.xl ++ ";border:1px solid rgba(255,255,255,0.2);}" ++

    // Hero title
    ".hero-title{font-size:" ++ design.font.size.xl5 ++ ";font-weight:" ++ design.font.weight.bold ++ ";margin:0 0 " ++ design.space.lg ++ ";line-height:1.1;letter-spacing:-0.02em;background:linear-gradient(135deg,#fff 0%,#e9d5ff 100%);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;}" ++

    // Hero subtitle
    ".hero-subtitle{font-size:" ++ design.font.size.xl2 ++ ";color:" ++ design.slate.c300 ++ ";margin:0 0 " ++ design.space.xl3 ++ ";line-height:1.5;max-width:600px;margin-left:auto;margin-right:auto;font-weight:" ++ design.font.weight.normal ++ ";}" ++

    // Hero actions
    ".hero-actions{display:flex;gap:" ++ design.space.md ++ ";justify-content:center;flex-wrap:wrap;}" ++

    // Section styling
    ".section{margin-bottom:" ++ design.space.xl5 ++ ";}" ++
    ".section-header{text-align:center;margin-bottom:" ++ design.space.xl3 ++ ";}" ++
    ".section-label{color:" ++ design.violet.c600 ++ ";font-size:" ++ design.font.size.sm ++ ";font-weight:" ++ design.font.weight.semibold ++ ";text-transform:uppercase;letter-spacing:0.1em;margin-bottom:" ++ design.space.sm ++ ";}" ++
    ".section-title{font-size:" ++ design.font.size.xl3 ++ ";font-weight:" ++ design.font.weight.bold ++ ";color:" ++ design.slate.c900 ++ ";margin:0 0 " ++ design.space.base ++ ";letter-spacing:-0.02em;}" ++
    ".section-desc{font-size:" ++ design.font.size.lg ++ ";color:" ++ design.slate.c600 ++ ";max-width:600px;margin:0 auto;line-height:1.6;}" ++

    // Feature grid
    ".feature-grid{display:grid;gap:" ++ design.space.xl ++ ";grid-template-columns:repeat(auto-fit,minmax(320px,1fr));}" ++

    // Feature card icon container
    ".feature-icon-wrap{width:56px;height:56px;border-radius:" ++ design.radius.xl ++ ";display:flex;align-items:center;justify-content:center;font-size:28px;margin-bottom:" ++ design.space.lg ++ ";box-shadow:" ++ design.shadow.md ++ ";}" ++

    // Feature title
    ".feature-title{font-size:" ++ design.font.size.xl ++ ";font-weight:" ++ design.font.weight.semibold ++ ";color:" ++ design.slate.c900 ++ ";margin:0 0 " ++ design.space.sm ++ ";}" ++

    // Feature description
    ".feature-desc{font-size:" ++ design.font.size.base ++ ";color:" ++ design.slate.c600 ++ ";line-height:1.7;margin:0;}" ++

    // Code example section
    ".code-section{background:white;border-radius:" ++ design.radius.xl ++ ";padding:" ++ design.space.xl3 ++ ";border:1px solid " ++ design.slate.c200 ++ ";box-shadow:" ++ design.shadow.sm ++ ";}" ++
    ".code-header{display:flex;align-items:center;gap:" ++ design.space.sm ++ ";margin-bottom:" ++ design.space.lg ++ ";padding-bottom:" ++ design.space.base ++ ";border-bottom:1px solid " ++ design.slate.c200 ++ ";}" ++
    ".code-dot{width:12px;height:12px;border-radius:50%;}" ++
    ".code-dot-red{background:" ++ design.rose.c500 ++ ";}" ++
    ".code-dot-yellow{background:" ++ design.amber.c500 ++ ";}" ++
    ".code-dot-green{background:" ++ design.emerald.c500 ++ ";}" ++
    ".code-title{font-size:" ++ design.font.size.sm ++ ";color:" ++ design.slate.c500 ++ ";font-weight:" ++ design.font.weight.medium ++ ";margin-left:auto;}" ++

    // Interactive demo section
    ".interactive-demo{background:linear-gradient(135deg," ++ design.violet.c50 ++ " 0%," ++ design.purple.c50 ++ " 100%);border-radius:" ++ design.radius.xl ++ ";padding:" ++ design.space.xl3 ++ ";border:1px solid " ++ design.violet.c200 ++ ";}" ++
    ".interactive-title{font-size:" ++ design.font.size.xl ++ ";font-weight:" ++ design.font.weight.semibold ++ ";color:" ++ design.slate.c900 ++ ";margin:0 0 " ++ design.space.base ++ ";}" ++
    ".interactive-desc{font-size:" ++ design.font.size.base ++ ";color:" ++ design.slate.c600 ++ ";margin:0 0 " ++ design.space.xl2 ++ ";}" ++
    ".button-row{display:flex;gap:" ++ design.space.md ++ ";flex-wrap:wrap;align-items:center;}" ++

    // Alert styling
    ".alert-title{font-weight:" ++ design.font.weight.semibold ++ ";margin-bottom:" ++ design.space.xs ++ ";font-size:" ++ design.font.size.base ++ ";}" ++
    ".alert-text{font-size:" ++ design.font.size.sm ++ ";line-height:1.5;color:inherit;opacity:0.9;}" ++

    // Form styling
    ".form-demo{max-width:420px;}" ++
    ".form-field{margin-bottom:" ++ design.space.lg ++ ";}" ++
    ".form-label{display:block;font-size:" ++ design.font.size.sm ++ ";font-weight:" ++ design.font.weight.medium ++ ";color:" ++ design.slate.c700 ++ ";margin-bottom:" ++ design.space.sm ++ ";}" ++
    ".form-hint{font-size:" ++ design.font.size.sm ++ ";color:" ++ design.slate.c500 ++ ";margin-top:" ++ design.space.sm ++ ";}" ++

    // Two column layout
    ".two-col{display:grid;gap:" ++ design.space.xl3 ++ ";grid-template-columns:1fr;align-items:start;}" ++
    "@media (min-width: 1024px){.two-col{grid-template-columns:1fr 1fr;}}" ++

    // Color palette showcase
    ".color-grid{display:grid;gap:" ++ design.space.base ++ ";grid-template-columns:repeat(auto-fit,minmax(140px,1fr));margin-top:" ++ design.space.xl2 ++ ";}" ++
    ".color-swatch{height:80px;border-radius:" ++ design.radius.lg ++ " " ++ design.radius.lg ++ " 0 0;box-shadow:inset 0 0 0 1px rgba(0,0,0,0.05);}" ++
    ".color-info{background:white;padding:" ++ design.space.sm ++ " " ++ design.space.base ++ ";border-radius:0 0 " ++ design.radius.lg ++ " " ++ design.radius.lg ++ ";border:1px solid " ++ design.slate.c200 ++ ";border-top:none;}" ++
    ".color-name{font-size:" ++ design.font.size.sm ++ ";font-weight:" ++ design.font.weight.semibold ++ ";color:" ++ design.slate.c900 ++ ";margin:0;}" ++
    ".color-hex{font-size:" ++ design.font.size.xs ++ ";color:" ++ design.slate.c500 ++ ";margin:0;font-family:" ++ design.font.family.mono ++ ";}" ++

    // Stats bar
    ".stats-bar{display:flex;justify-content:center;gap:" ++ design.space.xl3 ++ ";flex-wrap:wrap;margin-top:" ++ design.space.xl4 ++ ";padding-top:" ++ design.space.xl4 ++ ";border-top:1px solid rgba(255,255,255,0.1);}" ++
    ".stat{text-align:center;}" ++
    ".stat-value{font-size:" ++ design.font.size.xl3 ++ ";font-weight:" ++ design.font.weight.bold ++ ";color:white;margin:0;line-height:1;}" ++
    ".stat-label{font-size:" ++ design.font.size.sm ++ ";color:" ++ design.slate.c400 ++ ";margin:" ++ design.space.xs ++ " 0 0;text-transform:uppercase;letter-spacing:0.05em;}" ++

    // Footer
    ".footer{text-align:center;padding:" ++ design.space.xl4 ++ " 0;border-top:1px solid " ++ design.slate.c200 ++ ";margin-top:" ++ design.space.xl4 ++ ";}" ++
    ".footer-text{font-size:" ++ design.font.size.sm ++ ";color:" ++ design.slate.c500 ++ ";}";

pub const meta: mer.Meta = .{
    .title = "mercss - The Ultimate Design System for Zig",
    .description = "A stunning, type-safe design system for merjs. Better than Tailwind. Zero runtime cost.",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    const page_node = h.div(.{ .class = "page" }, .{

        // ═══════════════════════════════════════════════════════════════════════════════
        // HERO SECTION
        // ═══════════════════════════════════════════════════════════════════════════════
        h.div(.{ .class = "hero" }, .{
            h.div(.{ .class = "hero-content" }, .{
                h.div(.{ .class = "hero-badge" }, .{
                    h.text("✨"),
                    h.text("Now with State Variants"),
                }),
                h.h1(.{ .class = "hero-title" }, "mercss Design System"),
                h.p(.{ .class = "hero-subtitle" }, "The ultimate design system for Zig and merjs. Type-safe, compile-time generated, and beautiful by default."),
                h.div(.{ .class = "hero-actions" }, .{
                    h.raw("<button class='" ++ PrimaryButton.classes ++ "'>Get Started</button>"),
                    h.raw("<button class='" ++ SecondaryButton.classes ++ "'>View on GitHub</button>"),
                }),
                h.div(.{ .class = "stats-bar" }, .{
                    h.div(.{ .class = "stat" }, .{
                        h.div(.{ .class = "stat-value" }, "17"),
                        h.div(.{ .class = "stat-label" }, "Color Scales"),
                    }),
                    h.div(.{ .class = "stat" }, .{
                        h.div(.{ .class = "stat-value" }, "0ms"),
                        h.div(.{ .class = "stat-label" }, "Runtime Cost"),
                    }),
                    h.div(.{ .class = "stat" }, .{
                        h.div(.{ .class = "stat-value" }, "100%"),
                        h.div(.{ .class = "stat-label" }, "Type Safe"),
                    }),
                }),
            }),
        }),

        // ═══════════════════════════════════════════════════════════════════════════════
        // FEATURES SECTION
        // ═══════════════════════════════════════════════════════════════════════════════
        h.div(.{ .class = "section" }, .{
            h.div(.{ .class = "section-header" }, .{
                h.div(.{ .class = "section-label" }, "Features"),
                h.h2(.{ .class = "section-title" }, "Everything You Need"),
                h.p(.{ .class = "section-desc" }, "A complete design system with colors, typography, spacing, shadows, and more. All generated at compile-time."),
            }),
            h.div(.{ .class = "feature-grid" }, .{
                h.div(.{ .class = FeatureCard.classes }, .{
                    h.div(.{ .class = "feature-icon-wrap", .style = "background:linear-gradient(135deg," ++ design.violet.c100 ++ " 0%," ++ design.purple.c100 ++ " 100%);" }, "🎨"),
                    h.h3(.{ .class = "feature-title" }, "17 Color Scales"),
                    h.p(.{ .class = "feature-desc" }, "Complete palette from slate to rose with 11 shades each. Semantic aliases for primary, success, warning, and danger."),
                }),

                h.div(.{ .class = FeatureCard.classes }, .{
                    h.div(.{ .class = "feature-icon-wrap", .style = "background:linear-gradient(135deg," ++ design.emerald.c100 ++ " 0%," ++ design.teal.c100 ++ " 100%);" }, "⚡"),
                    h.h3(.{ .class = "feature-title" }, "Zero Runtime"),
                    h.p(.{ .class = "feature-desc" }, "All CSS is generated at Zig compile-time. No runtime overhead, no JavaScript, no hydration needed."),
                }),

                h.div(.{ .class = FeatureCard.classes }, .{
                    h.div(.{ .class = "feature-icon-wrap", .style = "background:linear-gradient(135deg," ++ design.blue.c100 ++ " 0%," ++ design.sky.c100 ++ " 100%);" }, "📱"),
                    h.h3(.{ .class = "feature-title" }, "Responsive"),
                    h.p(.{ .class = "feature-desc" }, "Mobile-first breakpoints with sm:, md:, lg:, xl: prefixes. Create adaptive layouts effortlessly."),
                }),

                h.div(.{ .class = FeatureCard.classes }, .{
                    h.div(.{ .class = "feature-icon-wrap", .style = "background:linear-gradient(135deg," ++ design.rose.c100 ++ " 0%," ++ design.pink.c100 ++ " 100%);" }, "🖱️"),
                    h.h3(.{ .class = "feature-title" }, "State Variants"),
                    h.p(.{ .class = "feature-desc" }, "Interactive components with hover:, focus:, and active: states. Even works with breakpoints: hover:md:"),
                }),

                h.div(.{ .class = FeatureCard.classes }, .{
                    h.div(.{ .class = "feature-icon-wrap", .style = "background:linear-gradient(135deg," ++ design.amber.c100 ++ " 0%," ++ design.orange.c100 ++ " 100%);" }, "🔒"),
                    h.h3(.{ .class = "feature-title" }, "Type Safe"),
                    h.p(.{ .class = "feature-desc" }, "Wrong color? Compile error. Invalid property? Compile error. Catch design issues before deployment."),
                }),

                h.div(.{ .class = FeatureCard.classes }, .{
                    h.div(.{ .class = "feature-icon-wrap", .style = "background:linear-gradient(135deg," ++ design.indigo.c100 ++ " 0%," ++ design.violet.c100 ++ " 100%);" }, "🚀"),
                    h.h3(.{ .class = "feature-title" }, "Beautiful"),
                    h.p(.{ .class = "feature-desc" }, "Polished defaults with perfect shadows, smooth transitions, and elegant typography out of the box."),
                }),
            }),
        }),

        // ═══════════════════════════════════════════════════════════════════════════════
        // CODE EXAMPLE SECTION
        // ═══════════════════════════════════════════════════════════════════════════════
        h.div(.{ .class = "section" }, .{
            h.div(.{ .class = "section-header" }, .{
                h.div(.{ .class = "section-label" }, "Usage"),
                h.h2(.{ .class = "section-title" }, "Simple & Intuitive"),
                h.p(.{ .class = "section-desc" }, "Define components at compile-time with full type safety. No magic strings, no runtime bloat."),
            }),
            h.div(.{ .class = "two-col" }, .{
                h.div(.{ .class = "code-section" }, .{
                    h.div(.{ .class = "code-header" }, .{
                        h.div(.{ .class = "code-dot code-dot-red" }, .{}),
                        h.div(.{ .class = "code-dot code-dot-yellow" }, .{}),
                        h.div(.{ .class = "code-dot code-dot-green" }, .{}),
                        h.span(.{ .class = "code-title" }, "button.zig"),
                    }),
                    h.pre(.{ .class = CodeBlock.classes }, "const Button = design.InteractiveComponent(.{\n" ++
                        "    .base = .{\n" ++
                        "        .padding = \"12px 24px\",\n" ++
                        "        .background = design.violet.c600,\n" ++
                        "        .color = \"white\",\n" ++
                        "        .border_radius = design.radius.lg,\n" ++
                        "    },\n" ++
                        "    .hover = .{\n" ++
                        "        .background = design.violet.c700,\n" ++
                        "        .transform = \"translateY(-2px)\",\n" ++
                        "    },\n" ++
                        "    .focus = .{\n" ++
                        "        .box_shadow = \"0 0 0 3px \" ++ design.violet.c300,\n" ++
                        "    },\n" ++
                        "});"),
                }),
                h.div(.{ .class = "interactive-demo" }, .{
                    h.div(.{ .class = "interactive-title" }, "Try it yourself"),
                    h.p(.{ .class = "interactive-desc" }, "These buttons use the exact code shown. Hover, focus with Tab, and click to see the states."),
                    h.div(.{ .class = "button-row" }, .{
                        h.raw("<button class='" ++ PrimaryButton.classes ++ "'>Primary Button</button>"),
                        h.raw("<button class='" ++ DangerButton.classes ++ "'>Danger</button>"),
                    }),
                    h.br(),
                    h.div(.{ .class = "button-row" }, .{
                        h.raw("<button class='" ++ SecondaryButton.classes ++ "'>Secondary</button>"),
                    }),
                }),
            }),
        }),

        // ═══════════════════════════════════════════════════════════════════════════════
        // FORM COMPONENTS SECTION
        // ═══════════════════════════════════════════════════════════════════════════════
        h.div(.{ .class = "section" }, .{
            h.div(.{ .class = "section-header" }, .{
                h.div(.{ .class = "section-label" }, "Forms"),
                h.h2(.{ .class = "section-title" }, "Form Components"),
                h.p(.{ .class = "section-desc" }, "Beautiful, accessible form elements with focus states and smooth transitions."),
            }),
            h.div(.{ .class = "code-section form-demo" }, .{
                h.div(.{ .class = "form-field" }, .{
                    h.label(.{ .class = "form-label" }, "Email address"),
                    h.raw("<input class='" ++ Input.classes ++ "' type='email' placeholder='you@example.com' />"),
                    h.p(.{ .class = "form-hint" }, "We'll never share your email with anyone."),
                }),
                h.div(.{ .class = "form-field" }, .{
                    h.label(.{ .class = "form-label" }, "Full name"),
                    h.raw("<input class='" ++ Input.classes ++ "' type='text' placeholder='John Doe' />"),
                }),
                h.div(.{ .class = SuccessAlert.classes }, .{
                    h.div(.{ .class = "alert-title" }, "Success!"),
                    h.div(.{ .class = "alert-text" }, "Your form has been submitted successfully."),
                }),
            }),
        }),

        // ═══════════════════════════════════════════════════════════════════════════════
        // COLOR PALETTE SHOWCASE
        // ═══════════════════════════════════════════════════════════════════════════════
        h.div(.{ .class = "section" }, .{
            h.div(.{ .class = "section-header" }, .{
                h.div(.{ .class = "section-label" }, "Colors"),
                h.h2(.{ .class = "section-title" }, "Beautiful Palette"),
                h.p(.{ .class = "section-desc" }, "17 carefully crafted color scales with 11 shades each. Perfect for any design."),
            }),
            h.div(.{ .class = "color-grid" }, .{
                // Primary colors
                h.div(.{}, .{
                    h.div(.{ .class = "color-swatch", .style = "background:" ++ design.violet.c500 ++ ";" }, .{}),
                    h.div(.{ .class = "color-info" }, .{
                        h.p(.{ .class = "color-name" }, "Violet"),
                        h.p(.{ .class = "color-hex" }, "violet.c500"),
                    }),
                }),
                h.div(.{}, .{
                    h.div(.{ .class = "color-swatch", .style = "background:" ++ design.indigo.c500 ++ ";" }, .{}),
                    h.div(.{ .class = "color-info" }, .{
                        h.p(.{ .class = "color-name" }, "Indigo"),
                        h.p(.{ .class = "color-hex" }, "indigo.c500"),
                    }),
                }),
                h.div(.{}, .{
                    h.div(.{ .class = "color-swatch", .style = "background:" ++ design.blue.c500 ++ ";" }, .{}),
                    h.div(.{ .class = "color-info" }, .{
                        h.p(.{ .class = "color-name" }, "Blue"),
                        h.p(.{ .class = "color-hex" }, "blue.c500"),
                    }),
                }),
                h.div(.{}, .{
                    h.div(.{ .class = "color-swatch", .style = "background:" ++ design.emerald.c500 ++ ";" }, .{}),
                    h.div(.{ .class = "color-info" }, .{
                        h.p(.{ .class = "color-name" }, "Emerald"),
                        h.p(.{ .class = "color-hex" }, "emerald.c500"),
                    }),
                }),
                h.div(.{}, .{
                    h.div(.{ .class = "color-swatch", .style = "background:" ++ design.rose.c500 ++ ";" }, .{}),
                    h.div(.{ .class = "color-info" }, .{
                        h.p(.{ .class = "color-name" }, "Rose"),
                        h.p(.{ .class = "color-hex" }, "rose.c500"),
                    }),
                }),
                h.div(.{}, .{
                    h.div(.{ .class = "color-swatch", .style = "background:" ++ design.amber.c500 ++ ";" }, .{}),
                    h.div(.{ .class = "color-info" }, .{
                        h.p(.{ .class = "color-name" }, "Amber"),
                        h.p(.{ .class = "color-hex" }, "amber.c500"),
                    }),
                }),
                h.div(.{}, .{
                    h.div(.{ .class = "color-swatch", .style = "background:" ++ design.purple.c500 ++ ";" }, .{}),
                    h.div(.{ .class = "color-info" }, .{
                        h.p(.{ .class = "color-name" }, "Purple"),
                        h.p(.{ .class = "color-hex" }, "purple.c500"),
                    }),
                }),
                h.div(.{}, .{
                    h.div(.{ .class = "color-swatch", .style = "background:" ++ design.pink.c500 ++ ";" }, .{}),
                    h.div(.{ .class = "color-info" }, .{
                        h.p(.{ .class = "color-name" }, "Pink"),
                        h.p(.{ .class = "color-hex" }, "pink.c500"),
                    }),
                }),
            }),
        }),

        // ═══════════════════════════════════════════════════════════════════════════════
        // FOOTER
        // ═══════════════════════════════════════════════════════════════════════════════
        h.div(.{ .class = "footer" }, .{
            h.p(.{ .class = "footer-text" }, "Built with ❤️ using merjs and Zig. The future of web development."),
        }),
    });

    const html = h.render(req.allocator, page_node) catch return mer.internalError("render failed");
    return mer.html(html);
}
