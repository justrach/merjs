# merjs Desktop (experimental)

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

The ObjC bridge uses `extern fn` declarations for three runtime primitives (`objc_getClass`, `sel_registerName`, `objc_msgSend`) and typed function pointer casts for every method call. No `@cImport` of AppKit/WebKit headers — those contain Objective-C syntax that Zig's translate-c can't parse.

See [`spike.zig`](spike.zig) for the full research notes and the interop pattern decision (issue #50).

## Files

| File | Purpose |
|---|---|
| `spike.zig` | #50 research spike — proves Zig→ObjC bridge pattern |
| `main.zig` | Full app: server thread + NSApp run loop + WKWebView |

## Status

Experimental. The window opens and loads the merjs site from a local server. Known gaps:

- No app icon
- No `cmd+w` / `cmd+q` keyboard shortcuts wired to `[NSApp terminate:]`
- No code signing (runs fine locally, not distributable via App Store)
- Server shutdown on window close not yet wired

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
