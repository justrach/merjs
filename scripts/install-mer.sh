#!/bin/sh

set -eu

REPO="${MER_INSTALL_REPO:-justrach/merjs}"
VERSION="${MER_INSTALL_VERSION:-latest}"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "install-mer: missing required command: $1" >&2
        exit 1
    fi
}

need_cmd uname
need_cmd mktemp
need_cmd chmod
need_cmd mkdir
need_cmd mv

if command -v curl >/dev/null 2>&1; then
    fetch() {
        curl -fsSL "$1" -o "$2"
    }
elif command -v wget >/dev/null 2>&1; then
    fetch() {
        wget -qO "$2" "$1"
    }
else
    echo "install-mer: need curl or wget to download releases" >&2
    exit 1
fi

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Darwin) os="macos" ;;
    Linux) os="linux" ;;
    *)
        echo "install-mer: unsupported OS: $OS" >&2
        exit 1
        ;;
esac

case "$ARCH" in
    arm64|aarch64) arch="aarch64" ;;
    x86_64|amd64) arch="x86_64" ;;
    *)
        echo "install-mer: unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac

asset="mer-${os}-${arch}"
base_url="https://github.com/${REPO}/releases"
if [ "$VERSION" = "latest" ]; then
    download_url="${base_url}/latest/download/${asset}"
    checksums_url="${base_url}/latest/download/checksums.txt"
else
    download_url="${base_url}/download/${VERSION}/${asset}"
    checksums_url="${base_url}/download/${VERSION}/checksums.txt"
fi

if [ -n "${MER_INSTALL_DIR:-}" ]; then
    install_dir="$MER_INSTALL_DIR"
elif [ -w /usr/local/bin ]; then
    install_dir="/usr/local/bin"
else
    install_dir="${HOME}/.local/bin"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

bin_path="${tmpdir}/mer"
checksums_path="${tmpdir}/checksums.txt"

echo "install-mer: downloading ${asset}" >&2
fetch "$download_url" "$bin_path"
fetch "$checksums_url" "$checksums_path"

if command -v shasum >/dev/null 2>&1; then
    (
        cd "$tmpdir"
        grep " ${asset}\$" "$checksums_path" | sed "s| ${asset}\$| mer|" | shasum -a 256 -c -
    )
elif command -v sha256sum >/dev/null 2>&1; then
    (
        cd "$tmpdir"
        grep " ${asset}\$" "$checksums_path" | sed "s| ${asset}\$| mer|" | sha256sum -c -
    )
else
    echo "install-mer: checksum tool not found, skipping verification" >&2
fi

mkdir -p "$install_dir"
chmod +x "$bin_path"
mv "$bin_path" "${install_dir}/mer"

echo "install-mer: installed to ${install_dir}/mer" >&2
case ":${PATH}:" in
    *":${install_dir}:"*) ;;
    *)
        echo "install-mer: add ${install_dir} to PATH to run 'mer'" >&2
        ;;
esac
