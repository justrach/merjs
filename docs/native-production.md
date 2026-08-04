# `mer native` macOS production checklist

This checklist is for shipping a **macOS** `mer native` app. Linux, Windows, mobile, and a mature plugin/updater runtime remain tracked separately.

Linux/WebKitGTK and Windows/WebView2 production packaging/signing/runtime checks will be added with those native backends. See [`docs/native-platforms.md`](native-platforms.md) for the staged platform plan.

## 1. Harden the manifest

Production manifests should use explicit least privilege:

```zig
.permissions = .{ "window", "clipboard", "dialog", "open" },
.security = .{
    // Empty means no extra navigation origins; the shell injects the exact
    // runtime http://127.0.0.1:<port> origin after binding.
    .navigation = .{ .allowed_origins = .{} },
    .bridge = .{
        .allowed_commands = .{
            "mer.ping",
            "dialog.openFile",
            "open.external",
            "window.close",
        },
        .command_origins = .{
            "mer.ping|http://127.0.0.1",
            "dialog.openFile|http://127.0.0.1",
            "open.external|http://127.0.0.1",
            "window.close|http://127.0.0.1",
        },
    },
    .open = .{
        .external_schemes = .{ "https", "mailto" },
        // No shell expansion is performed; use repo-relative or absolute paths.
        .path_roots = .{ "public", "/Users/me/Documents/MyApp" },
    },
},
```

Command-origin examples may omit the ephemeral port only because the shell first enforces the exact runtime origin globally and bridge dispatch repeats that global allowlist check.

`mer native` enforces these in two places:

- the WKWebView navigation delegate cancels navigation to non-allowed origins;
- the native shell injects a fresh per-process bridge token into the private JS shim;
- the `window.mer.invoke()` bridge checks the session token, origin, command allowlist, command origin bindings, permission class, and command-specific URL/path restrictions.

## 2. Configure signing and notarization

```zig
.macos = .{
    .signing_identity = "Developer ID Application: Example, Inc. (TEAMID)",
    .team_id = "TEAMID",
    .entitlements = "native/entitlements.plist", // optional
    .notarization_profile = "merjs-notary",
},
```

Create the notarytool keychain profile once:

```bash
xcrun notarytool store-credentials merjs-notary \
  --apple-id you@example.com \
  --team-id TEAMID \
  --password app-specific-password
```

## 3. Configure update metadata

The production gate requires update metadata so releases do not ship without an update trust root:

```zig
.update = .{
    .provider = "github-releases", // or "custom-http"
    .feed_url = "https://example.com/my-app/update.json",
    .public_key = "ed25519:base64-raw-32-byte-public-key",
},
```

`src/native/update.zig` now implements signed update checks and artifact verification helpers. It requires strict HTTPS feed/artifact URLs, a base64 raw 32-byte Ed25519 public key, Ed25519 signatures over canonical metadata, lowercase SHA-256 artifact hashes, positive artifact sizes, unique `(os, arch)` platform entries, signed monotonic `metadata_version`, and numeric `N[.N[.N]]` version metadata.

Current status: this is not an automatic installer yet. merjs can verify signed update metadata and artifact bytes. The caller must durably persist the complete `UpdateState` returned by every authenticated result variant (`no_update`, `update_available`, and `required_update`) and pass it to the next check for the same `(os, arch)` target; state is target-bound and must be stored separately per target. `required_update` carries the verified update information when the current version is below `min_supported_version`; persist its state before proceeding with that required update. It contains the highest accepted `metadata_version`, a target digest, and the SHA-256 digest of the verified canonical signed payload: lower versions are rejected, a repeated equal version is accepted only when its digest matches, a different valid payload at the same version is rejected as equivocation, and cross-target state reuse is rejected explicitly. Disabled update configuration returns the supplied state unchanged. merjs does **not** replace the running app or perform platform-specific install/rollback in this PR. Do not claim automatic updates until installer/rollback behavior and updater UX are implemented and audited.

Example feed contract:

```json
{
  "schema_version": 1,
  "metadata_version": 42,
  "app_id": "com.example.my-app",
  "version": "1.2.3",
  "min_supported_version": "1.0.0",
  "notes_url": "https://example.com/my-app/releases/1.2.3",
  "platforms": [{
    "os": "macos",
    "arch": "aarch64",
    "url": "https://example.com/my-app/MyApp-1.2.3-aarch64.zip",
    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "size": 12345678,
    "signature": "ed25519:base64-raw-64-byte-signature"
  }]
}
```

## 4. Run the production gate

```bash
mer native doctor
# or
zig build native-prod-check
```

Both forms accept `-Dmacos-signing-identity=...` and
`-Dmacos-notarization-profile=...` when credentials are intentionally kept out
of `mer.app.zon`.

This fails if the manifest is missing or misconfigures:

- native `.server.mode = "embedded"` (development/hot-reload mode cannot ship)
- native `.server.host` loopback IP-literal binding (`127.0.0.1` recommended; `localhost` is intentionally rejected)
- `.macos.signing_identity`
- `.macos.notarization_profile`
- extra `.security.navigation.allowed_origins` without loopback/localhost (`localhost`, `127.*`, `[::1]`); an empty list is valid and means only the shell-injected runtime origin is allowed
- non-empty `.security.bridge.allowed_commands`
- non-empty `.security.bridge.command_origins`
- non-empty `.security.open.external_schemes`
- non-empty `.security.open.path_roots`
- `.update.provider` (`github-releases` or `custom-http`)
- `.update.feed_url` (strict `https://` URL)
- `.update.public_key` (`ed25519:<base64 raw 32-byte public key>`)

## 5. Build, sign, notarize, staple

For a production-gated standalone binary (without packaging), run:

```bash
mer native build -Dmacos-signing-identity="Developer ID Application: …" \
  -Dmacos-notarization-profile=merjs-notary
```

This invokes the same `native-prod-check` gate as `mer native doctor`; it does
not silently produce a "production" binary from a development-mode manifest.
For a build-only development compile, use `zig build native-dev-build`.

For a signed, notarized app bundle, run:

```bash
mer package --release
# or
zig build native-prod-release -Doptimize=ReleaseSmall
```

Equivalent manual flow:

```bash
zig build package -Doptimize=ReleaseSmall
zig build package-sign -Doptimize=ReleaseSmall
codesign --verify --deep --strict zig-out/<Display>.app

zig build package-notarize -Doptimize=ReleaseSmall
spctl --assess --type execute --verbose zig-out/<Display>.app
```

`package-sign` requires a signing identity; entitlements are optional. `package-notarize` and
`native-prod-release` run the full production gate before signing, including notarization and
update trust-root metadata. Signing identity, entitlements, and notarization profile may come
from `mer.app.zon` or the corresponding `-Dmacos-*` options, so credentials do not need to be
committed. Paths above use Zig's default install prefix; custom `zig build --prefix <dir>` writes
`<Display>.app` under that prefix.

The package step also copies the configured static directory (default `public/`)
into `Contents/Resources/<static_dir>/` so Finder-launched apps do not depend on the repo CWD.
The static root must resolve inside the project, and nested symlinks are rejected to prevent
packaging files outside the configured asset root. Production release packaging removes any
previous `.app` after the gate passes, then rebuilds it so deleted assets cannot survive into a
signed release.

## 6. Manual smoke test

```bash
open zig-out/<Display>.app
```

Verify:

- app window opens;
- root route returns HTTP 200;
- `window.mer.invoke("mer.ping", {})` returns `{ "pong": true }`;
- an ad-hoc `window.webkit.messageHandlers.merInvoke.postMessage(JSON.stringify({cmd:"mer.ping",id:1,args:null}))` does not execute a handler or resolve/reject an existing `window.mer.invoke` promise;
- navigation to an unlisted origin is cancelled;
- unknown command returns `UnknownCommand`;
- missing permission returns `PermissionDenied`;
- unlisted command returns `CommandDenied`;
- bad origin returns `OriginNotAllowed`;
- `open.external` rejects `javascript:`, malformed HTTP(S), controls, backslashes, and userinfo;
- `open.path` rejects paths outside configured roots;
- closing the final window exits the app.
