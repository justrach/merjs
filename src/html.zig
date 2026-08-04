// html.zig — Type-safe HTML builder DSL.
//
// JSX-like ergonomics:
//   const h = @import("mer").h;
//
//   // Text shorthand — just pass a string:
//   h.h1(.{}, "Hello, world!")
//
//   // Children array:
//   h.div(.{ .class = "card" }, .{
//       h.h2(.{}, "Title"),
//       h.p(.{}, "Body text here."),
//   })
//
//   // No props needed? Pass .{} as first arg.
//   // Mix raw HTML freely:
//   h.div(.{}, .{ h.raw("<b>bold</b>"), h.text("escaped") })
//
//   // Full document:
//   h.document(.{ h.charset("UTF-8"), h.title("Hi") },
//              .{ h.h1(.{}, "Hello!") })
//
// RenderStorage is recommended when standalone nodes are retained or copied:
//   var storage = h.RenderStorage.init(allocator);
//   storage.activate();
//   defer storage.deinit();
// Without active storage, runtime child slices use a bounded thread-local pool.

const std = @import("std");

// ── Thread-local request allocator ──────────────────────────────────────────
// Set by server.zig before each request so coerceChildren can heap-allocate
// runtime children tuples (avoids returning pointers to stack-local arrays).
threadlocal var _render_alloc: ?std.mem.Allocator = null;
threadlocal var _active_storage: ?*RenderStorage = null;

/// Call this once per request (before building any Node tree) to enable
/// safe runtime children. server.zig calls this automatically. The allocator
/// must outlive every Node built while it is selected.
pub fn setRenderAllocator(alloc: std.mem.Allocator) void {
    _render_alloc = alloc;
    _active_storage = null;
}

pub fn hasRenderAllocator() bool {
    return _render_alloc != null;
}

/// Bounded storage for standalone/runtime Node construction. Node values borrow
/// child slices from this arena, so they remain freely copyable and renderable
/// until the storage is deinitialized.
pub const RenderStorage = struct {
    arena: std.heap.ArenaAllocator,
    previous_allocator: ?std.mem.Allocator = null,
    previous_storage: ?*RenderStorage = null,
    active: bool = false,

    pub fn init(backing_allocator: std.mem.Allocator) RenderStorage {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    /// Select this storage for runtime children built on the current thread.
    /// Activations may be nested, but must be deinitialized in reverse order.
    pub fn activate(self: *RenderStorage) void {
        std.debug.assert(!self.active);
        self.previous_allocator = _render_alloc;
        self.previous_storage = _active_storage;
        self.active = true;
        _render_alloc = self.arena.allocator();
        _active_storage = self;
    }

    pub fn deinit(self: *RenderStorage) void {
        if (self.active) {
            std.debug.assert(_active_storage == self);
            _render_alloc = self.previous_allocator;
            _active_storage = self.previous_storage;
            self.active = false;
        }
        self.arena.deinit();
    }
};

// ── Core types ──────────────────────────────────────────────────────────────

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Node = union(enum) {
    element: Element,
    text: []const u8,
    raw: []const u8,

    /// Retained for source compatibility. Nodes do not have unique ownership;
    /// release an active RenderStorage instead.
    pub fn deinit(self: Node) void {
        _ = self;
    }
};

pub const Element = struct {
    tag: []const u8,
    attrs: []const Attr,
    children: []const Node,
    self_closing: bool = false,
};

// ── Attribute helpers ───────────────────────────────────────────────────────

pub const Props = struct {
    // String attributes
    class: ?[]const u8 = null,
    id: ?[]const u8 = null,
    style: ?[]const u8 = null,
    href: ?[]const u8 = null,
    src: ?[]const u8 = null,
    alt: ?[]const u8 = null,
    name: ?[]const u8 = null,
    content: ?[]const u8 = null,
    property: ?[]const u8 = null,
    rel: ?[]const u8 = null,
    type: ?[]const u8 = null,
    charset: ?[]const u8 = null,
    crossorigin: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    action: ?[]const u8 = null,
    method: ?[]const u8 = null,
    value: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    target: ?[]const u8 = null,
    // Form / input extras
    @"for": ?[]const u8 = null, // <label for="...">
    rows: ?[]const u8 = null,
    cols: ?[]const u8 = null,
    role: ?[]const u8 = null,
    tabindex: ?[]const u8 = null,
    min: ?[]const u8 = null,
    max: ?[]const u8 = null,
    step: ?[]const u8 = null,
    autocomplete: ?[]const u8 = null,
    size: ?[]const u8 = null,
    // Boolean attributes (rendered as `name=""` when true)
    disabled: bool = false,
    required: bool = false,
    checked: bool = false,
    readonly: bool = false,
    multiple: bool = false,
    selected: bool = false,
    open: bool = false, // <details open>
    hidden: bool = false,
    // Escape hatch for any attr not in the list above
    extra: []const Attr = &.{},
};

fn propsToAttrs(comptime props: Props) []const Attr {
    @setEvalBranchQuota(20_000);
    comptime var attrs: [48]Attr = undefined;
    comptime var n: usize = 0;

    // String optional attributes
    inline for (.{
        .{ "class", props.class },
        .{ "id", props.id },
        .{ "style", props.style },
        .{ "href", props.href },
        .{ "src", props.src },
        .{ "alt", props.alt },
        .{ "name", props.name },
        .{ "content", props.content },
        .{ "property", props.property },
        .{ "rel", props.rel },
        .{ "type", props.type },
        .{ "charset", props.charset },
        .{ "crossorigin", props.crossorigin },
        .{ "lang", props.lang },
        .{ "action", props.action },
        .{ "method", props.method },
        .{ "value", props.value },
        .{ "placeholder", props.placeholder },
        .{ "target", props.target },
        .{ "for", props.@"for" },
        .{ "rows", props.rows },
        .{ "cols", props.cols },
        .{ "role", props.role },
        .{ "tabindex", props.tabindex },
        .{ "min", props.min },
        .{ "max", props.max },
        .{ "step", props.step },
        .{ "autocomplete", props.autocomplete },
        .{ "size", props.size },
    }) |pair| {
        if (pair[1]) |v| {
            attrs[n] = .{ .name = pair[0], .value = v };
            n += 1;
        }
    }

    // Boolean attributes — rendered as `disabled=""` etc.
    inline for (.{
        .{ "disabled", props.disabled },
        .{ "required", props.required },
        .{ "checked", props.checked },
        .{ "readonly", props.readonly },
        .{ "multiple", props.multiple },
        .{ "selected", props.selected },
        .{ "open", props.open },
        .{ "hidden", props.hidden },
    }) |pair| {
        if (pair[1]) {
            attrs[n] = .{ .name = pair[0], .value = "" };
            n += 1;
        }
    }

    const final: [n]Attr = attrs[0..n].*;
    return &final;
}

// ── Self-closing tag set ────────────────────────────────────────────────────

fn isSelfClosing(tag: []const u8) bool {
    const void_tags = [_][]const u8{
        "area",  "base", "br",   "col",    "embed", "hr",  "img",
        "input", "link", "meta", "source", "track", "wbr",
    };
    for (void_tags) |vt| {
        if (std.mem.eql(u8, tag, vt)) return true;
    }
    return false;
}

// ── Children coercion (JSX-like) ────────────────────────────────────────────

/// Coerce various child types to []const Node:
///   - []const u8 / string literal → single text node
///   - .{ Node, Node, ... } tuple  → slice of nodes
///   - []const Node                → pass through
const Children = struct {
    items: []const Node,
};

/// The thread-local standalone pool holds this many child values. Existing
/// slices are never overwritten; use RenderStorage for sustained construction
/// or when an explicit lifetime is required.
pub const standalone_fallback_capacity = 1024;
threadlocal var _standalone_fallback: [standalone_fallback_capacity]Node = undefined;
threadlocal var _standalone_fallback_cursor: usize = 0;

/// Reclaim standalone fallback storage after every node built without an active
/// RenderStorage is no longer used. Existing fallback-backed nodes become
/// invalid, so retained/repeated construction should prefer RenderStorage.
pub fn resetStandaloneFallback() void {
    std.debug.assert(_render_alloc == null);
    _standalone_fallback_cursor = 0;
}

fn ownRuntimeChildren(nodes: []const Node) Children {
    if (nodes.len == 0) return .{ .items = &.{} };

    if (_render_alloc) |allocator| {
        return .{ .items = allocator.dupe(Node, nodes) catch @panic("h.*: out of memory") };
    }
    if (nodes.len > standalone_fallback_capacity -| _standalone_fallback_cursor) {
        @panic("h.*: standalone fallback exhausted; use h.RenderStorage");
    }
    const start = _standalone_fallback_cursor;
    _standalone_fallback_cursor += nodes.len;
    @memcpy(_standalone_fallback[start.._standalone_fallback_cursor], nodes);
    return .{ .items = _standalone_fallback[start.._standalone_fallback_cursor] };
}

fn coerceChildren(children: anytype) Children {
    const T = @TypeOf(children);

    // Runtime wrappers must outlive this function. Server requests and an
    // active RenderStorage use their arena; standalone nodes use the bounded
    // thread-local fallback.
    if (T == []const u8) {
        if (@inComptime()) return .{ .items = &.{Node{ .text = children }} };
        const singleton = [1]Node{Node{ .text = children }};
        return ownRuntimeChildren(&singleton);
    }
    if (comptime isStringLiteral(T)) {
        const slice: []const u8 = children;
        if (@inComptime()) return .{ .items = &.{Node{ .text = slice }} };
        const singleton = [1]Node{Node{ .text = slice }};
        return ownRuntimeChildren(&singleton);
    }

    // Caller-provided slices remain borrowed.
    if (T == []const Node) {
        return .{ .items = children };
    }

    if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
        const fields = @typeInfo(T).@"struct".fields;
        var nodes: [fields.len]Node = undefined;
        inline for (fields, 0..) |field, idx| {
            const val = @field(children, field.name);
            if (field.type == Node) {
                nodes[idx] = val;
            } else if (field.type == []const u8 or comptime isStringLiteral(field.type)) {
                nodes[idx] = Node{ .text = val };
            } else {
                nodes[idx] = val;
            }
        }
        if (@inComptime()) {
            const final: [fields.len]Node = nodes;
            return .{ .items = &final };
        }
        return ownRuntimeChildren(&nodes);
    }

    // Pointer to array of Node.
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .one) {
        const child_info = @typeInfo(info.pointer.child);
        if (child_info == .@"struct" and child_info.@"struct".is_tuple) {
            return coerceChildren(children.*);
        }
        if (child_info == .array and child_info.array.child == Node) {
            if (@inComptime()) return .{ .items = children };
            return ownRuntimeChildren(children);
        }
    }

    @compileError("h.*: unsupported children type: " ++ @typeName(T));
}

fn isStringLiteral(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    if (info.pointer.size != .one) return false;
    const child = @typeInfo(info.pointer.child);
    if (child != .array) return false;
    return child.array.child == u8;
}

// ── Element constructors ────────────────────────────────────────────────────

/// Create an element with tag, props, and children (anytype).
pub fn el(tag: []const u8, comptime props: Props, children: anytype) Node {
    const child_nodes = coerceChildren(children);
    return .{ .element = .{
        .tag = tag,
        .attrs = propsToAttrs(props),
        .children = child_nodes.items,
        .self_closing = isSelfClosing(tag),
    } };
}

/// Create a self-closing element with props only (meta, link, img, etc.).
pub fn elVoid(tag: []const u8, comptime props: Props) Node {
    return .{ .element = .{
        .tag = tag,
        .attrs = propsToAttrs(props),
        .children = &.{},
        .self_closing = true,
    } };
}

/// Text node (HTML-escaped).
pub fn text(s: []const u8) Node {
    return .{ .text = s };
}

/// Raw HTML (not escaped).
pub fn raw(s: []const u8) Node {
    return .{ .raw = s };
}

// ── Common body elements ────────────────────────────────────────────────────
// Each accepts (Props, children) where children can be:
//   - "string"     → text node
//   - .{ nodes }   → tuple of children
//   - &.{ nodes }  → slice of nodes

pub fn div(comptime props: Props, children: anytype) Node {
    return el("div", props, children);
}
pub fn span(comptime props: Props, children: anytype) Node {
    return el("span", props, children);
}
pub fn section(comptime props: Props, children: anytype) Node {
    return el("section", props, children);
}
pub fn header(comptime props: Props, children: anytype) Node {
    return el("header", props, children);
}
pub fn footer(comptime props: Props, children: anytype) Node {
    return el("footer", props, children);
}
pub fn nav(comptime props: Props, children: anytype) Node {
    return el("nav", props, children);
}
pub fn article(comptime props: Props, children: anytype) Node {
    return el("article", props, children);
}
pub fn aside(comptime props: Props, children: anytype) Node {
    return el("aside", props, children);
}
pub fn main_el(comptime props: Props, children: anytype) Node {
    return el("main", props, children);
}

// Text elements
pub fn h1(comptime props: Props, children: anytype) Node {
    return el("h1", props, children);
}
pub fn h2(comptime props: Props, children: anytype) Node {
    return el("h2", props, children);
}
pub fn h3(comptime props: Props, children: anytype) Node {
    return el("h3", props, children);
}
pub fn h4(comptime props: Props, children: anytype) Node {
    return el("h4", props, children);
}
pub fn h5(comptime props: Props, children: anytype) Node {
    return el("h5", props, children);
}
pub fn h6(comptime props: Props, children: anytype) Node {
    return el("h6", props, children);
}
pub fn p(comptime props: Props, children: anytype) Node {
    return el("p", props, children);
}
pub fn em(comptime props: Props, children: anytype) Node {
    return el("em", props, children);
}
pub fn strong(comptime props: Props, children: anytype) Node {
    return el("strong", props, children);
}
pub fn code(comptime props: Props, children: anytype) Node {
    return el("code", props, children);
}
pub fn pre(comptime props: Props, children: anytype) Node {
    return el("pre", props, children);
}
pub fn br() Node {
    return elVoid("br", .{});
}
pub fn hr(comptime props: Props) Node {
    return elVoid("hr", props);
}

// Links / media
pub fn a(comptime props: Props, children: anytype) Node {
    return el("a", props, children);
}
pub fn img(comptime props: Props) Node {
    return elVoid("img", props);
}
pub fn button(comptime props: Props, children: anytype) Node {
    return el("button", props, children);
}

// Lists
pub fn ul(comptime props: Props, children: anytype) Node {
    return el("ul", props, children);
}
pub fn ol(comptime props: Props, children: anytype) Node {
    return el("ol", props, children);
}
pub fn li(comptime props: Props, children: anytype) Node {
    return el("li", props, children);
}

// Forms
pub fn form(comptime props: Props, children: anytype) Node {
    return el("form", props, children);
}
pub fn input(comptime props: Props) Node {
    return elVoid("input", props);
}
pub fn label(comptime props: Props, children: anytype) Node {
    return el("label", props, children);
}
pub fn textarea(comptime props: Props, children: anytype) Node {
    return el("textarea", props, children);
}
pub fn selectEl(comptime props: Props, children: anytype) Node {
    return el("select", props, children);
}
pub fn option(comptime props: Props, children: anytype) Node {
    return el("option", props, children);
}

// Tables
pub fn table(comptime props: Props, children: anytype) Node {
    return el("table", props, children);
}
pub fn thead(comptime props: Props, children: anytype) Node {
    return el("thead", props, children);
}
pub fn tbody(comptime props: Props, children: anytype) Node {
    return el("tbody", props, children);
}
pub fn tr(comptime props: Props, children: anytype) Node {
    return el("tr", props, children);
}
pub fn th(comptime props: Props, children: anytype) Node {
    return el("th", props, children);
}
pub fn td(comptime props: Props, children: anytype) Node {
    return el("td", props, children);
}

// Interactive / semantic HTML5
pub fn dialog(comptime props: Props, children: anytype) Node {
    return el("dialog", props, children);
}
pub fn details(comptime props: Props, children: anytype) Node {
    return el("details", props, children);
}
pub fn summary(comptime props: Props, children: anytype) Node {
    return el("summary", props, children);
}
pub fn figure(comptime props: Props, children: anytype) Node {
    return el("figure", props, children);
}
pub fn figcaption(comptime props: Props, children: anytype) Node {
    return el("figcaption", props, children);
}
pub fn fieldset(comptime props: Props, children: anytype) Node {
    return el("fieldset", props, children);
}
pub fn legend(comptime props: Props, children: anytype) Node {
    return el("legend", props, children);
}

// Inline semantics
pub fn mark(comptime props: Props, children: anytype) Node {
    return el("mark", props, children);
}
pub fn time_el(comptime props: Props, children: anytype) Node {
    return el("time", props, children);
}
pub fn abbr(comptime props: Props, children: anytype) Node {
    return el("abbr", props, children);
}
pub fn kbd(comptime props: Props, children: anytype) Node {
    return el("kbd", props, children);
}
pub fn samp(comptime props: Props, children: anytype) Node {
    return el("samp", props, children);
}
pub fn sub(comptime props: Props, children: anytype) Node {
    return el("sub", props, children);
}
pub fn sup(comptime props: Props, children: anytype) Node {
    return el("sup", props, children);
}
pub fn del(comptime props: Props, children: anytype) Node {
    return el("del", props, children);
}
pub fn ins(comptime props: Props, children: anytype) Node {
    return el("ins", props, children);
}
pub fn q(comptime props: Props, children: anytype) Node {
    return el("q", props, children);
}
pub fn s_el(comptime props: Props, children: anytype) Node {
    return el("s", props, children);
}

// Block semantics
pub fn blockquote(comptime props: Props, children: anytype) Node {
    return el("blockquote", props, children);
}
pub fn address(comptime props: Props, children: anytype) Node {
    return el("address", props, children);
}

// Progress / meter
pub fn progress(comptime props: Props, children: anytype) Node {
    return el("progress", props, children);
}
pub fn meter(comptime props: Props, children: anytype) Node {
    return el("meter", props, children);
}

// ── Head / document elements ────────────────────────────────────────────────

pub fn head(comptime props: Props, children: anytype) Node {
    return el("head", props, children);
}
pub fn body(comptime props: Props, children: anytype) Node {
    return el("body", props, children);
}
pub fn htmlEl(comptime props: Props, children: anytype) Node {
    return el("html", props, children);
}

pub fn title(s: []const u8) Node {
    return el("title", .{}, s);
}

pub fn meta(comptime props: Props) Node {
    return elVoid("meta", props);
}
pub fn link(comptime props: Props) Node {
    return elVoid("link", props);
}

pub fn script(comptime props: Props, s: []const u8) Node {
    return el("script", props, &[_]Node{raw(s)});
}

pub fn scriptSrc(comptime props: Props) Node {
    return el("script", props, &[_]Node{});
}

pub fn style(s: []const u8) Node {
    return el("style", .{}, &[_]Node{raw(s)});
}

/// Shortcut: `<meta charset="...">`
pub fn charset(comptime val: []const u8) Node {
    return meta(.{ .charset = val });
}

/// Shortcut: `<meta name="viewport" content="...">`
pub fn viewport(comptime s: []const u8) Node {
    return meta(.{ .name = "viewport", .content = s });
}

/// Shortcut: `<meta property="og:..." content="...">`
pub fn og(comptime prop: []const u8, comptime val: []const u8) Node {
    return meta(.{ .property = prop, .content = val });
}

/// Shortcut: `<meta name="description" content="...">`
pub fn description(comptime val: []const u8) Node {
    return meta(.{ .name = "description", .content = val });
}

/// Produce a full `<!DOCTYPE html><html>...</html>` document.
pub fn document(head_children: anytype, body_children: anytype) Node {
    return htmlEl(.{}, .{
        head(.{}, head_children),
        body(.{}, body_children),
    });
}

/// Document with lang attribute.
pub fn documentLang(comptime lang_val: []const u8, head_children: anytype, body_children: anytype) Node {
    return htmlEl(.{ .lang = lang_val }, .{
        head(.{}, head_children),
        body(.{}, body_children),
    });
}

// ── Render ──────────────────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, node: Node) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try renderNode(&out, node);
    return out.toOwnedSlice();
}

fn renderNode(out: *std.Io.Writer.Allocating, node: Node) !void {
    switch (node) {
        .text => |txt| try escapeHtml(out, txt),
        .raw => |r| try out.writer.writeAll(r),
        .element => |elem| {
            if (std.mem.eql(u8, elem.tag, "html")) {
                try out.writer.writeAll("<!DOCTYPE html>");
            }

            try out.writer.writeAll("<");
            try out.writer.writeAll(elem.tag);

            for (elem.attrs) |at| {
                try out.writer.writeAll(" ");
                try out.writer.writeAll(at.name);
                try out.writer.writeAll("=\"");
                try escapeAttr(out, at.value);
                try out.writer.writeAll("\"");
            }

            if (elem.self_closing) {
                try out.writer.writeAll(">");
                return;
            }

            try out.writer.writeAll(">");
            for (elem.children) |child| {
                try renderNode(out, child);
            }
            try out.writer.writeAll("</");
            try out.writer.writeAll(elem.tag);
            try out.writer.writeAll(">");
        },
    }
}

fn escapeHtml(out: *std.Io.Writer.Allocating, s: []const u8) !void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const replacement: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => null,
        };
        if (replacement) |r| {
            if (i > start) try out.writer.writeAll(s[start..i]);
            try out.writer.writeAll(r);
            start = i + 1;
        }
    }
    if (start < s.len) try out.writer.writeAll(s[start..]);
}

fn escapeAttr(out: *std.Io.Writer.Allocating, s: []const u8) !void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const replacement: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '"' => "&quot;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => null,
        };
        if (replacement) |r| {
            if (i > start) try out.writer.writeAll(s[start..i]);
            try out.writer.writeAll(r);
            start = i + 1;
        }
    }
    if (start < s.len) try out.writer.writeAll(s[start..]);
}
