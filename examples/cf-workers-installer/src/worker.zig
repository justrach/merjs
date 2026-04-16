const std = @import("std");
const mer = @import("mer");

const INSTALL_SH = @embedFile("../public/install.sh");
const INDEX_HTML = @embedFile("../public/index.html");

export fn fetch(request: mer.js.Object, env: mer.js.Object, ctx: mer.js.Object) mer.js.Object {
    _ = env;
    _ = ctx;

    const url = request.get("url").toString();
    const pathname = std.mem.sliceTo(url.ptr, 0);

    if (std.mem.endsWith(u8, pathname, "/install.sh") or std.mem.eql(u8, pathname, "/install")) {
        return newResponse(INSTALL_SH, "text/x-shellscript; charset=utf-8");
    }

    return newResponse(INDEX_HTML, "text/html; charset=utf-8");
}

fn newResponse(body: []const u8, content_type: []const u8) mer.js.Object {
    const response = mer.js.Object.init();
    response.set("status", 200);
    response.set("statusText", "OK");

    const headers = mer.js.Object.init();
    headers.set("Content-Type", content_type);
    headers.set("Cache-Control", "public, max-age=3600");
    response.set("headers", headers);

    response.set("body", body);
    return response;
}
