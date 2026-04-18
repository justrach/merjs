# mercss — Compile-Time Atomic CSS for merjs

mercss is a zero-runtime, compile-time atomic CSS system built into merjs. It provides Tailwind-inspired utilities with full Zig comptime safety.

## Features

- **Hash-based short class names** — FNV-1a 32-bit hashing produces 6-character class names
- **Responsive breakpoints** — `sm:`, `md:`, `lg:`, `xl:`, `xl2:` with standard Tailwind widths
- **State variants** — `hover:`, `focus:`, `active:` pseudo-class support
- **Dark mode** — `dark:` prefix with `prefers-color-scheme` media query
- **Type-safe design tokens** — spacing, typography, colors, shadows, transitions
- **Zero runtime cost** — all CSS generated at compile time

## Quick Start

```zig
const mer = @import("mer");
const mercss = mer.mercss;
const design = mer.design;

// Define a component with compile-time styles
const Button = mercss.Component(.{
    .base = .{
        .padding = design.space.base,
        .background_color = design.primary.DEFAULT,
        .color = "#ffffff",
        .border_radius = design.radius.md,
    },
    .hover = .{
        .background_color = design.primary.dark,
    },
});

// Use in your page
pub fn render(req: mer.Request) mer.Response {
    const html =
        \\<button class="
    ++ Button.classes ++
        \\">Click Me</button>
    ;
    return mer.html(html);
}
```

## Component API

### `mercss.Component(comptime config: anytype)`

Creates a type with two compile-time constants:

- `.css` — The generated CSS rules as a string
- `.classes` — The space-separated class names as a string

### Configuration Fields

| Field | Purpose |
|-------|---------|
| `.base` | Base styles applied at all breakpoints |
| `.sm` | Styles for `min-width: 640px` |
| `.md` | Styles for `min-width: 768px` |
| `.lg` | Styles for `min-width: 1024px` |
| `.xl` | Styles for `min-width: 1280px` |
| `.xl2` | Styles for `min-width: 1536px` |
| `.dark` | Styles for `prefers-color-scheme: dark` |
| `.hover` | Styles for `:hover` pseudo-class |
| `.focus` | Styles for `:focus` pseudo-class |
| `.active` | Styles for `:active` pseudo-class |

All fields are optional. Only fields you specify will generate CSS.

### Property Naming

Use `snake_case` for CSS properties — they are automatically converted to `kebab-case`:

```zig
.base = .{
    .background_color = "#ffffff",  // → background-color
    .border_radius = "6px",         // → border-radius
    .font_size = "16px",            // → font-size
}
```

### Value Types

- **Strings**: Used directly as CSS values (`"16px"`, `"#3b82f6"`, `"none"`)
- **Integers**: Automatically get `px` suffix (`16` → `"16px"`)
- **Floats**: Automatically get `px` suffix (`1.5` → `"1.5px"`)
- **Booleans**: Convert to `1` or `0`

## Design System

The `mer.design` module provides Tailwind-inspired design tokens:

### Spacing (4px grid)

```zig
design.space.px    // "1px"
design.space.xs    // "4px"
design.space.sm    // "8px"
design.space.base  // "16px"
design.space.lg    // "24px"
design.space.xl    // "32px"
// ... up to xl6
```

### Typography

```zig
design.font.family.sans    // System font stack
design.font.family.serif   // Serif font stack
design.font.family.mono    // Monospace font stack

design.font.size.xs        // "12px"
design.font.size.base      // "16px"
design.font.size.xl3       // "30px"
// ... up to xl8

design.font.weight.normal  // "400"
design.font.weight.bold    // "700"
// ... etc

design.font.leading.base   // "1.5"
design.font.tracking.tight // "-0.025em"
```

### Colors

17 color scales with 11 shades each:

```zig
design.slight.c500         // Default shade
design.slight.lightest     // c50
design.slight.darkest      // c900

// Available: slate, gray, zinc, neutral, stone,
// red, orange, amber, yellow, lime, green, emerald, teal,
// cyan, sky, blue, indigo, violet, purple, fuchsia, pink, rose

// Semantic aliases
design.primary.DEFAULT     // blue
design.success.DEFAULT     // emerald
design.danger.DEFAULT      // red
design.warning.DEFAULT     // amber
design.info.DEFAULT        // sky
```

### Shadows & Effects

```zig
design.shadow.xs           // Subtle shadow
design.shadow.md           // Medium shadow
design.shadow.xl2          // Large shadow
design.shadow.inner        // Inset shadow

design.blur.sm             // "4px"
design.blur.lg             // "12px"
```

### Transitions

```zig
design.transition.fast     // 100ms
design.transition.base     // 150ms
design.transition.slow     // 300ms

design.ease.in_out         // cubic-bezier(0.4, 0, 0.2, 1)

design.duration.xs         // "75ms"
design.duration.lg         // "300ms"
```

### Other Tokens

```zig
design.radius.md           // "6px"
design.radius.full         // "9999px"

design.z.dropdown          // "10"
design.z.modal             // "50"

design.opacity.base        // "0.5"

design.size.full           // "100%"
design.size.screen         // "100vh"
```

## Utility Functions

### `mercss.generateStylesheet(comptime components)`

Combines multiple components into a complete stylesheet:

```zig
const sheet = mercss.generateStylesheet(.{
    .button = Button,
    .card = Card,
});
// Returns: "/* mercss generated stylesheet */\n/* button */\n..."
```

### `mercss.getAllClasses(comptime components)`

Collects all class names from multiple components:

```zig
const classes = mercss.getAllClasses(.{
    .button = Button,
    .card = Card,
});
// Returns: "mAbc123 mDef456 mGhi789 ..."
```

## Injecting CSS into Pages

### Via `extra_head` in meta

```zig
pub const meta: mer.Meta = .{
    .title = "My Page",
    .extra_head = "<style>" ++ Button.css ++ Card.css ++ "</style>",
};
```

### Via a separate stylesheet

Generate the stylesheet at compile time and serve it as a static file, or inline it directly.

## Complete Example

```zig
const mer = @import("mer");
const mercss = mer.mercss;
const design = mer.design;

const Card = mercss.Component(.{
    .base = .{
        .padding = design.space.xl,
        .background_color = "#ffffff",
        .border_radius = design.radius.lg,
        .box_shadow = design.shadow.md,
    },
    .md = .{
        .padding = design.space.xl2,
    },
    .dark = .{
        .background_color = design.slate.c800,
        .color = design.slate.c100,
    },
});

const Button = mercss.Component(.{
    .base = .{
        .padding = design.space.base,
        .background_color = design.primary.DEFAULT,
        .color = "#ffffff",
        .border_radius = design.radius.md,
    },
    .hover = .{
        .background_color = design.primary.dark,
    },
    .focus = .{
        .outline = "2px solid " ++ design.primary.light,
    },
});

const all_css = Card.css ++ Button.css;

pub const meta: mer.Meta = .{
    .title = "mercss Example",
    .extra_head = "<style>" ++ all_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    _ = req;
    const html =
        \\<div class="
    ++ Card.classes ++
        \\">
        \\  <h2>Card Title</h2>
        \\  <p>Card content here.</p>
        \\  <button class="
    ++ Button.classes ++
        \\">Action</button>
        \\</div>
    ;
    return mer.html(html);
}
```

## Limitations

- All styling must be known at compile time — no dynamic runtime values
- Property names use `snake_case` (not `kebab-case`) due to Zig identifier rules
- The design system provides common tokens but you can use any string values
- Responsive breakpoints follow Tailwind defaults but are not configurable at runtime

## Demo

See `examples/site/app/mercss-demo.zig` for a live demonstration of all features.
