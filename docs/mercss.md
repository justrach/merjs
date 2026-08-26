# mercss - Compile-time Atomic CSS for merjs

mercss generates type-safe, atomic CSS at **compile time** using Zig's `comptime`. Unlike Tailwind CSS which needs a build pipeline (PostCSS → JIT → Purge), mercss generates CSS during Zig compilation with **zero runtime cost**.

## Quick Start

```zig
const mer = @import("mer");
const mercss = mer.mercss;

// Define component styles at compile time
const Button = mercss.Component(.{
    .background = "#3b82f6",
    .color = "white",
    .padding = "12px 24px",
    .border_radius = "8px",
    .font_weight = "600",
});

// Use in your page
pub const meta: mer.Meta = .{
    .extra_head = "<style>" ++ Button.css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, 
        h.button(.{ .class = Button.classes }, "Click Me")
    );
}
```

## How It Works

1. **Define styles** as Zig structs with design tokens
2. **Compile time**: Zig analyzes the struct fields
3. **CSS generation**: One atomic rule per property (`.mcss-padding{padding:12px}`)
4. **Class generation**: Component gets all classes (`.mcss-padding .mcss-background`)
5. **Zero runtime**: All strings are comptime constants

## Comparison with Tailwind CSS

| Feature | Tailwind CSS | mercss (merjs) |
|---------|--------------|----------------|
| **Build step** | PostCSS → JIT → PurgeCSS | ❌ None (Zig comptime) |
| **File scanning** | Scans all source files | ❌ Not needed (comptime knows all) |
| **Type safety** | Runtime errors for wrong classes | ✅ Compile-time errors |
| **Config** | `tailwind.config.js` | ✅ Zig structs (type-safe) |
| **Unused styles** | Need PurgeCSS | ❌ Never generated |
| **Bundle size** | ~10KB (purged) | ~500 bytes (actual used) |
| **Arbitrary values** | `w-[123px]` (runtime) | ✅ `width = 123` (comptime) |
| **JIT mode** | Required for arbitrary values | ❌ Not needed (all comptime) |
| **Plugins** | JavaScript-based | ✅ Zig functions |
| **IDE support** | Tailwind IntelliSense | 🚧 Coming soon |

## Current mercss Features

### ✅ Implemented
- [x] Atomic CSS generation from structs
- [x] Compile-time class name generation
- [x] Type-safe design tokens (`mer.design` — 17 color scales × 11 shades)
- [x] Component-level style scoping
- [x] CSS string concatenation at comptime
- [x] Integration with merjs page rendering
- [x] Responsive variants (`sm`, `md`, `lg`, `xl`, `xl2`) → `@media (min-width: …)`
- [x] State variants (`hover`, `focus`, `active`) → `.cls:hover { … }`
- [x] Dark mode via `prefers-color-scheme`
- [x] Property-name mapping (`border_radius` → `border-radius`)
- [x] Shorter, content-addressed hashed class names (`HashedComponent`)
- [x] `generateStylesheet` / `getAllClasses` helpers

### 🚧 Not Yet Implemented (vs Tailwind)
- [ ] Arbitrary value syntax (`[123px]`) as a dedicated parser
- [ ] Plugin system
- [ ] `@apply` directive equivalent
- [ ] Container queries
- [ ] CSS grid helpers
- [ ] Typography plugin
- [ ] Form elements reset
- [ ] Animation utilities
- [ ] Transform/transition utilities

### 🎯 Different Approach from Tailwind

**Tailwind:** Utility-first, thousands of pre-generated classes, purge unused ones
```html
<button class="px-4 py-2 bg-blue-500 text-white rounded hover:bg-blue-600">
```

**mercss:** Generate only what you use, type-safe, compile-time
```zig
const Button = mercss.Component(.{
    .padding = "8px 16px",
    .background = "#3b82f6",
    .color = "white",
    .border_radius = "6px",
});
// Generates: .mcss-padding{padding:8px 16px} .mcss-background{background:#3b82f6} ...
```

## Tailwind-parity feature reference (#91)

### 1. Property-name mapping (kebab-case)

Struct field names use Zig's `snake_case`; mercss maps them to CSS `kebab-case`
properties automatically at comptime.

```zig
const Box = mercss.Component(.{ .border_radius = "6px", .background_color = "#fff" });
// Box.css == ".mcss-border_radius{border-radius:6px;}.mcss-background_color{background-color:#fff;}"
```

Integer / float values become pixels (`.margin_top = 12` → `margin-top:12px;`).

### 2. Responsive prefixes → `@media (min-width: …)`

```zig
const Box = mercss.ResponsiveComponent(.{
    .base = .{ .padding = "8px" },
    .md   = .{ .font_size = "18px" },
});
// Box.css contains:
//   .mcss-padding{padding:8px;}
//   @media (min-width: 768px){.mcss-md-font_size{font-size:18px;}}
```

Breakpoints: `sm` 640px, `md` 768px, `lg` 1024px, `xl` 1280px, `xl2` 1536px.

### 3. State variants → `.cls:hover { … }`

```zig
const Btn = mercss.Component(.{
    .base   = .{ .background = "#3b82f6" },
    .hover  = .{ .background_color = "#2563eb" },
    .focus  = .{ .outline = "2px solid #93c5fd" },
    .active = .{ .background = "#1d4ed8" },
});
// Btn.css contains:
//   .mcss-hover-background_color:hover{background-color:#2563eb;}
//   .mcss-focus-outline:focus{outline:2px solid #93c5fd;}
//   .mcss-active-background:active{background:#1d4ed8;}
```

`Component(...)` auto-detects the variant shape (presence of `base`/`sm`/`hover`/…)
and dispatches to `ResponsiveComponent`, so flat and variant configs use the same
entry point.

### 4. Shorter, hashed atomic class names (`HashedComponent`)

The default `Component` emits readable `.mcss-<property>` names. For pages with
many components those names get long and repeat identical atomic rules.
`HashedComponent` derives a short class name from each rule's *content*
(`property:value`), so identical atomic rules collapse onto one class name across
components — true atomic-CSS deduplication.

```zig
const Primary = mercss.HashedComponent(.{ .background = "#3b82f6", .border_radius = "6px" });
// Primary.css     == ".mc-<hash>{background:#3b82f6;}.mc-<hash>{border-radius:6px;}"
// Primary.classes == "mc-<hash> mc-<hash>"

const Ghost = mercss.HashedComponent(.{ .background = "#3b82f6", .border_radius = "999px" });
// Ghost shares Primary's `background:#3b82f6` class name (same hash) — deduped.
```

Hashing is FNV-1a → base36, evaluated entirely at comptime (no runtime cost).
`HashedComponent` is opt-in; existing pages keep the stable `mcss-*` names.

## Design System / Theme

`mer.design` (from yxlyx #92/#95) is the public token set. `mercss.DesignSystem` remains as a small built-in fallback.

```zig
const mer = @import("mer");
const design = mer.design;
const mercss = mer.mercss;

const Button = mercss.Component(.{
    .base = .{
        .padding = design.space.base,
        .background_color = design.primary.DEFAULT,
        .color = "#ffffff",
        .border_radius = design.radius.md,
        .transition = design.transition.base,
    },
    .hover = .{
        .background_color = design.primary.dark,
    },
    .dark = .{
        .background_color = design.slate.c800,
        .color = design.slate.c100,
    },
    .md = .{
        .padding = design.space.xl,
    },
});
```

Tokens include `design.space`, `design.font`, 17 color scales (`design.blue.c500`, aliases like `design.primary`), `design.shadow`, `design.blur`, `design.transition`, `design.ease`, `design.duration`, `design.radius`, `design.z`, `design.opacity`, and `design.size`.

Flat style structs still work:

```zig
const Chip = mercss.Component(.{
    .padding = "8px 16px",
    .background = design.primary.DEFAULT,
});
```

## Server Setup (Important!)

When running the merjs server for local development, use one of these methods:

### Method 1: Direct (foreground)
```bash
cd /path/to/your/merjs/project
zig build
./zig-out/bin/merjs --port 3000 --no-dev
```
Server runs in foreground. Stop with `Ctrl+C`.

### Method 2: Background with nohup (recommended)
```bash
zig build
nohup ./zig-out/bin/merjs --port 3000 --no-dev > merjs.log 2>&1 &
```
- Server keeps running even if terminal closes
- Logs go to `merjs.log`
- Stop with: `pkill -f "merjs"`

### Method 3: Docker
```bash
docker build -t merjs .
docker run -p 3000:3000 merjs
```

### Common Issues

**"Connection refused" / Server crashes:**
- Check if port is already in use: `lsof -i :3000`
- Use a different port: `--port 3001`
- Ensure binary exists: `ls zig-out/bin/merjs`
- Check logs: `cat /tmp/merjs.log`

**Server stops when terminal closes:**
- Use `nohup` as shown above
- Or use Docker/containerization

## Roadmap

### v0.2.54
- [x] Responsive breakpoints (`sm`, `md`, `lg`, `xl`, `xl2`)
- [x] State variants (`hover`, `focus`, `active`)
- [x] Dark mode (`prefers-color-scheme`)
- [x] `mer.design` token system
- [x] Property mapping (`border_radius` → `border-radius`)
- [x] Shorter hash-based class names via `HashedComponent` (opt-in; `mcss-*` kept as default to avoid breaking existing pages)

### Later
- [ ] Streaming CSS (CSS arrives with component chunks)
- [ ] Container queries
- [ ] Animation keyframes
- [ ] CSS custom properties integration

## Contributing

mercss is experimental! Share ideas:
- What features from Tailwind do you need most?
- What should be different?
- API design feedback welcome

See Issue #90 for discussion on novel streaming CSS approaches.
