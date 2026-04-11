# merjs Distribution Packages

This directory contains the npm and PyPI package configurations for distributing merjs via popular package managers.

## Overview

| Package Manager | Package Name | Install Command | Status |
|----------------|--------------|-----------------|--------|
| npm | `merjs` | `npm install -g merjs` | Ready to publish |
| PyPI | `merjs` | `pip install merjs` | Ready to publish |
| Homebrew | `merjs` | `brew install merjs` | Future |
| Cargo | `merjs` | `cargo install merjs` | Future |

## npm Package (`npm/`)

### Structure
- `package.json` - Package manifest with platform/cpu restrictions
- `install.js` - Post-install script that downloads the correct binary
- `index.js` - Programmatic API for Node.js users
- `bin/mer` - CLI wrapper script

### How it Works
1. User runs `npm install -g merjs`
2. `postinstall` hook runs `install.js`
3. Script detects platform (macOS/Linux/Windows) and arch (x64/arm64)
4. Downloads appropriate binary from GitHub releases
5. Verifies SHA256 checksum
6. Places binary in `bin/` directory

### Testing Locally
```bash
cd dist/npm
npm pack                    # Create tarball
npm install -g ./merjs-*.tgz  # Test install
mer init test-app           # Verify it works
```

## PyPI Package (`pypi/`)

### Structure
- `pyproject.toml` - Modern Python packaging configuration
- `setup.py` - Custom install command with binary download
- `src/merjs/` - Python package
  - `__init__.py` - Package API with `get_binary_path()`
  - `cli.py` - Entry point that wraps the mer binary
  - `install.py` - Binary download logic

### How it Works
1. User runs `pip install merjs`
2. `setup.py` custom install command triggers binary download
3. Downloads and verifies binary from GitHub releases
4. Registers `mer` and `merjs` CLI entry points

### Testing Locally
```bash
cd dist/pypi
python -m build               # Create wheel and sdist
pip install ./dist/merjs-*.whl  # Test install
mer init test-app           # Verify it works
```

## Publishing

### Prerequisites
1. **npm**: Create account at npmjs.com, get `NPM_TOKEN` secret
2. **PyPI**: Create account at pypi.org, get `PYPI_TOKEN` secret

### Manual Publishing

```bash
# npm
cd dist/npm
npm version 0.2.3
npm publish --access public

# PyPI
cd dist/pypi
# Update version in pyproject.toml and __init__.py
python -m build
twine upload dist/*
```

### Automated Publishing
GitHub Actions workflows handle publishing on release:
- `.github/workflows/npm-publish.yml`
- `.github/workflows/pypi-publish.yml`

## Version Synchronization

Both packages should stay in sync with the main merjs version:

| File | Version Location |
|------|------------------|
| `package.json` | `"version": "0.2.2"` |
| `pyproject.toml` | `version = "0.2.2"` |
| `src/merjs/__init__.py` | `__version__ = "0.2.2"` |

## Platform Support

### Current
- ✅ macOS Intel (x86_64)
- ✅ macOS Apple Silicon (arm64)
- ✅ Linux x64
- ✅ Linux ARM64
- ✅ Windows x64

### Future
- Windows ARM64 (when Zig supports)
- FreeBSD (community request)

## Troubleshooting

### npm install fails with "unsupported platform"
Check your Node.js version: `node --version` (needs 16+)

### pip install fails
Check Python version: `python --version` (needs 3.8+)

### Binary not found after install
- Check internet connection (binary downloads from GitHub)
- Try force reinstall: `npm install -g merjs --force` or `pip install --force-reinstall merjs`
- Check antivirus isn't blocking the binary (Windows)

## Security

- All binaries are SHA256 verified before use
- Downloads use HTTPS from official GitHub releases
- npm package has `cpu` and `os` restrictions to prevent install on unsupported platforms

## License

MIT - Same as merjs
