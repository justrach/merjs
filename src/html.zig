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

const std = @import("std");

// ── Core types ──────────────────────────────────────────────────────────────

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Node = union(enum) {
    element: Element,
    text: []const u8,
    raw: []const u8,
};

pub const Element = struct {
    tag: []const u8,
    attrs: []const Attr,
    children: []const Node,
    self_closing: bool = false,
};

// ── Attribute helpers ───────────────────────────────────────────────────────

pub const Props = struct {
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
    @"type": ?[]const u8 = null,
    charset: ?[]const u8 = null,
    crossorigin: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    action: ?[]const u8 = null,
    method: ?[]const u8 = null,
    value: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    target: ?[]const u8 = null,
    extra: []const Attr = &.{},
};

fn propsToAttrs(props: Props) []const Attr {
    @setEvalBranchQuota(10_000);
    var attrs: [20]Attr = undefined;
    var n: usize = 0;

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
        .{ "type", props.@"type" },
        .{ "charset", props.charset },
        .{ "crossorigin", props.crossorigin },
        .{ "lang", props.lang },
        .{ "action", props.action },
        .{ "method", props.method },
        .{ "value", props.value },
        .{ "placeholder", props.placeholder },
        .{ "target", props.target },
    }) |pair| {
        if (pair[1]) |v| {
            attrs[n] = .{ .name = pair[0], .value = v };
            n += 1;
        }
    }

    const final: [n]Attr = attrs[0..n].*;
    return &final;
}

// ── Self-closing tag set ────────────────────────────────────────────────────

fn isSelfClosing(tag: []const u8) bool {
    const void_tags = [_][]const u8{
        "area", "base", "br", "col", "embed", "hr", "img",
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
fn coerceChildren(children: anytype) []const Node {
    const T = @TypeOf(children);

    // String literal → text node
    if (T == []const u8) {
        return &.{Node{ .text = children }};
    }
    if (comptime isStringLiteral(T)) {
        const slice: []const u8 = children;
        return &.{Node{ .text = slice }};
    }

    // Already a node slice
    if (T == []const Node) {
        return children;
    }

    // Tuple of nodes — coerce to slice
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
        const final: [fields.len]Node = nodes;
        return &final;
    }

    // Pointer to array of Node
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .one) {
        const child_info = @typeInfo(info.pointer.child);
        if (child_info == .array and child_info.array.child == Node) {
            return children;
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
pub fn el(tag: []const u8, props: Props, children: anytype) Node {
    return .{ .element = .{
        .tag = tag,
        .attrs = propsToAttrs(props),
        .children = coerceChildren(children),
        .self_closing = isSelfClosing(tag),
    } };
}

/// Create a self-closing element with props only (meta, link, img, etc.).
pub fn elVoid(tag: []const u8, props: Props) Node {
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

pub fn div(props: Props, children: anytype) Node { return el("div", props, children); }
pub fn span(props: Props, children: anytype) Node { return el("span", props, children); }
pub fn section(props: Props, children: anytype) Node { return el("section", props, children); }
pub fn header(props: Props, children: anytype) Node { return el("header", props, children); }
pub fn footer(props: Props, children: anytype) Node { return el("footer", props, children); }
pub fn nav(props: Props, children: anytype) Node { return el("nav", props, children); }
pub fn article(props: Props, children: anytype) Node { return el("article", props, children); }
pub fn aside(props: Props, children: anytype) Node { return el("aside", props, children); }
pub fn main_el(props: Props, children: anytype) Node { return el("main", props, children); }

// Text elements
pub fn h1(props: Props, children: anytype) Node { return el("h1", props, children); }
pub fn h2(props: Props, children: anytype) Node { return el("h2", props, children); }
pub fn h3(props: Props, children: anytype) Node { return el("h3", props, children); }
pub fn h4(props: Props, children: anytype) Node { return el("h4", props, children); }
pub fn h5(props: Props, children: anytype) Node { return el("h5", props, children); }
pub fn h6(props: Props, children: anytype) Node { return el("h6", props, children); }
pub fn p(props: Props, children: anytype) Node { return el("p", props, children); }
pub fn em(props: Props, children: anytype) Node { return el("em", props, children); }
pub fn strong(props: Props, children: anytype) Node { return el("strong", props, children); }
pub fn code(props: Props, children: anytype) Node { return el("code", props, children); }
pub fn pre(props: Props, children: anytype) Node { return el("pre", props, children); }
pub fn br() Node { return elVoid("br", .{}); }
pub fn hr(props: Props) Node { return elVoid("hr", props); }

// Links / media
pub fn a(props: Props, children: anytype) Node { return el("a", props, children); }
pub fn img(props: Props) Node { return elVoid("img", props); }
pub fn button(props: Props, children: anytype) Node { return el("button", props, children); }

// Lists
pub fn ul(props: Props, children: anytype) Node { return el("ul", props, children); }
pub fn ol(props: Props, children: anytype) Node { return el("ol", props, children); }
pub fn li(props: Props, children: anytype) Node { return el("li", props, children); }

// Forms
pub fn form(props: Props, children: anytype) Node { return el("form", props, children); }
pub fn input(props: Props) Node { return elVoid("input", props); }
pub fn label(props: Props, children: anytype) Node { return el("label", props, children); }
pub fn textarea(props: Props, children: anytype) Node { return el("textarea", props, children); }
pub fn selectEl(props: Props, children: anytype) Node { return el("select", props, children); }
pub fn option(props: Props, children: anytype) Node { return el("option", props, children); }

// Tables
pub fn table(props: Props, children: anytype) Node { return el("table", props, children); }
pub fn thead(props: Props, children: anytype) Node { return el("thead", props, children); }
pub fn tbody(props: Props, children: anytype) Node { return el("tbody", props, children); }
pub fn tr(props: Props, children: anytype) Node { return el("tr", props, children); }
pub fn th(props: Props, children: anytype) Node { return el("th", props, children); }
pub fn td(props: Props, children: anytype) Node { return el("td", props, children); }

// ── Head / document elements ────────────────────────────────────────────────

pub fn head(props: Props, children: anytype) Node { return el("head", props, children); }
pub fn body(props: Props, children: anytype) Node { return el("body", props, children); }
pub fn htmlEl(props: Props, children: anytype) Node { return el("html", props, children); }

pub fn title(s: []const u8) Node {
    return el("title", .{}, s);
}

pub fn meta(props: Props) Node { return elVoid("meta", props); }
pub fn link(props: Props) Node { return elVoid("link", props); }

pub fn script(props: Props, s: []const u8) Node {
    return el("script", props, &[_]Node{raw(s)});
}

pub fn scriptSrc(props: Props) Node {
    return el("script", props, &[_]Node{});
}

pub fn style(s: []const u8) Node {
    return el("style", .{}, &[_]Node{raw(s)});
}

/// Shortcut: `<meta charset="...">`
pub fn charset(val: []const u8) Node {
    return meta(.{ .charset = val });
}

/// Shortcut: `<meta name="viewport" content="...">`
pub fn viewport(s: []const u8) Node {
    return meta(.{ .name = "viewport", .content = s });
}

/// Shortcut: `<meta property="og:..." content="...">`
pub fn og(prop: []const u8, val: []const u8) Node {
    return meta(.{ .property = prop, .content = val });
}

/// Shortcut: `<meta name="description" content="...">`
pub fn description(val: []const u8) Node {
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
pub fn documentLang(lang_val: []const u8, head_children: anytype, body_children: anytype) Node {
    return htmlEl(.{ .lang = lang_val }, .{
        head(.{}, head_children),
        body(.{}, body_children),
    });
}

// ── Render ──────────────────────────────────────────────────────────────────

pub fn render(allocator: std.mem.Allocator, node: Node) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    try renderNode(&out, node);
    return out.written();
}

fn renderNode(out: *std.io.Writer.Allocating, node: Node) !void {
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

fn escapeHtml(out: *std.io.Writer.Allocating, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try out.writer.writeAll("&amp;"),
            '<' => try out.writer.writeAll("&lt;"),
            '>' => try out.writer.writeAll("&gt;"),
            else => try out.writer.writeByte(c),
        }
    }
}

fn escapeAttr(out: *std.io.Writer.Allocating, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try out.writer.writeAll("&amp;"),
            '"' => try out.writer.writeAll("&quot;"),
            '<' => try out.writer.writeAll("&lt;"),
            '>' => try out.writer.writeAll("&gt;"),
            else => try out.writer.writeByte(c),
        }
    }
}
