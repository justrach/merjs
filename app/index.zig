const mer = @import("mer");
const h = mer.h;

pub const meta: mer.Meta = .{
    .title = "merjs \u{2014} A Zig-native web framework",
    .description = "A Next.js competitor written in Zig. Zero Node.js, zero node_modules. SSR, file-based routing, type-safe APIs, and WASM for client interactivity.",
    .og_title = "merjs \u{2014} A Zig-native web framework. No Node. No npm. Just WASM.",
    .og_description = "A Next.js competitor written in Zig. Zero Node.js, zero node_modules. SSR, file-based routing, type-safe APIs, and WASM for client interactivity.",
    .og_url = "https://merlionjs.com",
    .twitter_card = "summary_large_image",
    .twitter_title = "merjs \u{2014} A Zig-native web framework",
    .twitter_description = "Zero Node.js. Zero node_modules. Pure Zig all the way down.",
};

const page_node = page();
comptime {
    mer.lint.check(page_node);
}

pub fn render(req: mer.Request) mer.Response {
    return mer.render(req.allocator, page_node);
}

fn page() h.Node {
    return h.div(.{ .class = "page" }, .{
        // Header
        h.header(.{ .class = "header" }, .{
            h.div(.{ .class = "wordmark" }, .{ h.text("mer"), h.span(.{}, .{h.raw("js")}) }),
            h.nav(.{ .class = "nav" }, .{
                navLink("/dashboard", "Dashboard"),
                navLink("/weather", "Weather"),
                navLink("/users", "Users"),
                navLink("/counter", "Counter"),
                navLink("/about", "About"),
            }),
        }),

        // Hero
        h.h1(.{ .class = "lede" }, .{
            h.text("The web doesn't need"),
            h.br(),
            h.em(.{}, "another"),
            h.text(" JavaScript"),
            h.br(),
            h.text("framework. It needs"),
            h.br(),
            h.span(.{ .class = "red" }, "no runtime at all."),
        }),

        h.hr(.{ .class = "rule" }),

        // Items
        h.div(.{ .class = "items" }, .{
            item("01", "Node.js solved the wrong problem.", .{
                h.text("It unified the language, not the stack. You still ship a 400MB runtime to run a "),
                h.code(.{}, "hello world"),
                h.text(". You still wait 30 seconds for "),
                h.strong(.{}, "npm install"),
                h.text(". You still debug dependency conflicts that have nothing to do with your product. The problem was never \"which language\" \u{2014} it was \"why do we need a runtime at all.\""),
            }),
            item("02",
                \\<span class="red">WASM</span> closes the last gap.
            , .{
                h.text("The real reason JS won the server: it already ran in the browser. That moat is gone. WebAssembly is a compile target for "),
                h.em(.{}, "any"),
                h.text(" language. Zig compiles to "),
                h.code(.{}, "wasm32-freestanding"),
                h.text(" in a single step. Write client logic in Zig, compile to "),
                h.strong(.{}, ".wasm"),
                h.text(", ship it directly. No transpiler. No bundler. The browser runs it natively."),
            }),
            item("03",
                \\One language. <em>Two targets.</em>
            , .{
                h.text("The server compiles to a "),
                h.strong(.{}, "native binary"),
                h.text(". The client compiles to "),
                h.strong(.{}, ".wasm"),
                h.text(". File-based routing, SSR, type-safe APIs, hot reload \u{2014} everything Next.js does, in Zig. Zero node_modules. A single "),
                h.code(.{}, "zig build serve"),
                h.text("."),
            }),
            item("04",
                \\Type safety without a <span class="red">build step.</span>
            , .{
                h.text("Validation constraints are comptime. API schemas are Zig structs. JSON serialization is "),
                h.code(.{}, "std.json"),
                h.text(". No codegen. No schema files. No runtime overhead. The compiler catches it, or it doesn't compile."),
            }),
            item("05",
                \\This is <em>early proof.</em>
            , .{
                h.text("merjs is a bet \u{2014} that systems languages, WASM, and file-based routing can meet in one place and produce something better than what we have today. The node_modules folder had a good run. "),
                h.strong(.{}, "It's time to move on."),
            }),
        }),

        // Footer
        h.div(.{ .class = "footer" }, .{
            h.a(.{ .href = "/dashboard", .class = "btn-primary" }, "See it in action"),
            h.a(.{ .href = "/about", .class = "btn-ghost" }, "Read the philosophy"),
            h.p(.{ .class = "footer-note" }, .{
                h.text("Built in "),
                h.a(.{ .href = "https://ziglang.org" }, "Zig 0.15"),
                h.raw(" &middot; Validation by "),
                h.a(.{ .href = "https://github.com/justrach/dhi" }, "dhi"),
                h.raw(" &middot; Zero node_modules"),
            }),
        }),
    });
}

fn navLink(href: []const u8, label: []const u8) h.Node {
    return h.a(.{ .href = href }, label);
}

fn item(num: []const u8, heading: []const u8, body_children: anytype) h.Node {
    return h.div(.{ .class = "item" }, .{
        h.div(.{ .class = "item-num" }, num),
        h.div(.{ .class = "item-body" }, .{
            h.div(.{ .class = "item-heading" }, .{h.raw(heading)}),
            h.p(.{ .class = "item-text" }, body_children),
        }),
    });
}
