"""
Setup script for merjs - downloads binary during install
"""

from setuptools import setup, find_packages
from setuptools.command.install import install
import subprocess
import sys


class InstallCommand(install):
    """Custom install command that downloads the mer binary."""
    
    def run(self):
        # Run standard install first
        install.run(self)
        
        # Download the binary
        try:
            from merjs.install import main as install_binary
            install_binary()
        except Exception as e:
            print(f"Warning: Failed to download mer binary: {e}", file=sys.stderr)
            print("You can manually download it from https://github.com/justrach/merjs/releases", file=sys.stderr)


setup(
    cmdclass={
        'install': InstallCommand,
    },
    packages=find_packages(where="src"),
    package_dir={"": "src"},
)
