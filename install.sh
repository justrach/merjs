#!/bin/bash
# install.sh — One-liner installer for merjs
# Usage: curl -fsSL https://merjs.trilok.ai/install.sh | bash
# Or:    wget -qO- https://merjs.trilok.ai/install.sh | bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Config
REPO="justrach/merjs"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${VERSION:-latest}"

# Detect OS
 detect_os() {
    case "$(uname -s)" in
        Linux*)     echo "linux";;
        Darwin*)    echo "macos";;
        CYGWIN*)    echo "windows";;
        MINGW*)     echo "windows";;
        MSYS*)      echo "windows";;
        *)          echo "unknown";;
    esac
}

# Detect architecture
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "x86_64";;
        arm64|aarch64)  echo "arm64";;
        armv7l)         echo "armv7";;
        i386|i686)      echo "x86";;
        *)              echo "unknown";;
    esac
}

OS=$(detect_os)
ARCH=$(detect_arch)

if [ "$OS" = "unknown" ] || [ "$ARCH" = "unknown" ]; then
    echo -e "${RED}Error: Unsupported platform: ${OS}/${ARCH}${NC}"
    echo "Supported: linux/x86_64, linux/arm64, macos/x86_64, macos/arm64"
    exit 1
fi

echo -e "${BLUE}🚀 merjs installer${NC}"
echo "   Platform: ${OS}/${ARCH}"
echo "   Install dir: ${INSTALL_DIR}"
echo ""

# Check for required tools
 check_deps() {
    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        echo -e "${RED}Error: curl or wget is required${NC}"
        exit 1
    fi
    
    if ! command -v tar &> /dev/null; then
        echo -e "${RED}Error: tar is required${NC}"
        exit 1
    fi
}

download() {
    local url="$1"
    local output="$2"
    
    if command -v curl &> /dev/null; then
        curl -fsSL "$url" -o "$output"
    else
        wget -q "$url" -O "$output"
    fi
}

# Get latest version if not specified
if [ "$VERSION" = "latest" ]; then
    echo -e "${YELLOW}📦 Fetching latest version...${NC}"
    VERSION=$(curl -s "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$VERSION" ]; then
        VERSION="v0.2.5"  # fallback
    fi
fi

echo -e "${BLUE}   Version: ${VERSION}${NC}"

# Build download URL
FILENAME="merjs-${VERSION}-${OS}-${ARCH}.tar.gz"
URL="https://github.com/${REPO}/releases/download/${VERSION}/${FILENAME}"

# Create temp directory
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

echo -e "${YELLOW}⬇️  Downloading...${NC}"
if ! download "$URL" "${TMP_DIR}/${FILENAME}"; then
    echo -e "${RED}Error: Failed to download ${URL}${NC}"
    echo "You may need to build from source:"
    echo "  git clone https://github.com/${REPO}.git"
    echo "  cd merjs && zig build cli"
    exit 1
fi

echo -e "${YELLOW}📂 Extracting...${NC}"
tar -xzf "${TMP_DIR}/${FILENAME}" -C "$TMP_DIR"

# Find binaries
MER_BIN=$(find "$TMP_DIR" -name "mer" -type f | head -1)
MERJS_BIN=$(find "$TMP_DIR" -name "merjs" -type f | head -1)

if [ -z "$MER_BIN" ]; then
    echo -e "${RED}Error: mer binary not found in archive${NC}"
    exit 1
fi

echo -e "${YELLOW}🔧 Installing...${NC}"

# Check if we need sudo
if [ -w "$INSTALL_DIR" ]; then
    SUDO=""
else
    echo -e "${YELLOW}   (may prompt for sudo password)${NC}"
    SUDO="sudo"
fi

# Install binaries
$SUDO mkdir -p "$INSTALL_DIR"
$SUDO cp "$MER_BIN" "${INSTALL_DIR}/mer"
$SUDO chmod +x "${INSTALL_DIR}/mer"

if [ -n "$MERJS_BIN" ]; then
    $SUDO cp "$MERJS_BIN" "${INSTALL_DIR}/merjs"
    $SUDO chmod +x "${INSTALL_DIR}/merjs"
fi

# Verify installation
if command -v mer &> /dev/null; then
    INSTALLED_VERSION=$(mer --version 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✅ merjs installed successfully!${NC}"
    echo ""
    echo "   Version: ${INSTALLED_VERSION}"
    echo "   Location: $(which mer)"
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo "   mer init myapp    # Create a new project"
    echo "   mer dev           # Start dev server"
    echo ""
else
    echo -e "${YELLOW}⚠️  mer installed but not in PATH${NC}"
    echo "   Add this to your shell profile:"
    echo "   export PATH=\"${INSTALL_DIR}:\$PATH\""
fi

# Print quickstart
echo -e "${BLUE}Documentation:${NC} https://merjs.trilok.ai/docs"
echo -e "${BLUE}GitHub:${NC} https://github.com/${REPO}"
