# Security Policy

## Supported versions

merjs is pre-1.0 and experimental. Only the latest commit on `main` receives security fixes.

## Reporting a vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Email **rach@merlionjs.com** with:

- A description of the vulnerability and its impact
- Steps to reproduce (minimal PoC if possible)
- Affected component (`src/server.zig`, `src/native/bridge.zig`, `worker/worker.js`, etc.)
- Your suggested fix if you have one

You will receive an acknowledgement within 48 hours and a resolution timeline within 7 days.

## Scope

In scope:

- HTTP server request handling (`src/server.zig`)
- Session signing/verification (`src/mer.zig` `signSession`/`verifySession`)
- Cloudflare Workers WASM handler (`worker/worker.js`)
- `merjs-auth` package (`packages/merjs-auth/`)
- Native shell bridge, manifest, and packaging code (`src/native/`, `mer.app.zon`, native `build.zig` steps)

Out of scope:

- Vulnerabilities in Zig toolchain itself (report to https://github.com/ziglang/zig)
- Issues in third-party dependencies (dhi, Tailwind, system WebView runtimes)
- Demo/example apps that are not the framework runtime

## Native security model (`mer native`)

`mer native` is a small native shell around the system WebView. It does **not** bundle Node, npm, Electron, or Chromium. The app UI is served by the embedded merjs loopback server and the native bridge is exposed as `window.mer.invoke()`.

### Implemented hardening

- **Loopback binding:** the shell binds the embedded server to `127.0.0.1` by default, uses an ephemeral port (`port = 0`), and rejects non-loopback/non-literal native `server.host` values (`localhost` is intentionally rejected; use `127.0.0.1`).
- **Runtime origin pinning:** after the server binds, `shell.zig` prepends the exact `http://host:port` origin to the allowed origin list.
- **Bridge origin validation:** the macOS backend reads the `WKScriptMessage` frame origin and rejects calls before dispatch when the origin is not allowed; bridge dispatch also enforces the global origin allowlist for lower-level embedders.
- **WebView navigation policy:** the macOS shell installs a `WKNavigationDelegate` and cancels navigation to non-allowed origins.
- **Payload limits:** bridge payloads over 64 KB are rejected.
- **Session-scoped bridge token:** the native shell generates a 256-bit random capability per process, injects it into the private JS shim closure, `bridge.zig` rejects missing/invalid tokens before command lookup, and native responses must echo the token before the shim resolves a pending Promise.
- **Embedded-NUL guard:** NSString payload byte length is compared against `UTF8String` length so NUL truncation cannot hide data from dispatch.
- **Deny-by-default command registry:** unknown command names return `UnknownCommand`.
- **Static custom command validation:** app-provided commands must use non-reserved names, non-empty permissions, explicit `allowed_commands`, and the same origin/permission gates as built-ins; dynamic plugin loading is not supported.
- **Permission classes:** built-in commands require manifest permissions such as `clipboard`, `dialog`, `open`, and `window`.
- **Explicit command allowlist:** `security.bridge.allowed_commands` can restrict the manifest to exact command names, similar to Tauri capabilities.
- **Per-command origins:** `security.bridge.command_origins` can bind commands to origins with `"command|origin"` entries; when configured, commands without a matching origin rule are denied.
- **Safer open commands:** `open.external` rejects disallowed schemes (default: `http`, `https`, `mailto`) and malformed/native-ambiguous URLs; `open.path` fails closed unless explicit path roots are configured.
- **macOS signing hooks:** `zig build package-sign` / `mer package --sign` run hardened-runtime `codesign`; `package-notarize` / `mer package --notarize` run `notarytool` and `stapler`.
- **Signed update checks:** `src/native/update.zig` verifies HTTPS feed/config shape, Ed25519 signatures over canonical update metadata, SHA-256 artifact hashes, platform uniqueness, signed metadata_version anti-replay state, and rollback-window metadata before reporting an update.

### Not yet done / do not claim production-complete

- **Auto-updater install/runtime:** signed update checks and artifact byte verification are implemented, but merjs does not automatically replace the running app yet.
- **Durable rollback prevention:** version window metadata is validated; persistent installed-version rollback protection is planned with the installer runtime.
- **Full Linux support:** WebKitGTK backend and package integration are planned but not implemented; see `docs/native-platforms.md`.
- **Full Windows support:** WebView2 backend and package integration are planned but not implemented; see `docs/native-platforms.md`.
- **Dynamic plugin system:** static app command registries are implemented; loading commands/plugins from disk and plugin capability manifests are not implemented.
- **Advanced navigation policy:** basic origin-based WKWebView navigation cancellation is implemented; richer per-window route policies and external-browser handoff are still future hardening items.
- **Universal user prompts:** OS dialogs prompt where applicable, but merjs does not yet prompt for every sensitive bridge command.
- **Independent production audit:** a full third-party audit / pen-test has not been completed.

See also `docs/native-production.md` for the macOS production release gate, `docs/native-platforms.md` for the Linux/Windows backend plan, and `docs/native-zero-trust.md` for the zero-trust model and remaining maturity gaps.

## Native release checklist

Before presenting a native app as production-ready, run or document:

```bash
zig build test
zig build cli
zig build native-build -Doptimize=ReleaseSmall
zig build package -Doptimize=ReleaseSmall
```

For signed macOS distribution:

```bash
zig build package-sign -Doptimize=ReleaseSmall \
  -Dmacos-signing-identity="Developer ID Application: Example, Inc. (TEAMID)"
codesign --verify --deep --strict zig-out/<Display>.app

zig build package-notarize -Doptimize=ReleaseSmall -Dmacos-notarization-profile=<keychain-profile>
spctl --assess --type execute --verbose zig-out/<Display>.app
```

Security smoke tests to keep in CI/manual review:

- missing or wrong bridge token returns `InvalidToken` when a shell token is configured
- unknown command returns `UnknownCommand`
- missing permission returns `PermissionDenied`
- unlisted command returns `CommandDenied` when `allowed_commands` is configured
- allowed command without a command-origin rule returns `OriginNotAllowed` when `command_origins` is configured
- wrong command origin returns `OriginNotAllowed`
- oversized payload returns `PayloadTooLarge`
- malformed JSON returns `ParseError`
- `open.external` rejects `javascript:`, unexpected schemes, malformed HTTP(S), userinfo, controls, and backslashes
- `open.path` rejects paths outside configured roots
