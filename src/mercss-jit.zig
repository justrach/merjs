//! mercss-jit.zig — JIT utility-class CSS engine for merjs.
//!
//! Inspired by Tailwind v4 (Oxide). Three pieces:
//!   1. Scanner — walks source bytes, extracts class="..." candidates.
//!   2. Parser  — turns each candidate into a Candidate struct
//!                (variants, utility, value, modifier).
//!   3. Compile — DesignSystem (tokens + utility registry) emits one
//!                stylesheet from a candidate list.
//!
//! Coexists with src/mercss.zig (the comptime struct-based engine).
//! No variants in this first cut — just the scanner / parser / utility
//! pipeline. hover/md/dark land in a follow-up.

const std = @import("std");

// ============================================================================
// Candidate: the parsed form of one class name.
// ============================================================================

pub const Value = union(enum) {
    /// Static utility with no value (e.g. "flex", "hidden").
    none,
    /// Token-named value (e.g. "red-500" in "bg-red-500", "4" in "p-4").
    named: []const u8,
    /// User-supplied arbitrary value (e.g. "123px" in "w-[123px]").
    arbitrary: []const u8,
};

pub const Candidate = struct {
    raw: []const u8,
    variants: [][]const u8,
    utility: []const u8,
    value: Value,
    modifier: ?[]const u8 = null,

    pub fn deinit(self: *Candidate, alloc: std.mem.Allocator) void {
        alloc.free(self.variants);
    }
};

/// Parse one raw candidate string. Returns null if malformed.
///   "flex"                 → utility="flex", value=.none
///   "p-4"                  → utility="p",    value=.named("4")
///   "bg-red-500"           → utility="bg",   value=.named("red-500")
///   "w-[123px]"            → utility="w",    value=.arbitrary("123px")
///   "md:hover:bg-red-500"  → variants=[md,hover], utility="bg", value=.named("red-500")
///   "bg-red-500/50"        → utility="bg", value=.named("red-500"), modifier="50"
pub fn parseCandidate(alloc: std.mem.Allocator, raw: []const u8) !?Candidate {
    if (raw.len == 0) return null;

    var rest = raw;
    var variants: std.ArrayList([]const u8) = .empty;
    errdefer variants.deinit(alloc);

    while (findUnbracketed(rest, ':')) |colon| {
        try variants.append(alloc, rest[0..colon]);
        rest = rest[colon + 1 ..];
    }

    if (rest.len == 0) {
        variants.deinit(alloc);
        return null;
    }

    var modifier: ?[]const u8 = null;
    if (findUnbracketed(rest, '/')) |slash| {
        modifier = rest[slash + 1 ..];
        rest = rest[0..slash];
    }

    const utility: []const u8 = blk: {
        if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
            const u = rest[0..dash];
            rest = rest[dash + 1 ..];
            break :blk u;
        }
        const u = rest;
        rest = &.{};
        break :blk u;
    };

    const value: Value = if (rest.len == 0)
        .none
    else if (rest.len >= 2 and rest[0] == '[' and rest[rest.len - 1] == ']')
        .{ .arbitrary = rest[1 .. rest.len - 1] }
    else
        .{ .named = rest };

    return Candidate{
        .raw = raw,
        .variants = try variants.toOwnedSlice(alloc),
        .utility = utility,
        .value = value,
        .modifier = modifier,
    };
}

fn findUnbracketed(s: []const u8, ch: u8) ?usize {
    var depth: usize = 0;
    for (s, 0..) |c, i| switch (c) {
        '[' => depth += 1,
        ']' => if (depth > 0) {
            depth -= 1;
        },
        else => if (c == ch and depth == 0) return i,
    };
    return null;
}

// ============================================================================
// Scanner: extract candidate strings from source content.
// ============================================================================

/// Walk `source`, find every `class="..."` literal (HTML form OR Zig form
/// `.class = "..."`), split on whitespace, append each token to `out`.
/// Tokens borrow from `source` — keep `source` alive while you use them.
pub fn scan(source: []const u8, alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i + 5 <= source.len) {
        if (!std.mem.eql(u8, source[i .. i + 5], "class")) {
            i += 1;
            continue;
        }
        if (i > 0 and isIdentChar(source[i - 1])) {
            i += 1;
            continue;
        }
        var j = i + 5;
        while (j < source.len and (source[j] == ' ' or source[j] == '\t')) j += 1;
        if (j >= source.len or source[j] != '=') {
            i = j;
            continue;
        }
        j += 1;
        while (j < source.len and (source[j] == ' ' or source[j] == '\t')) j += 1;
        if (j >= source.len or source[j] != '"') {
            i = j;
            continue;
        }
        j += 1;
        const start = j;
        while (j < source.len and source[j] != '"') j += 1;
        var it = std.mem.tokenizeAny(u8, source[start..j], " \t\n\r");
        while (it.next()) |tok| try out.append(alloc, tok);
        i = j + 1;
    }
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

// ============================================================================
// DesignSystem: tokens + utility registry.
// ============================================================================

pub const Sink = std.ArrayList(u8);

pub const UtilityFn = *const fn (
    ds: *const DesignSystem,
    cand: Candidate,
    sink: *Sink,
    alloc: std.mem.Allocator,
) anyerror!void;

pub const Variant = union(enum) {
    /// Pseudo-class suffix on the selector (e.g. ":hover").
    pseudo: []const u8,
    /// Media query condition (e.g. "(min-width: 768px)").
    media: []const u8,
};

pub const DesignSystem = struct {
    alloc: std.mem.Allocator,
    /// CSS custom properties → emitted as `:root { --foo: bar; }`.
    tokens: std.StringHashMap([]const u8),
    /// Utility registry: "p" → padding emitter, "bg" → background-color, etc.
    utilities: std.StringHashMap(UtilityFn),
    /// Variant registry: "hover" → :hover, "md" → (min-width: 768px), etc.
    variants: std.StringHashMap(Variant),

    pub fn init(alloc: std.mem.Allocator) DesignSystem {
        return .{
            .alloc = alloc,
            .tokens = std.StringHashMap([]const u8).init(alloc),
            .utilities = std.StringHashMap(UtilityFn).init(alloc),
            .variants = std.StringHashMap(Variant).init(alloc),
        };
    }

    pub fn deinit(self: *DesignSystem) void {
        self.tokens.deinit();
        self.utilities.deinit();
        self.variants.deinit();
    }

    pub fn putToken(self: *DesignSystem, name: []const u8, value: []const u8) !void {
        try self.tokens.put(name, value);
    }

    pub fn putUtility(self: *DesignSystem, name: []const u8, fn_: UtilityFn) !void {
        try self.utilities.put(name, fn_);
    }

    pub fn putVariant(self: *DesignSystem, name: []const u8, v: Variant) !void {
        try self.variants.put(name, v);
    }

    /// Seed with a baseline of brand colors, spacing, ~16 utilities, and
    /// the standard hover/focus/md/lg/xl/dark variants.
    pub fn loadDefaults(self: *DesignSystem) !void {
        // Spacing base: every spacing utility is calc(var(--spacing) * N).
        try self.putToken("--spacing", "0.25rem");

        // Brand palette (mercss red).
        try self.putToken("--color-brand-50", "#fef2f2");
        try self.putToken("--color-brand-100", "#fee2e2");
        try self.putToken("--color-brand-200", "#fecaca");
        try self.putToken("--color-brand-500", "#e8251f");
        try self.putToken("--color-brand-600", "#ca1f1a");
        try self.putToken("--color-brand-700", "#9f1815");
        try self.putToken("--color-brand-900", "#5b0c0a");

        // Slate (neutral).
        try self.putToken("--color-slate-50", "#f8fafc");
        try self.putToken("--color-slate-200", "#e2e8f0");
        try self.putToken("--color-slate-500", "#64748b");
        try self.putToken("--color-slate-700", "#334155");
        try self.putToken("--color-slate-900", "#0f172a");

        try self.putToken("--color-white", "#ffffff");
        try self.putToken("--color-black", "#000000");

        // Radius scale.
        try self.putToken("--radius-sm", "0.25rem");
        try self.putToken("--radius-md", "0.5rem");
        try self.putToken("--radius-lg", "0.75rem");
        try self.putToken("--radius-xl", "1rem");
        try self.putToken("--radius-full", "9999px");

        // Font size scale.
        try self.putToken("--text-xs", "0.75rem");
        try self.putToken("--text-sm", "0.875rem");
        try self.putToken("--text-base", "1rem");
        try self.putToken("--text-lg", "1.125rem");
        try self.putToken("--text-xl", "1.25rem");
        try self.putToken("--text-2xl", "1.5rem");

        // Static-display utilities.
        try self.putUtility("flex", emitFlex);
        try self.putUtility("grid", emitGrid);
        try self.putUtility("block", emitBlock);
        try self.putUtility("hidden", emitHidden);

        // Spacing.
        try self.putUtility("p", emitP);
        try self.putUtility("px", emitPx);
        try self.putUtility("py", emitPy);
        try self.putUtility("m", emitM);
        try self.putUtility("gap", emitGap);

        // Sizing.
        try self.putUtility("w", emitW);
        try self.putUtility("h", emitH);

        // Color & border.
        try self.putUtility("bg", emitBg);
        try self.putUtility("text", emitText);
        try self.putUtility("border", emitBorder);

        // Border radius.
        try self.putUtility("rounded", emitRounded);

        // Font weight.
        try self.putUtility("font", emitFont);

        // Variants.
        try self.putVariant("hover", .{ .pseudo = ":hover" });
        try self.putVariant("focus", .{ .pseudo = ":focus" });
        try self.putVariant("active", .{ .pseudo = ":active" });
        try self.putVariant("disabled", .{ .pseudo = ":disabled" });
        try self.putVariant("md", .{ .media = "(min-width: 768px)" });
        try self.putVariant("lg", .{ .media = "(min-width: 1024px)" });
        try self.putVariant("xl", .{ .media = "(min-width: 1280px)" });
        try self.putVariant("dark", .{ .media = "(prefers-color-scheme: dark)" });
    }
};

// ----------------------------------------------------------------------------
// Utility emitters
// ----------------------------------------------------------------------------

fn emitFlex(_: *const DesignSystem, _: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    try sink.appendSlice(alloc, "display:flex");
}
fn emitGrid(_: *const DesignSystem, _: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    try sink.appendSlice(alloc, "display:grid");
}
fn emitBlock(_: *const DesignSystem, _: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    try sink.appendSlice(alloc, "display:block");
}
fn emitHidden(_: *const DesignSystem, _: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    try sink.appendSlice(alloc, "display:none");
}

fn writeSpacing(prop: []const u8, value: Value, sink: *Sink, alloc: std.mem.Allocator) !void {
    switch (value) {
        .arbitrary => |v| try sink.print(alloc, "{s}:{s}", .{ prop, v }),
        .named => |v| try sink.print(alloc, "{s}:calc(var(--spacing) * {s})", .{ prop, v }),
        .none => {},
    }
}

fn emitP(_: *const DesignSystem, c: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    try writeSpacing("padding", c.value, sink, alloc);
}
fn emitPx(_: *const DesignSystem, c: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    switch (c.value) {
        .arbitrary => |v| try sink.print(alloc, "padding-left:{s};padding-right:{s}", .{ v, v }),
        .named => |v| try sink.print(alloc, "padding-left:calc(var(--spacing) * {s});padding-right:calc(var(--spacing) * {s})", .{ v, v }),
        .none => {},
    }
}
fn emitPy(_: *const DesignSystem, c: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    switch (c.value) {
        .arbitrary => |v| try sink.print(alloc, "padding-top:{s};padding-bottom:{s}", .{ v, v }),
        .named => |v| try sink.print(alloc, "padding-top:calc(var(--spacing) * {s});padding-bottom:calc(var(--spacing) * {s})", .{ v, v }),
        .none => {},
    }
}
fn emitM(_: *const DesignSystem, c: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    try writeSpacing("margin", c.value, sink, alloc);
}
fn emitGap(_: *const DesignSystem, c: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    try writeSpacing("gap", c.value, sink, alloc);
}

fn emitW(_: *const DesignSystem, c: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    switch (c.value) {
        .arbitrary => |v| try sink.print(alloc, "width:{s}", .{v}),
        .named => |v| {
            if (std.mem.eql(u8, v, "full")) try sink.appendSlice(alloc, "width:100%") //
            else if (std.mem.eql(u8, v, "screen")) try sink.appendSlice(alloc, "width:100vw") //
            else if (std.mem.eql(u8, v, "auto")) try sink.appendSlice(alloc, "width:auto") //
            else try sink.print(alloc, "width:calc(var(--spacing) * {s})", .{v});
        },
        .none => {},
    }
}
fn emitH(_: *const DesignSystem, c: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    switch (c.value) {
        .arbitrary => |v| try sink.print(alloc, "height:{s}", .{v}),
        .named => |v| {
            if (std.mem.eql(u8, v, "full")) try sink.appendSlice(alloc, "height:100%") //
            else if (std.mem.eql(u8, v, "screen")) try sink.appendSlice(alloc, "height:100vh") //
            else if (std.mem.eql(u8, v, "auto")) try sink.appendSlice(alloc, "height:auto") //
            else try sink.print(alloc, "height:calc(var(--spacing) * {s})", .{v});
        },
        .none => {},
    }
}

fn emitBg(ds: *const DesignSystem, c: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    switch (c.value) {
        .arbitrary => |v| try sink.print(alloc, "background-color:{s}", .{v}),
        .named => |v| try emitColorRef(ds, "background-color", v, sink, alloc),
        .none => {},
    }
}
fn emitText(ds: *const DesignSystem, c: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    switch (c.value) {
        .arbitrary => |v| try sink.print(alloc, "color:{s}", .{v}),
        .named => |v| {
            // Color first, then size fallback.
            if (try tryColorRef(ds, "color", v, sink, alloc)) return;
            if (isSizeName(v)) try sink.print(alloc, "font-size:var(--text-{s})", .{v});
        },
        .none => {},
    }
}
fn emitBorder(ds: *const DesignSystem, c: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    switch (c.value) {
        .arbitrary => |v| try sink.print(alloc, "border:1px solid {s}", .{v}),
        .named => |v| try emitColorRef(ds, "border-color", v, sink, alloc),
        .none => try sink.appendSlice(alloc, "border-width:1px;border-style:solid"),
    }
}
fn emitRounded(_: *const DesignSystem, c: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    switch (c.value) {
        .arbitrary => |v| try sink.print(alloc, "border-radius:{s}", .{v}),
        .named => |v| try sink.print(alloc, "border-radius:var(--radius-{s})", .{v}),
        .none => try sink.appendSlice(alloc, "border-radius:var(--radius-md)"),
    }
}
fn emitFont(_: *const DesignSystem, c: Candidate, sink: *Sink, alloc: std.mem.Allocator) !void {
    switch (c.value) {
        .named => |v| {
            if (std.mem.eql(u8, v, "thin")) try sink.appendSlice(alloc, "font-weight:100") //
            else if (std.mem.eql(u8, v, "light")) try sink.appendSlice(alloc, "font-weight:300") //
            else if (std.mem.eql(u8, v, "normal")) try sink.appendSlice(alloc, "font-weight:400") //
            else if (std.mem.eql(u8, v, "medium")) try sink.appendSlice(alloc, "font-weight:500") //
            else if (std.mem.eql(u8, v, "semibold")) try sink.appendSlice(alloc, "font-weight:600") //
            else if (std.mem.eql(u8, v, "bold")) try sink.appendSlice(alloc, "font-weight:700") //
            else if (std.mem.eql(u8, v, "black")) try sink.appendSlice(alloc, "font-weight:900");
        },
        else => {},
    }
}

fn emitColorRef(
    ds: *const DesignSystem,
    prop: []const u8,
    value_name: []const u8,
    sink: *Sink,
    alloc: std.mem.Allocator,
) !void {
    _ = try tryColorRef(ds, prop, value_name, sink, alloc);
}

fn tryColorRef(
    ds: *const DesignSystem,
    prop: []const u8,
    value_name: []const u8,
    sink: *Sink,
    alloc: std.mem.Allocator,
) !bool {
    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "--color-{s}", .{value_name}) catch return false;
    if (!ds.tokens.contains(key)) return false;
    try sink.print(alloc, "{s}:var({s})", .{ prop, key });
    return true;
}

fn isSizeName(s: []const u8) bool {
    const sizes = [_][]const u8{ "xs", "sm", "base", "lg", "xl", "2xl" };
    for (sizes) |sz| if (std.mem.eql(u8, s, sz)) return true;
    return false;
}

// ============================================================================
// compile: candidates → CSS string.
// ============================================================================

/// Emit a complete stylesheet from a list of candidate strings.
/// Caller owns the returned slice.
/// Emit a complete stylesheet from a list of candidate strings.
/// Caller owns the returned slice.
pub fn compile(
    alloc: std.mem.Allocator,
    ds: *const DesignSystem,
    candidates: []const []const u8,
) ![]u8 {
    var sink: Sink = .empty;
    errdefer sink.deinit(alloc);

    try sink.appendSlice(alloc, ":root {\n");
    var tok_it = ds.tokens.iterator();
    while (tok_it.next()) |entry| {
        try sink.print(alloc, "  {s}: {s};\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    try sink.appendSlice(alloc, "}\n\n");

    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    var pseudos: std.ArrayList([]const u8) = .empty;
    defer pseudos.deinit(alloc);
    var medias: std.ArrayList([]const u8) = .empty;
    defer medias.deinit(alloc);

    for (candidates) |raw| {
        if (raw.len == 0) continue;
        if (seen.contains(raw)) continue;
        try seen.put(raw, {});

        var cand = (try parseCandidate(alloc, raw)) orelse continue;
        defer cand.deinit(alloc);

        const emit = ds.utilities.get(cand.utility) orelse continue;

        // Resolve all variants up front; skip the rule if any are unknown.
        pseudos.clearRetainingCapacity();
        medias.clearRetainingCapacity();
        var unknown_variant = false;
        for (cand.variants) |v_name| {
            const v = ds.variants.get(v_name) orelse {
                unknown_variant = true;
                break;
            };
            switch (v) {
                .pseudo => |s| try pseudos.append(alloc, s),
                .media => |s| try medias.append(alloc, s),
            }
        }
        if (unknown_variant) continue;

        var body: Sink = .empty;
        defer body.deinit(alloc);
        try emit(ds, cand, &body, alloc);
        if (body.items.len == 0) continue;

        // Open one @media wrapper per media variant (outer-to-inner).
        for (medias.items) |m| try sink.print(alloc, "@media {s} {{ ", .{m});

        try sink.append(alloc, '.');
        try writeEscapedSelector(raw, &sink, alloc);
        for (pseudos.items) |p| try sink.appendSlice(alloc, p);
        try sink.appendSlice(alloc, " { ");
        try sink.appendSlice(alloc, body.items);
        try sink.appendSlice(alloc, " }");

        for (medias.items) |_| try sink.appendSlice(alloc, " }");
        try sink.append(alloc, '\n');
    }

    return sink.toOwnedSlice(alloc);
}

fn writeEscapedSelector(raw: []const u8, sink: *Sink, alloc: std.mem.Allocator) !void {
    // CSS class identifier: anything outside [a-zA-Z0-9_-] gets a `\` prefix.
    // Matches Tailwind's escaping behavior for arbitrary values like `bg-[#abc]`.
    for (raw) |c| {
        const safe = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!safe) try sink.append(alloc, '\\');
        try sink.append(alloc, c);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "parseCandidate: static utility" {
    const alloc = std.testing.allocator;
    var c = (try parseCandidate(alloc, "flex")).?;
    defer c.deinit(alloc);
    try std.testing.expectEqualStrings("flex", c.utility);
    try std.testing.expectEqual(@as(usize, 0), c.variants.len);
    try std.testing.expectEqual(Value.none, std.meta.activeTag(c.value));
}

test "parseCandidate: named value" {
    const alloc = std.testing.allocator;
    var c = (try parseCandidate(alloc, "p-4")).?;
    defer c.deinit(alloc);
    try std.testing.expectEqualStrings("p", c.utility);
    try std.testing.expectEqualStrings("4", c.value.named);
}

test "parseCandidate: multi-segment named value" {
    const alloc = std.testing.allocator;
    var c = (try parseCandidate(alloc, "bg-red-500")).?;
    defer c.deinit(alloc);
    try std.testing.expectEqualStrings("bg", c.utility);
    try std.testing.expectEqualStrings("red-500", c.value.named);
}

test "parseCandidate: arbitrary value" {
    const alloc = std.testing.allocator;
    var c = (try parseCandidate(alloc, "w-[123px]")).?;
    defer c.deinit(alloc);
    try std.testing.expectEqualStrings("w", c.utility);
    try std.testing.expectEqualStrings("123px", c.value.arbitrary);
}

test "parseCandidate: variants" {
    const alloc = std.testing.allocator;
    var c = (try parseCandidate(alloc, "md:hover:bg-red-500")).?;
    defer c.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), c.variants.len);
    try std.testing.expectEqualStrings("md", c.variants[0]);
    try std.testing.expectEqualStrings("hover", c.variants[1]);
    try std.testing.expectEqualStrings("bg", c.utility);
    try std.testing.expectEqualStrings("red-500", c.value.named);
}

test "parseCandidate: modifier" {
    const alloc = std.testing.allocator;
    var c = (try parseCandidate(alloc, "bg-red-500/50")).?;
    defer c.deinit(alloc);
    try std.testing.expectEqualStrings("red-500", c.value.named);
    try std.testing.expectEqualStrings("50", c.modifier.?);
}

test "parseCandidate: arbitrary survives colon-bracket" {
    const alloc = std.testing.allocator;
    var c = (try parseCandidate(alloc, "md:bg-[rgb(255,0,0)]")).?;
    defer c.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), c.variants.len);
    try std.testing.expectEqualStrings("rgb(255,0,0)", c.value.arbitrary);
}

test "scan: extracts class= attributes (Zig and HTML forms)" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(alloc);

    const src =
        \\h.div(.{ .class = "flex p-4 bg-brand-500" }, ...);
        \\<span class="text-sm font-bold">hi</span>
    ;
    try scan(src, alloc, &out);
    try std.testing.expectEqual(@as(usize, 5), out.items.len);
    try std.testing.expectEqualStrings("flex", out.items[0]);
    try std.testing.expectEqualStrings("p-4", out.items[1]);
    try std.testing.expectEqualStrings("bg-brand-500", out.items[2]);
    try std.testing.expectEqualStrings("text-sm", out.items[3]);
    try std.testing.expectEqualStrings("font-bold", out.items[4]);
}

test "scan: respects identifier boundary (subclass/className not matched)" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(alloc);
    const src = "subclass=\"NOPE\" className=\"NOPE\" class=\"yes\"";
    try scan(src, alloc, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("yes", out.items[0]);
}

test "compile: end-to-end basic" {
    const alloc = std.testing.allocator;
    var ds = DesignSystem.init(alloc);
    defer ds.deinit();
    try ds.loadDefaults();

    const candidates = [_][]const u8{ "flex", "p-4", "bg-brand-500", "text-sm", "rounded-lg" };
    const css = try compile(alloc, &ds, &candidates);
    defer alloc.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, ":root {") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "--color-brand-500: #e8251f") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".flex { display:flex }") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".p-4 { padding:calc(var(--spacing) * 4) }") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".bg-brand-500 { background-color:var(--color-brand-500) }") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".text-sm { font-size:var(--text-sm) }") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".rounded-lg { border-radius:var(--radius-lg) }") != null);
}

test "compile: dedupes repeated candidates" {
    const alloc = std.testing.allocator;
    var ds = DesignSystem.init(alloc);
    defer ds.deinit();
    try ds.loadDefaults();

    const candidates = [_][]const u8{ "flex", "flex", "flex", "p-4" };
    const css = try compile(alloc, &ds, &candidates);
    defer alloc.free(css);

    var count: usize = 0;
    var i: usize = 0;
    const needle = ".flex {";
    while (std.mem.indexOfPos(u8, css, i, needle)) |pos| : (i = pos + needle.len) count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "compile: arbitrary value emitted verbatim" {
    const alloc = std.testing.allocator;
    var ds = DesignSystem.init(alloc);
    defer ds.deinit();
    try ds.loadDefaults();

    const candidates = [_][]const u8{ "w-[42px]", "bg-[#abcdef]" };
    const css = try compile(alloc, &ds, &candidates);
    defer alloc.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, ".w-\\[42px\\] { width:42px }") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".bg-\\[\\#abcdef\\] { background-color:#abcdef }") != null);
}

test "compile: unknown utility silently dropped" {
    const alloc = std.testing.allocator;
    var ds = DesignSystem.init(alloc);
    defer ds.deinit();
    try ds.loadDefaults();

    const candidates = [_][]const u8{ "nope-42", "flex" };
    const css = try compile(alloc, &ds, &candidates);
    defer alloc.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, "nope-42") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".flex {") != null);
}

test "compile: pseudo-class variant" {
    const alloc = std.testing.allocator;
    var ds = DesignSystem.init(alloc);
    defer ds.deinit();
    try ds.loadDefaults();

    const candidates = [_][]const u8{"hover:bg-brand-500"};
    const css = try compile(alloc, &ds, &candidates);
    defer alloc.free(css);

    try std.testing.expect(std.mem.indexOf(
        u8,
        css,
        ".hover\\:bg-brand-500:hover { background-color:var(--color-brand-500) }",
    ) != null);
}

test "compile: media variant wraps in @media" {
    const alloc = std.testing.allocator;
    var ds = DesignSystem.init(alloc);
    defer ds.deinit();
    try ds.loadDefaults();

    const candidates = [_][]const u8{"md:p-8"};
    const css = try compile(alloc, &ds, &candidates);
    defer alloc.free(css);

    try std.testing.expect(std.mem.indexOf(
        u8,
        css,
        "@media (min-width: 768px) { .md\\:p-8 { padding:calc(var(--spacing) * 8) } }",
    ) != null);
}

test "compile: media + pseudo compose correctly" {
    const alloc = std.testing.allocator;
    var ds = DesignSystem.init(alloc);
    defer ds.deinit();
    try ds.loadDefaults();

    const candidates = [_][]const u8{"md:hover:bg-brand-600"};
    const css = try compile(alloc, &ds, &candidates);
    defer alloc.free(css);

    try std.testing.expect(std.mem.indexOf(
        u8,
        css,
        "@media (min-width: 768px) { .md\\:hover\\:bg-brand-600:hover { background-color:var(--color-brand-600) } }",
    ) != null);
}

test "compile: dark variant emits prefers-color-scheme media" {
    const alloc = std.testing.allocator;
    var ds = DesignSystem.init(alloc);
    defer ds.deinit();
    try ds.loadDefaults();

    const candidates = [_][]const u8{"dark:bg-slate-900"};
    const css = try compile(alloc, &ds, &candidates);
    defer alloc.free(css);

    try std.testing.expect(std.mem.indexOf(
        u8,
        css,
        "@media (prefers-color-scheme: dark) { .dark\\:bg-slate-900 { background-color:var(--color-slate-900) } }",
    ) != null);
}

test "compile: unknown variant silently dropped" {
    const alloc = std.testing.allocator;
    var ds = DesignSystem.init(alloc);
    defer ds.deinit();
    try ds.loadDefaults();

    const candidates = [_][]const u8{ "nonsense:bg-brand-500", "flex" };
    const css = try compile(alloc, &ds, &candidates);
    defer alloc.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, "nonsense") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".flex {") != null);
}
