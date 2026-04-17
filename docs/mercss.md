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
- [x] Type-safe design tokens
- [x] Component-level style scoping
- [x] CSS string concatenation at comptime
- [x] Integration with merjs page rendering

### 🚧 Not Yet Implemented (vs Tailwind)
- [ ] Responsive variants (`md:`, `lg:`)
- [ ] State variants (`hover:`, `focus:`, `active:`)
- [ ] Arbitrary value syntax (`[123px]`)
- [ ] Plugin system
- [ ] `@apply` directive equivalent
- [ ] Dark mode support
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

## Design System / Theme

```zig
const Theme = struct {
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

// Type-safe! This will error at compile time:
const bad = mercss.Component(.{
    .background = Theme.colors.nonexistent,  // ❌ Compile error!
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

### v0.3.0 Goals
- [ ] Responsive breakpoints (`sm:`, `md:`, `lg:`)
- [ ] State variants (`hover:`, `focus:`)
- [ ] Property mapping (`border_radius` → `border-radius`)
- [ ] Shorter hash-based class names
- [ ] Streaming CSS (CSS arrives with component chunks)

### v0.4.0 Ideas
- [ ] Container queries
- [ ] Dark mode (`dark:`)
- [ ] Animation keyframes
- [ ] CSS custom properties integration

## Contributing

mercss is experimental! Share ideas:
- What features from Tailwind do you need most?
- What should be different?
- API design feedback welcome

See Issue #90 for discussion on novel streaming CSS approaches.
