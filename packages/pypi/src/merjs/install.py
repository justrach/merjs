#!/usr/bin/env python3
"""
Post-install script to download the mer binary
"""

import os
import platform
import urllib.request
import urllib.error
import hashlib
import sys
from pathlib import Path

REPO = os.environ.get("MER_INSTALL_REPO", "justrach/merjs")
VERSION = os.environ.get("MER_INSTALL_VERSION", "0.2.2")


def get_platform():
    """Get normalized platform and architecture."""
    system = platform.system().lower()
    machine = platform.machine().lower()
    
    platform_map = {
        "darwin": "macos",
        "linux": "linux",
        "windows": "windows"
    }
    
    arch_map = {
        "x86_64": "x86_64",
        "amd64": "x86_64",
        "x64": "x86_64",
        "arm64": "aarch64",
        "aarch64": "aarch64"
    }
    
    p = platform_map.get(system)
    a = arch_map.get(machine)
    
    if not p or not a:
        raise RuntimeError(
            f"Unsupported platform: {system} {machine}. "
            "merjs supports macOS/Linux/Windows on x64/arm64."
        )
    
    return p, a


def download(url: str, dest: Path):
    """Download file from URL to destination."""
    print(f"merjs: downloading from {url}...")
    try:
        urllib.request.urlretrieve(url, dest)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Download failed: HTTP {e.code}")
    except Exception as e:
        raise RuntimeError(f"Download failed: {e}")


def verify_checksum(bin_path: Path, checksums_url: str, asset_name: str):
    """Verify SHA256 checksum of downloaded binary."""
    try:
        with urllib.request.urlopen(checksums_url) as response:
            checksums = response.read().decode('utf-8')
        
        expected_hash = None
        for line in checksums.split('\n'):
            if asset_name in line:
                expected_hash = line.split()[0]
                break
        
        if not expected_hash:
            print("merjs: checksum not found, skipping verification")
            return
        
        actual_hash = hashlib.sha256(bin_path.read_bytes()).hexdigest()
        
        if expected_hash != actual_hash:
            raise RuntimeError(
                f"Checksum mismatch: expected {expected_hash}, got {actual_hash}"
            )
        print("merjs: checksum verified")
    except Exception as e:
        print(f"merjs: checksum verification skipped: {e}")


def main():
    """Download and install the mer binary."""
    platform_name, arch = get_platform()
    asset_name = f"mer-{platform_name}-{arch}"
    bin_name = "mer.exe" if platform_name == "windows" else "mer"
    
    # Get package directory
    package_dir = Path(__file__).parent
    bin_dir = package_dir / "bin"
    bin_path = bin_dir / bin_name
    
    # Create bin directory
    bin_dir.mkdir(parents=True, exist_ok=True)
    
    # Check if already exists
    if bin_path.exists():
        print("merjs: binary already exists, skipping download")
        return
    
    # Build download URLs
    base_url = f"https://github.com/{REPO}/releases"
    if VERSION == "latest" or not VERSION[0].isdigit():
        download_url = f"{base_url}/latest/download/{asset_name}"
        checksums_url = f"{base_url}/latest/download/checksums.txt"
    else:
        download_url = f"{base_url}/download/v{VERSION}/{asset_name}"
        checksums_url = f"{base_url}/download/v{VERSION}/checksums.txt"
    
    try:
        download(download_url, bin_path)
        verify_checksum(bin_path, checksums_url, asset_name)
        
        # Make executable on Unix
        if platform_name != "windows":
            bin_path.chmod(0o755)
        
        print(f"merjs: installed to {bin_path}")
        print("merjs: run `mer init my-app` to get started")
    except Exception as e:
        print(f"merjs: install failed: {e}", file=sys.stderr)
        # Clean up partial download
        if bin_path.exists():
            bin_path.unlink()
        sys.exit(1)


if __name__ == "__main__":
    main()
