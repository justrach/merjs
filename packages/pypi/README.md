# merlionjs

Next.js-style web framework in Zig — zero Node.js required.

## Installation

```bash
pip install merlionjs
```

The matching release binary is downloaded and checksum-verified on first use. It is installed atomically in a version- and platform-specific user cache, never in the Python package directory. Concurrent first runs share one verified download, and a failed checksum leaves no partial binary.

The cache is `$XDG_CACHE_HOME/merjs` when `XDG_CACHE_HOME` is set, or `~/.cache/merjs` otherwise. Set `XDG_CACHE_HOME` to a writable absolute path when the default home or cache is read-only. `MER_INSTALL_REPO` and `MER_INSTALL_VERSION` continue to select an alternate release repository or version.

## Usage

```bash
# Create new project
mer init my-app
cd my-app

# Start dev server
zig build serve

# Build for production
zig build prod
```

## Requirements

- Zig 0.15.1+
- Python 3.8+ (for this installer only)

## Platform Support

- macOS (Intel & Apple Silicon)
- Linux (x64 & ARM64)

Windows is not published yet; the installer fails as unsupported instead of requesting a missing release asset.

## Documentation

Visit [merlionjs.com](https://merlionjs.com) for full documentation.

## License

MIT
