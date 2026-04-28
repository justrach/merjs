#!/bin/sh
# install.sh — One-liner installer for the `mer` CLI from merjs releases.
# Usage:
#   curl -fsSL https://merjs.trilok.ai/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/justrach/merjs/main/install.sh | sh
#
# Env overrides:
#   MER_INSTALL_VERSION=v0.2.5   pin a specific release (default: latest)
#   MER_INSTALL_DIR=/opt/bin      pick install location
#   MER_INSTALL_REPO=fork/merjs   install from a fork

set -eu

REPO="${MER_INSTALL_REPO:-justrach/merjs}"
VERSION="${MER_INSTALL_VERSION:-latest}"

# ── helpers ────────────────────────────────────────────────────────────────
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m::\033[0m %s\n' "$*" >&2; }
ok() { printf '\033[0;32m::\033[0m %s\n' "$*" >&2; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO "$2" "$1"; }
else
    die "need curl or wget to download releases"
fi

need uname
need mktemp
need chmod
need mkdir
need mv

# ── platform detection ──────────────────────────────────────────────────────
case "$(uname -s)" in
    Darwin) os="macos" ;;
    Linux)  os="linux" ;;
    *) die "unsupported OS: $(uname -s) (supported: macOS, Linux)" ;;
esac

case "$(uname -m)" in
    arm64|aarch64) arch="aarch64" ;;
    x86_64|amd64)  arch="x86_64" ;;
    *) die "unsupported architecture: $(uname -m) (supported: x86_64, aarch64)" ;;
esac

# ── asset resolution ───────────────────────────────────────────────────────
asset="mer-${os}-${arch}"
base="https://github.com/${REPO}/releases"
if [ "$VERSION" = "latest" ]; then
    bin_url="${base}/latest/download/${asset}"
    sums_url="${base}/latest/download/checksums.txt"
else
    bin_url="${base}/download/${VERSION}/${asset}"
    sums_url="${base}/download/${VERSION}/checksums.txt"
fi

# ── install location ───────────────────────────────────────────────────────
if [ -n "${MER_INSTALL_DIR:-}" ]; then
    install_dir="$MER_INSTALL_DIR"
elif [ -w /usr/local/bin ]; then
    install_dir="/usr/local/bin"
else
    install_dir="${HOME}/.local/bin"
fi

info "merjs installer"
info "  platform     ${os}/${arch}"
info "  version      ${VERSION}"
info "  install dir  ${install_dir}"

# ── download + verify ──────────────────────────────────────────────────────
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

bin_path="${tmpdir}/mer"
sums_path="${tmpdir}/checksums.txt"

info "downloading ${asset}"
fetch "$bin_url" "$bin_path" || die "failed to download ${bin_url}"
fetch "$sums_url" "$sums_path" || die "failed to download checksums"

verify() {
    expected=$(grep " ${asset}\$" "$sums_path" | awk '{print $1}')
    [ -n "$expected" ] || { info "no checksum entry for ${asset}; skipping verification"; return 0; }
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$bin_path" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$bin_path" | awk '{print $1}')
    else
        info "no sha256 tool found; skipping verification"
        return 0
    fi
    [ "$expected" = "$actual" ] || die "checksum mismatch for ${asset}: expected ${expected}, got ${actual}"
    ok "checksum verified"
}
verify

# ── install ────────────────────────────────────────────────────────────────
chmod +x "$bin_path"
if [ -w "$install_dir" ] || [ ! -e "$install_dir" ]; then
    SUDO=""
else
    info "  (may prompt for sudo password)"
    SUDO="sudo"
fi
$SUDO mkdir -p "$install_dir"
$SUDO mv "$bin_path" "${install_dir}/mer"

ok "installed mer to ${install_dir}/mer"

# ── PATH check ─────────────────────────────────────────────────────────────
case ":${PATH}:" in
    *":${install_dir}:"*) ;;
    *)
        info ""
        info "${install_dir} is not in your PATH. Add it to your shell profile:"
        info "    export PATH=\"${install_dir}:\$PATH\""
        info ""
        ;;
esac

# ── next steps ─────────────────────────────────────────────────────────────
cat >&2 <<EOF
Next steps:
  mer init myapp     # create a new project
  cd myapp
  mer dev            # start the dev server on :3000

Docs:    https://docs.merjs.dev
GitHub:  https://github.com/${REPO}
EOF
