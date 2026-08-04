# `mer native` — ship a merjs app as a native desktop app

A merjs project can be packaged and run as a small native desktop app: a Zig
shell hosting the system **WebView** (WKWebView on macOS today; WebKitGTK on Linux and WebView2 on Windows are planned) that loads the merjs
UI over a loopback HTTP server, with a `window.mer.invoke()` JS↔Zig bridge for
native calls. **No Electron, no bundled Chromium, no Node.**

This implements the [zero-native](https://github.com/vercel-labs/zero-native)
model — an unusually clean fit for merjs because the framework *already owns*
the HTTP server, routing, SSR, and hot-reload transport. The shell only adds
the WebView + window + bridge + packaging layer.

> PR #100 is based on the latest `main` branch and ships macOS first. Linux (WebKitGTK) and Windows (WebView2) are planned.

## Platform status

| Platform | WebView backend | Status |
|---|---|---|
| macOS | WKWebView + AppKit | Implemented, including `.app` packaging, signing hooks, notarization hooks, and production manifest gate. |
| Linux | WebKitGTK | Planned. Shared bridge/security code is being prepared for platform-neutral use; GTK/WebKitGTK window, message-origin extraction, navigation policy, and packaging remain to be implemented and validated. |
| Windows | WebView2 + Win32 | Planned. Shared bridge/security code is being prepared for platform-neutral use; COM/WebView2 hosting, navigation/message events, Windows path canonicalization, and packaging/signing remain to be implemented and validated. |

The shared pieces are being isolated in platform-neutral Zig (`shell.zig`, `bridge.zig`, `manifest.zig`, and `platform_commands.zig`). Platform-specific work is deliberately kept behind the WebView backend and command facade so Linux/Windows can be added without weakening the macOS bridge policy.

See [`docs/native-platforms.md`](native-platforms.md) for the staged Linux/Windows implementation plan and [`docs/native-zero-trust.md`](native-zero-trust.md) for the zero-trust security model and remaining maturity gaps.

---

## Quick start

From an existing merjs project:

```bash
mer add native     # scaffold mer.app.zon + native/main.zig, print build.zig snippet
```

Paste the printed snippet into `build.zig` (inside `pub fn build`), then:

```bash
mer native         # dev: launch a native window against the hot-reloading server
mer native build   # production-gated binary (ReleaseSmall; accepts -D build options)
mer package        # unsigned local .app (macOS): zig-out/<Display>.app with default prefix
mer package --sign # package + codesign (Developer ID; requires signing config)
mer package --sign -Dmacos-signing-identity="Developer ID Application: Example, Inc. (TEAMID)"
mer package --notarize # package + codesign + notarytool + stapler
mer native doctor # check macOS production manifest hardening
mer package --release # validate + sign + notarize + staple
```

`mer native` reuses the `mer dev` pipeline (codegen → serve) and attaches a
WebView window once the server reports its bound port. UI edits hot-reload
inside the window via the existing `/_mer/events` SSE channel — the shell does
not rebuild on UI edits. `mer native build` is intentionally fail-closed: it
runs the same embedded-mode production manifest and credential gate as
`mer native doctor` before producing a binary. Use `zig build native-dev-build`
for an explicit build-only development compile without that production gate.

---

## How it works

```
codegen → zig build serve (in-process)
   │  binds 127.0.0.1:0  (OS assigns a free port)
   │  ServerReady → bound port
   ▼
native shell (WKWebView)
   │  loadURL("http://127.0.0.1:<port>/")
   │  window.mer.invoke ⇄ bridge.zig ⇄ platform_commands.zig
   └─ SSE /_mer/events → live reload (dev mode)
```

The server, router, dispatch, SSR, and watcher are reused **unchanged** from the
web framework. The native layer lives under `src/native/`:

| File | Responsibility |
|---|---|
| `shell.zig` | Server-on-port-0 + `ServerReady` handshake + platform `openWindow`. |
| `macos.zig` | WKWebView + NSWindow via extern ObjC primitives (no `@cImport`); `WKScriptMessageHandler` glue for the bridge. |
| `bridge.zig` | `window.mer.invoke` dispatch: size/permission/origin/URL/path guards + comptime command registry. |
| `platform_commands.zig` | Facade that selects macOS command implementations today and unsupported stubs on planned platforms. |
| `macos_commands.zig` | macOS implementations for built-in clipboard/dialog/open/window commands. |
| `manifest.zig` | Comptime parse of `mer.app.zon`. |
| `main.zig` | The native binary entry point. |

The ObjC interop pattern (extern `objc_getClass`/`sel_registerName`/`objc_msgSend`
+ per-callsite typed casts, no `@cImport`) was proven in `examples/desktop/spike.zig`.

---

## The `mer.app.zon` manifest

```zig
.{
    .id = "com.example.my-app",       // → CFBundleIdentifier
    .name = "my-app",
    .display_name = "My App",         // → CFBundleName + .app bundle name
    .version = "0.1.0",               // → CFBundleVersion
    .web_engine = "system",           // "system" (v0.2.5) | "chromium" (unsupported)
    .server = .{
        .mode = "dev",                // "dev" (hot reload) | "embedded" (prod)
        .host = "127.0.0.1",         // native shell requires loopback IP literals
        .port = 0,                    // 0 = ephemeral; shell reads back via ServerReady
    },
    .capabilities = .{ "webview", "js_bridge" },
    .permissions = .{ "window", "clipboard", "dialog", "open" },
    .security = .{
        // Empty means no extra origins; the shell injects the exact runtime origin.
        .navigation = .{ .allowed_origins = .{} },
        .bridge = .{
            // Explicit command allowlist, similar to Tauri capabilities.
            .allowed_commands = .{ "mer.ping", "window.close" },
            // Per-command origin bindings use "command|origin". Port may be
            // omitted for the shell's ephemeral loopback origin. When configured,
            // every allowed command needs a matching origin rule.
            .command_origins = .{
                "mer.ping|http://127.0.0.1",
                "window.close|http://127.0.0.1",
            },
        },
        .open = .{
            .external_schemes = .{ "http", "https", "mailto" },
            .path_roots = .{ "public" },
        },
    },
    .macos = .{
        // Optional Developer ID signing/notarization config.
        // .signing_identity = "Developer ID Application: Example, Inc. (TEAMID)",
        // .team_id = "TEAMID",
        // .entitlements = "native/entitlements.plist",
        // .notarization_profile = "merjs-notary",
    },
    .update = .{
        // Signed update feed checks and artifact hash verification are implemented.
        // Automatic install/self-replacement remains deferred.
        // .provider = "github-releases", // or "custom-http"
        // .feed_url = "https://example.com/mer-native/update.json",
        // .public_key = "ed25519:base64-raw-32-byte-public-key",
    },
    .windows = .{
        .{ .label = "main", .title = "My App", .width = 1024, .height = 720 },
    },
}
```

The manifest is `@import`-ed comptime (like `build.zig.zon`), so every field
flows into the binary and the `.app` bundle with zero runtime parsing.

---

## The bridge: `window.mer.invoke`

Client code (in a page or WASM glue) calls a named command and awaits a result:

```js
const result = await window.mer.invoke("mer.ping", {});
console.log(result); // { pong: true }
```

Each call is:
1. **size-limited** — payloads > 64 KB are rejected;
2. **session-token checked** — the macOS shell generates an unguessable per-process bridge capability and the private injected shim echoes it in each envelope;
3. **permission-checked** — the command's declared permission must appear in the
   manifest's `permissions` list (deny-by-default);
4. **dispatched** — command name → handler via a comptime registry (same shape
   as merjs route tables in `src/dispatch.zig`);
5. **resolved** — the handler's JSON result is delivered back to the awaiting
   Promise via a token-echoing native response (`window.mer._resolve(response_token, id, ok, value)`).

### Built-in commands

| Command | Permission | Behavior |
|---|---|---|
| `mer.ping` | _(none)_ | Returns `{ "pong": true }`. Round-trip smoke test. |
| `mer.echo` | _(none)_ | Returns `{ "echo": true }` as a smoke ack (not an args echo). |
| `clipboard.read` | `clipboard` | Reads plain UTF-8 text from `NSPasteboard`; returns a string, or `""` when no text exists. |
| `clipboard.write` | `clipboard` | Writes plain UTF-8 text to `NSPasteboard`; accepts `{ text }` or a raw string; returns `null`. |
| `dialog.openFile` | `dialog` | Opens `NSOpenPanel` for one file; accepts optional `{ title }`; returns an absolute path string or `null` on cancel. |
| `dialog.pickDirectory` | `dialog` | Opens `NSOpenPanel` for one directory; accepts optional `{ title }`; returns an absolute path string or `null` on cancel. |
| `dialog.openDirectory` | `dialog` | Alias for `dialog.pickDirectory`. |
| `open.external` | `open` | Opens `{ url }` (or raw string) with `NSWorkspace.openURL`; returns `null`. |
| `open.path` | `open` | Opens `{ path }` (or raw string) with the default handler/Finder; disabled unless `security.open.path_roots` contains at least one explicit root. |
| `window.setTitle` | `window` | Sets the current key window title from `{ title }` (or raw string); returns `null`. |
| `window.close` | `window` | Closes the current key window (`performClose:`); returns `null`. |

### Custom commands

PR #100 includes a **static** app command extension point without dynamic plugin
loading. Native apps pass a comptime/constant slice of additional `Command`
entries through `Shell.run` options:

```zig
const bridge = mer.native.bridge;

fn exportData(ctx: *bridge.Ctx, args: std.json.Value) bridge.HandlerResult {
    _ = ctx;
    _ = args;
    return .{ .ok = "{\"exported\":true}" };
}

const app_commands = [_]bridge.Command{
    .{ .name = "app.exportData", .permission = "app.export", .handler = exportData },
};

try mer.native.Shell.run(allocator, app_manifest, &router, .{
    .commands = &app_commands,
});
```

Lower-level embedders can call `mer.native.bridge.dispatchWithRegistry(ctx,
payload, extra_commands)` directly, but must provide a valid `ctx.bridge_token` and include the same token in envelopes. Setting `ctx.require_bridge_token = false` is for non-WebView tests only; the macOS shim ignores legacy no-token responses.

Custom handlers must return valid JSON fragments (`null`, a string encoded with the
bridge JSON helpers, an object, etc.). Dispatch validates handler output before
embedding it in the JS resolver call and converts invalid fragments to `HandlerError`,
but handlers should still avoid concatenating untrusted strings into `.ok`/`.ok_owned`
without JSON encoding.

Custom commands fail closed unless all of the following are true:

- the command name is in an app namespace such as `app.exportData`;
- the name does not use reserved built-in prefixes (`mer.`, `dialog.`,
  `clipboard.`, `open.`, `window.`);
- the command declares a non-empty permission;
- the manifest grants that permission;
- `security.bridge.allowed_commands` explicitly lists the command;
- any configured `security.bridge.command_origins` entry matches the caller
  origin.

Dynamic plugins, loading commands from disk, and third-party command bundles are
still intentionally deferred because they expand the native attack surface.

### Security model

The native shell currently loads the app over an embedded loopback URL such as
`http://127.0.0.1:<port>/`. Before dispatching bridge commands, the macOS
backend checks the `WKScriptMessage` frame origin against
`security.navigation.allowed_origins`. `shell.zig` prepends the exact runtime
origin after the server binds its ephemeral port, so portless manifest command-origin
entries (for example `http://127.0.0.1`) are safe only after the global exact-origin
check and do **not** wildcard every local server port. Bridge dispatch repeats the
global origin check for lower-level embedders before enforcing per-command origin
bindings. The macOS shell also injects a fresh random bridge token into the private
JS shim closure; direct `WKScriptMessage` posts that do not carry that token fail
before registry lookup or handler execution, and native responses must echo the
token before the shim resolves a pending Promise. Bridge dispatch then enforces the
explicit command allowlist, permission class, and command-specific URL/path restrictions
before calling the platform command facade.

---

## Dev vs production

- **Dev (`mer native`):** the shell runs the server with the file watcher on;
  `/_mer/events` SSE hot-reloads the WebView on `app/` changes. Fast inner loop.
- **Prod (`mer package`):** the SSR binary + WebView shell are built with
  `-Doptimize=ReleaseSmall`; hot reload is off; the result is a `.app` bundle
  whose `Info.plist` reflects `id` / `display_name` / `version` from the
  manifest. The configured static directory (default `public/`) is copied into
  `Contents/Resources/<static_dir>/` so Finder-launched apps do not depend on the repo CWD.
  Unsigned by default for fast local packaging.

---

## macOS code signing and notarization

Unsigned packages remain the default for local development:

```bash
zig build package -Doptimize=ReleaseSmall
mer package
```

For Developer ID distribution, set signing metadata in `mer.app.zon` or pass
build options:

```zig
.macos = .{
    .signing_identity = "Developer ID Application: Example, Inc. (TEAMID)",
    .team_id = "TEAMID",
    .entitlements = "native/entitlements.plist",
    .notarization_profile = "merjs-notary",
},
```

```bash
zig build package-sign -Doptimize=ReleaseSmall \
  -Dmacos-signing-identity="Developer ID Application: Example, Inc. (TEAMID)"

codesign --verify --deep --strict zig-out/<Display>.app

# After creating a notarytool keychain profile once:
# xcrun notarytool store-credentials merjs-notary --apple-id ... --team-id ... --password ...
zig build package-notarize -Doptimize=ReleaseSmall -Dmacos-notarization-profile=merjs-notary
spctl --assess --type execute --verbose zig-out/<Display>.app
```

`package-sign` requires signing identity/entitlements only and runs:

```bash
codesign --deep --force --options runtime --timestamp --sign <identity> [--entitlements <plist>] zig-out/<Display>.app
```

`zig-out/<Display>.app` is the default Zig prefix output; custom `zig build --prefix <dir>` writes the bundle under that prefix. The full production gate (signing identity + notarization profile + update trust root + hardened manifest checks) runs before any signing side effect for `package-notarize` and `native-prod-release`. Signing/notarization values supplied through `-Dmacos-*` options satisfy the same gate as manifest values.

Packaging requires the static root to resolve inside the project and rejects nested symlinks rather than risk copying files from outside the asset root into the bundle. Production release packaging clears the previous `.app` after the gate passes so removed assets cannot survive into the signed bundle.

`package-notarize` signs, zips the app with `ditto --keepParent`, submits it via
`xcrun notarytool submit --wait`, then staples the ticket with
`xcrun stapler staple`. merjs does not store Apple credentials; use a keychain
profile.

---

## Native security status

Implemented in PR #100 plus hardening follow-up:

- deny-by-default built-in command registry;
- static custom command registry API with reserved-prefix, permission, allowlist,
  and origin-binding validation;
- 64 KB bridge payload cap;
- per-process random bridge token required on shell-injected bridge envelopes;
- embedded-NUL guard before dispatch;
- strict global origin check from the `WKScriptMessage` frame;
- WKWebView navigation delegate cancellation for non-allowed origins;
- explicit command allowlist via `security.bridge.allowed_commands`;
- per-command origin bindings via `security.bridge.command_origins`;
- `open.external` scheme allowlist (`http`, `https`, `mailto` by default) plus strict URL structure checks for native handoff;
- fail-closed `open.path` roots (no roots means `PathDenied`);
- manifest-driven macOS signing/notarization hooks;
- signed update feed/config checks (`src/native/update.zig`) for HTTPS feeds,
  Ed25519 signatures over canonical metadata, SHA-256 artifact hashes, platform
  uniqueness, version comparisons, signed metadata_version anti-replay state, and rollback-window metadata;
- artifact byte verification against signed size/SHA-256 metadata.

Still deferred / not production-complete:

- automatic updater install/self-replacement and durable rollback state;
- full Linux WebKitGTK and Windows WebView2 backends;
- dynamic plugin loading / third-party command bundles;
- UI prompts for every sensitive native API;
- independent production security audit and cross-platform pen-test.

See `SECURITY.md` for the project-wide vulnerability policy and native threat
model checklist. See `docs/native-production.md` for the macOS production
release gate and signing/notarization flow.

---

## Limitations (PR #100 / v0.2.5 target)

- macOS only (WKWebView). Linux (WebKitGTK) and Windows (WebView2) are planned and documented in `docs/native-platforms.md`.
- Built-in command allowlists, per-command origins, and static app-level custom bridge command registries are implemented. Dynamic plugin loading is deferred.
- Signed update feed/config checks and artifact hash verification are implemented. Runtime install/self-replacement is deferred.
- Code signing / notarization hooks exist for macOS, but release credentials,
  notarized artifacts, and CI distribution are not configured by default.
- `web_engine = "chromium"` (CEF) is parsed but unsupported.
- `server.mode = "static"` (fully static export over `mer://app`) is a stretch
  goal; this target runs the embedded loopback server in both dev and prod.

See `plans/mer-native.md` for the full design and phased roadmap.
