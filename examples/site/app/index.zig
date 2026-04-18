const std = @import("std");
const mer = @import("mer");

const version = mer.version;
const release_path = "/v" ++ version;
const page_css = @embedFile("page.css");
const page_template = @embedFile("page.html");

pub const meta: mer.Meta = .{
    .title = "merjs - A Zig-native web framework",
    .description = "File-based routing, SSR, typed APIs, and WASM client logic. A web framework built in Zig with zero Node.js runtime.",
    .og_title = "merjs - Zig-native web framework",
    .og_description = "File-based routing, SSR, typed APIs, and WASM client logic. No Node. No npm. Just Zig.",
    .og_url = "https://merlionjs.com",
    .twitter_card = "summary_large_image",
    .twitter_title = "merjs - Zig-native web framework",
    .twitter_description = "A web framework built in Zig with zero Node.js runtime.",
    .extra_head = "<style>" ++ page_css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    const html = std.fmt.allocPrint(req.allocator, page_template, .{ version, release_path, version, release_path, version, version, release_path, version }) catch {
        return mer.internalError("render failed");
    };
    return mer.html(html);
}
