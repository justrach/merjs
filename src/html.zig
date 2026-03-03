// html.zig — Type-safe HTML builder DSL.
//
// Usage:
//   const h = @import("mer").h;
//   const page = h.document(
//       &.{ h.charset("UTF-8"), h.title("Hello") },
//       &.{ h.div(.{ .class = "page" }, &.{ h.h1("Hello, world!") }) },
//   );
//   return mer.render(allocator, page);

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
    type: ?[]const u8 = null,
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
        .{ "type", props.type },
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

    return attrs[0..n];
}

fn attr(name: []const u8, value: []const u8) Attr {
    return .{ .name = name, .value = value };
}

// ── Self-closing tag set ────────────────────────────────────────────────────

fn isSelfClosing(tag: []const u8) bool {
    const void_tags = [_][]const u8{
        "area", "base", "br", "col", "embed", "hr", "img",
        "input", "link", "meta", "source", "track", "wbr",
    };
    for (void_tags) |t| {
        if (std.mem.eql(u8, tag, t)) return true;
    }
    return false;
}

// ── Element constructors ────────────────────────────────────────────────────

/// Create an element node with props and children.
pub fn el(tag: []const u8, props: Props, children: []const Node) Node {
    return .{ .element = .{
        .tag = tag,
        .attrs = propsToAttrs(props),
        .children = children,
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
pub fn text(content: []const u8) Node {
    return .{ .text = content };
}

/// Raw HTML (not escaped).
pub fn raw(content: []const u8) Node {
    return .{ .raw = content };
}

// ── Common body elements ────────────────────────────────────────────────────

pub fn div(props: Props, children: []const Node) Node { return el("div", props, children); }
pub fn span(props: Props, children: []const Node) Node { return el("span", props, children); }
pub fn section(props: Props, children: []const Node) Node { return el("section", props, children); }
pub fn header(props: Props, children: []const Node) Node { return el("header", props, children); }
pub fn footer(props: Props, children: []const Node) Node { return el("footer", props, children); }
pub fn nav(props: Props, children: []const Node) Node { return el("nav", props, children); }
pub fn article(props: Props, children: []const Node) Node { return el("article", props, children); }
pub fn aside(props: Props, children: []const Node) Node { return el("aside", props, children); }

// Text elements
pub fn h1(props: Props, children: []const Node) Node { return el("h1", props, children); }
pub fn h2(props: Props, children: []const Node) Node { return el("h2", props, children); }
pub fn h3(props: Props, children: []const Node) Node { return el("h3", props, children); }
pub fn h4(props: Props, children: []const Node) Node { return el("h4", props, children); }
pub fn h5(props: Props, children: []const Node) Node { return el("h5", props, children); }
pub fn h6(props: Props, children: []const Node) Node { return el("h6", props, children); }
pub fn p(props: Props, children: []const Node) Node { return el("p", props, children); }
pub fn em(props: Props, children: []const Node) Node { return el("em", props, children); }
pub fn strong(props: Props, children: []const Node) Node { return el("strong", props, children); }
pub fn code(props: Props, children: []const Node) Node { return el("code", props, children); }
pub fn pre(props: Props, children: []const Node) Node { return el("pre", props, children); }
pub fn br() Node { return elVoid("br", .{}); }
pub fn hr(props: Props) Node { return elVoid("hr", props); }

// Links / media
pub fn a(props: Props, children: []const Node) Node { return el("a", props, children); }
pub fn img(props: Props) Node { return elVoid("img", props); }
pub fn button(props: Props, children: []const Node) Node { return el("button", props, children); }

// Lists
pub fn ul(props: Props, children: []const Node) Node { return el("ul", props, children); }
pub fn ol(props: Props, children: []const Node) Node { return el("ol", props, children); }
pub fn li(props: Props, children: []const Node) Node { return el("li", props, children); }

// Forms
pub fn form(props: Props, children: []const Node) Node { return el("form", props, children); }
pub fn input(props: Props) Node { return elVoid("input", props); }
pub fn label(props: Props, children: []const Node) Node { return el("label", props, children); }
pub fn textarea(props: Props, children: []const Node) Node { return el("textarea", props, children); }
pub fn selectEl(props: Props, children: []const Node) Node { return el("select", props, children); }
pub fn option(props: Props, children: []const Node) Node { return el("option", props, children); }

// Tables
pub fn table(props: Props, children: []const Node) Node { return el("table", props, children); }
pub fn thead(props: Props, children: []const Node) Node { return el("thead", props, children); }
pub fn tbody(props: Props, children: []const Node) Node { return el("tbody", props, children); }
pub fn tr(props: Props, children: []const Node) Node { return el("tr", props, children); }
pub fn th(props: Props, children: []const Node) Node { return el("th", props, children); }
pub fn td(props: Props, children: []const Node) Node { return el("td", props, children); }

// ── Head / document elements ────────────────────────────────────────────────

pub fn head(props: Props, children: []const Node) Node { return el("head", props, children); }
pub fn body(props: Props, children: []const Node) Node { return el("body", props, children); }
pub fn htmlEl(props: Props, children: []const Node) Node { return el("html", props, children); }

pub fn title(content: []const u8) Node {
    return el("title", .{}, &.{text(content)});
}

pub fn meta(props: Props) Node { return elVoid("meta", props); }
pub fn link(props: Props) Node { return elVoid("link", props); }

pub fn script(props: Props, content: []const u8) Node {
    return el("script", props, &.{raw(content)});
}

pub fn scriptSrc(props: Props) Node {
    return el("script", props, &.{});
}

pub fn style(content: []const u8) Node {
    return el("style", .{}, &.{raw(content)});
}

/// Shortcut: `<meta charset="...">`
pub fn charset(value: []const u8) Node {
    return meta(.{ .charset = value });
}

/// Shortcut: `<meta name="viewport" content="...">`
pub fn viewport(content: []const u8) Node {
    return meta(.{ .name = "viewport", .content = content });
}

/// Shortcut: `<meta property="og:..." content="...">`
pub fn og(property: []const u8, content: []const u8) Node {
    return meta(.{ .property = property, .content = content });
}

/// Produce a full `<!DOCTYPE html><html>...</html>` document.
pub fn document(head_children: []const Node, body_children: []const Node) Node {
    return raw_document(.{}, .{}, head_children, body_children);
}

/// Document with props on html and body tags.
pub fn raw_document(html_props: Props, body_props: Props, head_children: []const Node, body_children: []const Node) Node {
    return htmlEl(html_props, &.{
        head(.{}, head_children),
        body(body_props, body_children),
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
        .text => |t| try escapeHtml(out, t),
        .raw => |r| try out.writer.writeAll(r),
        .element => |elem| {
            // Doctype for <html> root.
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
