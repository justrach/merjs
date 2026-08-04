# merjs Desktop (macOS MVP)

A native macOS host for merjs using the system `NSWindow` and `WKWebView`.
It is a single Zig binary with no Node.js, Electron, or bundled browser.

```bash
zig build desktop
open zig-out/MerApp.app
```

When launched, the app starts the example site on an ephemeral loopback port,
waits for the server to bind, and opens `http://127.0.0.1:<port>/` in WKWebView.
Closing the last window terminates the app.

## Public host API

Consumer entrypoints can present their own merjs server through `mer.native`:

```zig
try mer.native.runLoopback(ready.port, .{
    .title = "My App",
    .width = 1200,
    .height = 800,
});
```

`runLoopback` must be called from the process main thread and accepts only a
nonzero loopback-server port. It constructs the URL internally, validates the
title and dimensions, and returns after AppKit's event loop terminates. The app
remains responsible for starting and stopping its server. A macOS executable
using this API must link libc plus the AppKit, WebKit, and Foundation
frameworks, as the repository's `desktop` target does.

## Implementation

The host calls three Objective-C runtime primitives and uses a typed
`objc_msgSend` cast for each signature. It deliberately does not `@cImport`
AppKit or WebKit headers because their Objective-C syntax is not accepted by
Zig's C importer. See [`spike.zig`](spike.zig) for the original interop
research.

## Scope

This MVP extracts the existing macOS window into a reusable framework API and
keeps the working example build. It intentionally does **not** add:

- a JavaScript-to-Zig bridge or native command permissions
- a manifest or CLI scaffolding
- code signing, notarization, or updates
- Linux, Windows, or mobile hosts
- generalized app-bundle metadata or resources

The repository build still emits the example-specific `MerApp.app` bundle.
Manifest-driven downstream packaging is a separate follow-up so this native
runtime seam can be reviewed independently.
