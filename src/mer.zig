// mer.zig — public API surface for page authors.
// All user code imports this as `@import("mer")`.

const shared = @import("mer-shared.zig");
const session_mod = @import("session.zig");

// Worker-safe API. These aliases preserve the existing top-level names and
// share exact type identity with mer-worker.zig.
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

// Native-only session API.
pub const Session = session_mod.Session;
pub const SESSION_DEFAULT_TTL = session_mod.SESSION_DEFAULT_TTL;
pub const SESSION_SECRET_MIN_LENGTH = session_mod.SESSION_SECRET_MIN_LENGTH;
pub const signSession = session_mod.signSession;
pub const verifySession = session_mod.verifySession;
pub const sessionSigningSecret = session_mod.sessionSigningSecret;
pub const sessionVerificationSecrets = session_mod.sessionVerificationSecrets;

// Native-only telemetry and development tools.
pub const telemetry = @import("telemetry.zig");
pub const dev = @import("dev.zig");

// Native runtime (server, router, watcher, and prerender).
pub const Router = @import("router.zig").Router;
pub const LayoutFn = @import("router.zig").LayoutFn;
pub const StreamLayoutFn = @import("router.zig").StreamLayoutFn;
pub const Server = @import("server.zig").Server;
pub const Config = @import("server.zig").Config;
pub const ServerReady = @import("server.zig").ServerReady;
pub const ServerStop = @import("server.zig").ServerStop;
pub const RawHandler = @import("server.zig").RawHandler;
pub const RawHandlerResult = @import("server.zig").RawHandlerResult;
pub const Watcher = @import("watcher.zig").Watcher;
pub const runPrerender = @import("prerender.zig").run;

// Native shell (`mer native` / `mer package`).
pub const native = @import("native/mer.zig");
