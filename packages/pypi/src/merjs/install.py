#!/usr/bin/env python3
"""Download and verify the mer binary into the user's cache."""

import fcntl
import hashlib
import os
import sys
import tempfile
import urllib.error
import urllib.request
from contextlib import contextmanager
from pathlib import Path

from . import __version__, get_binary_cache_path, get_cache_root, get_platform

REPO = os.environ.get("MER_INSTALL_REPO", "justrach/merjs")
VERSION = os.environ.get("MER_INSTALL_VERSION", __version__)


def download(url: str, dest: Path):
    """Download file from URL to destination."""
    print(f"merjs: downloading from {url}...")
    try:
        urllib.request.urlretrieve(url, str(dest))
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Download failed: HTTP {e.code}") from e
    except (urllib.error.URLError, OSError) as e:
        raise RuntimeError(f"Download failed: {e}") from e


def checksum_for_asset(checksums: str, asset_name: str) -> str:
    """Return a validated checksum for an exact release asset name."""
    for line in checksums.splitlines():
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) != 2:
            raise RuntimeError(f"Invalid checksum entry: {line}")
        expected_hash, name = fields
        if name == asset_name:
            if len(expected_hash) != 64 or any(c not in "0123456789abcdefABCDEF" for c in expected_hash):
                raise RuntimeError(f"Invalid checksum for {asset_name}")
            return expected_hash.lower()
    raise RuntimeError(f"Checksum not found for {asset_name}")


def verify_checksum(bin_path: Path, checksums_url: str, asset_name: str):
    """Verify SHA256 checksum of downloaded binary."""
    try:
        with urllib.request.urlopen(checksums_url) as response:
            checksums = response.read().decode("utf-8")
    except (urllib.error.HTTPError, urllib.error.URLError, OSError, UnicodeDecodeError) as e:
        raise RuntimeError(f"Checksum download failed: {e}") from e

    expected_hash = checksum_for_asset(checksums, asset_name)
    actual_hash = hashlib.sha256(bin_path.read_bytes()).hexdigest()
    if expected_hash != actual_hash:
        raise RuntimeError(
            f"Checksum mismatch: expected {expected_hash}, got {actual_hash}"
        )
    print("merjs: checksum verified")


def _private_directory(path: Path, create_parents=False, secure_existing=True):
    """Create an installer-owned directory with owner-only permissions."""
    try:
        existed = path.exists()
        path.mkdir(mode=0o700, parents=create_parents, exist_ok=True)
        if not existed or secure_existing:
            path.chmod(0o700)
    except OSError as e:
        raise RuntimeError(
            f"Cannot create or secure merjs cache directory {path}: {e}. "
            "Set XDG_CACHE_HOME to a writable directory."
        ) from e


def _prepare_cache(bin_dir: Path):
    cache_root = get_cache_root()
    _private_directory(cache_root, create_parents=True, secure_existing=False)
    current = cache_root
    for part in bin_dir.relative_to(cache_root).parts:
        current = current / part
        _private_directory(current)


@contextmanager
def _install_lock(lock_path: Path):
    """Serialize first-use installs across processes."""
    try:
        fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
        os.chmod(str(lock_path), 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
    except OSError as e:
        if "fd" in locals():
            os.close(fd)
        raise RuntimeError(
            f"Cannot lock merjs cache at {lock_path}: {e}. "
            "Set XDG_CACHE_HOME to a writable directory."
        ) from e
    try:
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def install_binary(bin_path: Path, download_url: str,
                   checksums_url: str, asset_name: str):
    """Download, verify, and atomically install a release binary."""
    fd, temp_name = tempfile.mkstemp(prefix=".mer-download-", dir=str(bin_path.parent))
    os.close(fd)
    temp_path = Path(temp_name)
    try:
        download(download_url, temp_path)
        verify_checksum(temp_path, checksums_url, asset_name)
        temp_path.chmod(0o755)
        os.replace(str(temp_path), str(bin_path))
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def ensure_binary(repo=None, version=None) -> Path:
    """Return the cached binary, downloading it once when necessary."""
    repo = repo or os.environ.get("MER_INSTALL_REPO", REPO)
    version = version or os.environ.get("MER_INSTALL_VERSION", VERSION)
    platform_name, arch = get_platform()
    asset_name = f"mer-{platform_name}-{arch}"
    bin_path = get_binary_cache_path(version)
    _prepare_cache(bin_path.parent)

    lock_path = bin_path.parent / ".install.lock"
    with _install_lock(lock_path):
        if bin_path.is_file() and os.access(str(bin_path), os.X_OK):
            return bin_path

        tag = version if version.startswith("v") else f"v{version}"
        base_url = f"https://github.com/{repo}/releases/download/{tag}"
        install_binary(
            bin_path,
            f"{base_url}/{asset_name}",
            f"{base_url}/checksums.txt",
            asset_name,
        )

    print(f"merjs: installed to {bin_path}")
    return bin_path


def main():
    """Download and install the mer binary."""
    try:
        bin_path = ensure_binary()
    except Exception as e:
        print(f"merjs: install failed: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"merjs: binary ready at {bin_path}")
    print("merjs: run `mer init my-app` to get started")


if __name__ == "__main__":
    main()
