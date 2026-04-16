#!/bin/bash
# Usage: curl -fsSL https://merjs.trilok.ai/install.sh | bash

set -e

REPO="justrach/merjs"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${VERSION:-latest}"

detect_os() {
    case "$(uname -s)" in
        Linux*)     echo "linux";;
        Darwin*)    echo "macos";;
        *)          echo "unknown";;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "x86_64";;
        arm64|aarch64)  echo "arm64";;
        *)              echo "unknown";;
    esac
}

OS=$(detect_os)
ARCH=$(detect_arch)

if [ "$OS" = "unknown" ] || [ "$ARCH" = "unknown" ]; then
    echo "Error: Unsupported platform: ${OS}/${ARCH}"
    exit 1
fi

echo "🚀 merjs installer"
echo "   Platform: ${OS}/${ARCH}"
echo "   Install dir: ${INSTALL_DIR}"
echo ""

# Get latest version
if [ "$VERSION" = "latest" ]; then
    echo "📦 Fetching latest version..."
    VERSION=$(curl -s "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$VERSION" ]; then
        VERSION="v0.2.5"
    fi
fi

echo "   Version: ${VERSION}"

# Map to release asset naming
if [ "$OS" = "macos" ]; then
    if [ "$ARCH" = "arm64" ]; then
        ASSET="mer-macos-aarch64"
    else
        ASSET="mer-macos-x86_64"
    fi
else
    if [ "$ARCH" = "arm64" ]; then
        ASSET="mer-linux-aarch64"
    else
        ASSET="mer-linux-x86_64"
    fi
fi

URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"

TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

echo "⬇️  Downloading ${ASSET}..."
if ! curl -fsSL "$URL" -o "$TMP_DIR/mer"; then
    echo "Error: Failed to download ${URL}"
    echo "The release may not exist yet. Build from source:"
    echo "  git clone https://github.com/${REPO}.git"
    echo "  cd merjs && zig build cli"
    exit 1
fi

echo "🔧 Installing..."

if [ -w "$INSTALL_DIR" ]; then
    SUDO=""
else
    echo "   (may prompt for sudo password)"
    SUDO="sudo"
fi

$SUDO mkdir -p "$INSTALL_DIR"
$SUDO cp "$TMP_DIR/mer" "${INSTALL_DIR}/mer"
$SUDO chmod +x "${INSTALL_DIR}/mer"

if command -v mer &> /dev/null; then
    INSTALLED_VERSION=$(mer --version 2>/dev/null || echo "unknown")
    echo ""
    echo "✅ merjs installed successfully!"
    echo ""
    echo "   Version: ${INSTALLED_VERSION}"
    echo "   Location: $(which mer)"
    echo ""
    echo "Next steps:"
    echo "   mer init myapp    # Create a new project"
    echo "   mer dev           # Start dev server"
else
    echo "⚠️  mer installed but not in PATH"
    echo "   Add this to your shell profile:"
    echo "   export PATH=\"${INSTALL_DIR}:\$PATH\""
fi

echo ""
echo "Documentation: https://github.com/justrach/merjs"
