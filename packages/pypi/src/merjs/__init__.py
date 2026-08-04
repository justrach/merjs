"""
merlionjs - Next.js-style web framework in Zig

This package provides the `mer` CLI tool. The actual binary is downloaded
on first use.
"""

__version__ = "0.2.5"
__all__ = ["get_binary_path", "binary_exists"]

import os
import platform
from pathlib import Path


def get_platform():
    """Return normalized release platform and architecture names."""
    system = platform.system().lower()
    machine = platform.machine().lower()

    platform_map = {
        "darwin": "macos",
        "linux": "linux",
    }
    arch_map = {
        "x86_64": "x86_64",
        "amd64": "x86_64",
        "x64": "x86_64",
        "arm64": "aarch64",
        "aarch64": "aarch64",
    }

    platform_name = platform_map.get(system)
    arch = arch_map.get(machine)
    if not platform_name or not arch:
        raise RuntimeError(
            f"Unsupported platform: {system} {machine}. "
            "merjs supports macOS/Linux on x64/arm64."
        )
    return platform_name, arch


def get_cache_root() -> Path:
    """Return the user cache root without creating it."""
    configured = os.environ.get("XDG_CACHE_HOME")
    if configured:
        root = Path(configured).expanduser()
        if not root.is_absolute():
            raise RuntimeError("XDG_CACHE_HOME must be an absolute path")
        return root
    try:
        return Path.home() / ".cache"
    except (OSError, RuntimeError) as e:
        raise RuntimeError(
            "Cannot determine a user cache directory. "
            "Set XDG_CACHE_HOME to a writable absolute path."
        ) from e


def get_binary_cache_path(version=None) -> Path:
    """Return the version- and platform-specific binary cache path."""
    if version is None:
        version = os.environ.get("MER_INSTALL_VERSION", __version__)
    if not version or version in (".", "..") or Path(version).name != version:
        raise RuntimeError(f"Invalid MER_INSTALL_VERSION: {version!r}")
    platform_name, arch = get_platform()
    return get_cache_root() / "merjs" / version / f"{platform_name}-{arch}" / "mer"


def get_binary_path() -> Path:
    """Return the path to the cached mer binary."""
    bin_path = get_binary_cache_path()
    if not bin_path.is_file() or not os.access(str(bin_path), os.X_OK):
        raise RuntimeError(
            f"Binary not found in the user cache at {bin_path}. "
            "Run `mer` while connected to the internet to install it."
        )
    return bin_path


def binary_exists() -> bool:
    """Check if the mer binary is installed."""
    try:
        get_binary_path()
        return True
    except RuntimeError:
        return False
