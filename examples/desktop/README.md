# merjs Desktop (macOS MVP)

A native macOS app wrapper for merjs. Single Zig binary. Zero node_modules. No Electron.

```bash
zig build desktop
open zig-out/MerApp.app
```

## What it does

1. Spins up the merjs HTTP server on a random local port
2. Opens a native `NSWindow` + `WKWebView` pointing at that port
3. Packages as a proper `.app` bundle

## How it works

The host calls the Objective-C runtime with typed function pointer casts for every method signature. No `@cImport` of AppKit/WebKit headers — those contain Objective-C syntax that Zig's translate-c can't parse.

See [`spike.zig`](spike.zig) for the full research notes and the interop pattern decision (issue #50).

## Public API

Apps can present an existing loopback server from the process main thread:

```zig
try mer.native.runLoopback(ready.port, .{
    .title = "My App",
});
```

The app owns server startup and shutdown. Its macOS target must link libc plus AppKit, WebKit, and Foundation, as this repository's `desktop` target does.

## Status

MVP. The window opens and loads the merjs site from a local server. Known gaps:

- No app icon
- No code signing (runs fine locally, not distributable via App Store)
- No manifest, JS-to-Zig command bridge, updater, or cross-platform host
- WKWebView host needs a macOS machine to runtime-test

## Build output

```
zig-out/
  bin/
    merapp                    ← raw binary (also works standalone)
  MerApp.app/
    Contents/
      MacOS/
        merapp                ← same binary
      Info.plist
```
