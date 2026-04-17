# mercss in Next.js? Feasibility Analysis

## Question
> Can mercss be used in a Next.js app? What are the obstacles?

## Short Answer
**No, not directly.** mercss is specifically designed for Zig/merjs. For Next.js, use **Tailwind CSS** - it's already perfect for that ecosystem.

## Why mercss ≠ Next.js

### 1. Language Mismatch
| mercss | Next.js |
|--------|---------|
| Zig (systems language) | JavaScript/TypeScript |
| Compile-time evaluation | Runtime/build-time |
| `@import("mercss")` | `npm install tailwindcss` |

### 2. Build System Incompatibility
```
mercss flow:
Zig source → Zig compiler → CSS (at comptime)

Next.js flow:
TSX/JSX → Webpack/Turbopack → Bundled JS + PostCSS → CSS
```

### 3. Import Systems Don't Align
- mercss: `@import("mercss")` - Zig module system
- Next.js: `import styles from './styles.css'` - JS module system

### 4. Runtime vs Compile-time
- mercss generates CSS **during Zig compilation**
- Next.js expects CSS **during webpack build**
- No bridge exists between these

## Potential Integration Approaches (All Have Issues)

### Option A: CLI Tool
Create a `mercss-cli` that:
1. Scans JS/TS files for style definitions
2. Generates CSS at build time
3. Outputs `.css` file for Next.js

**Problem:**
- Where do you define styles? In JS comments? Separate file?
- Loses type-safety (Zig's advantage)
- Just becomes a worse Tailwind

### Option B: WASM Bridge
Compile mercss to WASM, run in Node.js during Next.js build.

**Problem:**
- Complex build pipeline
- Still need to define styles somewhere
- Overhead for marginal benefit

### Option C: Schema/JSON Based
Define styles in JSON, both Zig and JS read it.

**Problem:**
- Loses compile-time type safety
- Loses Zig's comptime power
- Just JSON config like Tailwind

### Option D: Tailwind Plugin
Create a Tailwind plugin with mercss-like conventions.

**Problem:**
- Not actually mercss
- Just different Tailwind config
- No Zig involved

## Recommendation

**Use Tailwind CSS for Next.js.** It's:
- ✅ Mature ecosystem
- ✅ IDE support (IntelliSense)
- ✅ Perfect Next.js integration
- ✅ JIT compiler for arbitrary values
- ✅ Huge community

**Use mercss for merjs.** It's:
- ✅ Type-safe at compile time
- ✅ Zero build overhead (Zig is the build)
- ✅ No purging needed
- ✅ Integrates with Zig's comptime power

## What mercss Gives You (That Tailwind Can't)

```zig
// Type-safe design tokens
const Button = mercss.Component(.{
    .background = DesignSystem.colors.primary,  // Compile error if wrong
    .padding = DesignSystem.spacing.md,         // Type-safe spacing
});

// Zig knows all components at compile time
// No scanning, no purging, no build step
```

Tailwind can't do this because:
- JS doesn't have comptime
- Can't know all classes at build time (must scan files)
- Needs PurgeCSS to remove unused styles

## The Real Value of mercss

mercss isn't trying to replace Tailwind in Next.js. It's bringing Tailwind-like ergonomics to **Zig web development**.

**merjs + mercss = Next.js + Tailwind for Zig**

## If You Really Want It

You could theoretically:
1. Define styles in a `.zig` file
2. Run `zig build css` to generate `.css`
3. Import that CSS in Next.js

But at that point... just use Tailwind.

## Conclusion

**Different ecosystems, different tools.**

- Next.js → Tailwind CSS  
- merjs → mercss

Don't cross the streams. Use the right tool for the job.
