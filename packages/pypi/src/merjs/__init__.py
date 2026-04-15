"""
merlionjs - Next.js-style web framework in Zig

This package provides the `mer` CLI tool. The actual binary is downloaded
during installation.
"""

__version__ = "0.2.2"
__all__ = ["get_binary_path", "binary_exists"]

import os
import platform
from pathlib import Path


def get_binary_path() -> Path:
    """Return the path to the mer binary."""
    system = platform.system().lower()
    machine = platform.machine().lower()

    # Normalize platform names
    if system == "darwin":
        platform_name = "macos"
    elif system == "linux":
        platform_name = "linux"
    elif system == "windows":
        platform_name = "windows"
    else:
        raise RuntimeError(f"Unsupported platform: {system}")

    # Normalize architecture names
    if machine in ("x86_64", "amd64", "x64"):
        arch = "x86_64"
    elif machine in ("arm64", "aarch64"):
        arch = "aarch64"
    else:
        raise RuntimeError(f"Unsupported architecture: {machine}")

    bin_name = "mer.exe" if platform_name == "windows" else "mer"

    # Look for binary in package directory
    package_dir = Path(__file__).parent
    bin_path = package_dir / "bin" / bin_name

    if not bin_path.exists():
        raise RuntimeError(
            f"Binary not found at {bin_path}. "
            "Try reinstalling: pip install --force-reinstall merlionjs"
        )

    return bin_path


def binary_exists() -> bool:
    """Check if the mer binary is installed."""
    try:
        return get_binary_path().exists()
    except RuntimeError:
        return False
