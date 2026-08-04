# Native platform roadmap: Linux + Windows

`mer native` ships macOS first in PR #100. Linux and Windows support should be added without weakening the bridge/security model that now exists for macOS.

This document is the implementation plan for the owner-requested Linux/WebKitGTK and Windows/WebView2 support.

## Non-negotiable security invariants

Every platform backend must preserve these shared rules:

1. The shell starts the merjs loopback server on an ephemeral port and injects the exact runtime origin into `bridge.Ctx` after binding.
2. The WebView backend blocks navigation to origins not allowed by `security.navigation.allowed_origins`.
3. The bridge message handler verifies the actual sender origin before dispatch whenever the WebView API exposes it.
4. `bridge.dispatch` remains the central gate for payload size, JSON parsing, command allowlist, per-command origin bindings, permission class, and handler dispatch.
5. `open.external` validates URL schemes before calling platform APIs.
6. `open.path` validates a canonical path against configured roots before calling platform APIs.
7. Platform commands stay behind `src/native/platform_commands.zig`; backend files should not bypass shared bridge policy.

## Current status

| Area | macOS | Linux | Windows |
|---|---|---|---|
| WebView window | WKWebView/AppKit implemented | WebKitGTK planned | WebView2/Win32 planned |
| JS bridge transport | `WKScriptMessageHandler` implemented | `WebKitUserContentManager` planned | `window.chrome.webview.postMessage` planned |
| Sender-origin check | `WKScriptMessage.frameInfo.securityOrigin` implemented | Needs WebKitGTK validation / possible web extension | WebView2 `WebMessageReceived.Source` planned |
| Navigation policy | WK navigation delegate implemented | `decide-policy` planned | `NavigationStarting` planned |
| Built-in commands | macOS commands implemented | GTK/GIO commands planned | Win32/Shell APIs planned |
| Packaging | `.app`, codesign, notary hooks | AppImage/`.deb`/Flatpak TBD | MSIX/WiX/plain bundle TBD |
| Production gate | macOS manifest gate implemented | Platform gate TBD | Platform gate TBD |

## Phase 1 — platform-ready shared code (implemented before enabling runtime support)

Scope:

- Keep native runtime/package commands macOS-only.
- Add a command facade (`src/native/platform_commands.zig`) so `bridge.zig` no longer imports macOS command files directly.
- Provide unsupported-platform command stubs for non-macOS builds.
- Document the Linux/Windows plan and platform-specific blockers.
- Keep non-native Linux/Windows builds free of GTK/WebKitGTK/WebView2 dependencies.

Acceptance tests:

```sh
zig build test
zig build cli
zig build worker
zig build wasm
zig build prod
zig test src/native/platform_commands.zig -target x86_64-linux --test-no-exec
zig test src/native/platform_commands.zig -target x86_64-windows --test-no-exec
zig test src/native/bridge.zig -target x86_64-linux --test-no-exec -lc
zig test src/native/bridge.zig -target x86_64-windows --test-no-exec
```

On macOS, also keep:

```sh
zig build native-build -Doptimize=ReleaseSmall
zig build package -Doptimize=ReleaseSmall
```

## Phase 2 — Linux WebKitGTK runtime spike

Target stack: GTK 3 + WebKitGTK 4.1.

New files:

- `src/native/linux.zig` — GTK window, WebKitWebView, user script injection, bridge callback, navigation policy, GTK main loop.
- `src/native/linux_commands.zig` — clipboard/dialog/open/window command implementations.

Build/CLI changes:

- Split `build.zig` native setup into shared executable creation plus platform linking.
- For Linux, require pkg-config libraries such as `gtk+-3.0` and `webkit2gtk-4.1`.
- Allow `mer native` / `mer native build` on Linux only when native dependencies are discoverable.
- Keep macOS `.app` packaging/signing/notary separate.

Linux backend milestones:

1. Initialize GTK and create a top-level window using manifest title/size.
2. Create `WebKitUserContentManager` and inject the same `window.mer.invoke` shim shape.
3. Register a `merInvoke` script message handler that accepts only string JSON payloads.
4. Enforce payload limit and sender origin, set `ctx.current_origin`, call `bridge.dispatch`, and evaluate the returned JS resolver.
5. Connect `decide-policy` and cancel navigation when `bridge.isOriginAllowed` denies the URL.
6. Implement `window.setTitle`, `window.close`, `open.external`, clipboard, and dialogs.
7. Enable `open.path` only after Linux canonical path/root checks are validated against symlinks and traversal.

Open security question:

- WebKitGTK must provide a reliable way to identify the script-message sender origin. If the main API cannot expose origin equivalently to WKWebView, use a WebKit web extension or explicitly keep Linux bridge support disabled until this is solved. Do not rely only on injected JS self-reporting.

Linux validation:

```sh
sudo apt-get install -y libgtk-3-dev libwebkit2gtk-4.1-dev
zig build test
zig build native-build
zig build native -- --dev
```

Manual smoke:

```js
await window.mer.invoke("mer.ping", {})
await window.mer.invoke("window.setTitle", { title: "Linux native smoke" })
```

Also verify blocked navigation, bad origin, unknown command, missing permission, unlisted command, and disallowed URL/path cases.

## Phase 3 — Windows WebView2 runtime spike

Target stack: Win32 + WebView2 Runtime.

New files:

- `src/native/win32.zig` — Win32 window/message loop, WebView2 controller lifecycle, bridge callback, navigation policy.
- `src/native/win32_commands.zig` — clipboard/dialog/open/window command implementations.
- Optional split files: `src/native/webview2.zig`, `src/native/win32_com.zig` for COM declarations and event handlers.

Build/CLI changes:

- Link Windows system libraries and WebView2 loader/runtime strategy.
- Allow `mer native` / `mer native build` on Windows only after WebView2 runtime detection has a clear error path.
- Keep Windows packaging/signing separate from macOS `.app` packaging.

Windows backend milestones:

1. `CoInitializeEx(..., COINIT_APARTMENTTHREADED)` and create a Win32 `HWND` from manifest title/size.
2. Create the WebView2 environment/controller/webview and resize the controller on `WM_SIZE`.
3. Inject the `window.mer.invoke` shim with `AddScriptToExecuteOnDocumentCreated` and use `window.chrome.webview.postMessage`.
4. Handle `WebMessageReceived`, read `TryGetWebMessageAsString`, verify `Source`, set `ctx.current_origin`, call `bridge.dispatch`, and execute the resolver JS.
5. Handle `NavigationStarting` and cancel disallowed origins.
6. Implement `window.setTitle`, `window.close`, `open.external`, clipboard, and dialogs.
7. Enable `open.path` only after Windows canonicalization handles drive letters, UNC paths, backslashes, case-insensitivity, symlinks, and junctions.

Windows validation:

```powershell
zig build test
zig build native-build
zig build native -- --dev
```

Manual smoke:

```js
await window.mer.invoke("mer.ping", {})
await window.mer.invoke("window.setTitle", { title: "Windows native smoke" })
```

Also verify missing WebView2 Runtime error handling, blocked navigation, bad origin, unknown command, missing permission, unlisted command, and disallowed URL/path cases.

## Phase 4 — Linux/Windows packaging and production gates

Packaging should not be bolted onto the macOS gate. Add platform-specific release gates after runtime support lands.

Linux options:

- AppImage
- `.deb`
- Flatpak

Windows options:

- plain distribution directory
- MSIX
- WiX/Inno installer

Production gates should validate platform-specific signing/runtime/update requirements, including update trust roots, runtime dependency strategy, signing certificates, timestamping, rollback prevention, and smoke-test checklists.
