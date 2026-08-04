# merlionjs

Next.js-style web framework in Zig — zero Node.js required.

## Installation

```bash
npm install -g merlionjs
# or
npx merlionjs init my-app
```

The matching release binary is checksum-verified during installation. If the checksum cannot be downloaded or validated, installation aborts without leaving a partial binary.

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
- Node.js 16+ (for this installer only)

## Platform Support

- macOS (Intel & Apple Silicon)
- Linux (x64 & ARM64)

Windows is not published yet; the installer fails as unsupported instead of requesting a missing release asset.

## Documentation

Visit [merlionjs.com](https://merlionjs.com) for full documentation.

## License

MIT
