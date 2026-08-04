// mer-worker.zig — worker-safe public API surface for page authors.
// Used only for wasm32-freestanding targets so native-only modules are not
// pulled into worker builds.

const std = @import("std");
const shared = @import("mer-shared.zig");
const WorkerApi = @This();

pub const mercss = shared.mercss;
pub const design = shared.design;
pub const mercss_compat = shared.mercss_compat;
pub const version = shared.version;
pub const StreamParts = shared.StreamParts;
pub const StreamWriter = shared.StreamWriter;
pub const Method = shared.Method;
pub const Param = shared.Param;
pub const Request = shared.Request;
pub const ContentType = shared.ContentType;
pub const Response = shared.Response;
pub const SameSite = shared.SameSite;
pub const SetCookie = shared.SetCookie;
pub const html = shared.html;
pub const json = shared.json;
pub const text = shared.text;
pub const notFound = shared.notFound;
pub const internalError = shared.internalError;
pub const redirect = shared.redirect;
pub const withCookies = shared.withCookies;
pub const typedJson = shared.typedJson;
pub const parseJson = shared.parseJson;
pub const formParam = shared.formParam;
pub const badRequest = shared.badRequest;
pub const env = shared.env;
pub const putEnv = shared.putEnv;
pub const loadDotenv = shared.loadDotenv;
pub const loadDotenvStatus = shared.loadDotenvStatus;
pub const deinitDotenv = shared.deinitDotenv;
pub const resetEnv = shared.resetEnv;
pub const __mer_set_env_status = shared.__mer_set_env_status;
pub const FetchRequest = shared.FetchRequest;
pub const FetchResponse = shared.FetchResponse;
pub const fetch = shared.fetch;
pub const fetchAll = shared.fetchAll;
pub const wasmBeginCollect = shared.wasmBeginCollect;
pub const wasmEndCollect = shared.wasmEndCollect;
pub const wasmEndCollectV2 = shared.wasmEndCollectV2;
pub const wasmExpectedState = shared.wasmExpectedState;
pub const wasmRestoreExpectedState = shared.wasmRestoreExpectedState;
pub const wasmProvideResult = shared.wasmProvideResult;
pub const wasmProvideResultV2 = shared.wasmProvideResultV2;
pub const wasmClearCache = shared.wasmClearCache;
pub const wasmClearCacheV2 = shared.wasmClearCacheV2;
pub const Meta = shared.Meta;
pub const h = shared.h;
pub const lint = shared.lint;
pub const css = shared.css;
pub const render = shared.render;
pub const dhi = shared.dhi;
pub const RenderFn = shared.RenderFn;
pub const StreamRenderFn = shared.StreamRenderFn;
pub const Route = shared.Route;

test "worker public API aliases preserve shared parity and type identity" {
    inline for (.{
        "typedJson",
        "parseJson",
        "formParam",
        "env",
        "putEnv",
        "loadDotenv",
        "loadDotenvStatus",
        "deinitDotenv",
        "resetEnv",
        "fetch",
        "fetchAll",
        "wasmEndCollect",
        "wasmEndCollectV2",
        "wasmProvideResult",
        "wasmProvideResultV2",
        "wasmClearCache",
        "wasmClearCacheV2",
        "render",
    }) |name| {
        try std.testing.expect(@hasDecl(WorkerApi, name));
        try std.testing.expect(@TypeOf(@field(WorkerApi, name)) == @TypeOf(@field(shared, name)));
    }
    try std.testing.expect(Request == shared.Request);
    try std.testing.expect(Response == shared.Response);
    try std.testing.expect(StreamWriter == shared.StreamWriter);
    try std.testing.expect(Meta == shared.Meta);
    try std.testing.expect(Route == shared.Route);
    try std.testing.expect(h.Node == shared.h.Node);
}
