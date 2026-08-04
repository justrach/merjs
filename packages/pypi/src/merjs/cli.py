#!/usr/bin/env python3
"""CLI wrapper for the mer binary."""

import os
import subprocess
import sys

from . import get_binary_path


def main():
    """Run the mer binary with passed arguments."""
    try:
        bin_path = get_binary_path()
    except RuntimeError:
        from .install import ensure_binary
        try:
            bin_path = ensure_binary()
        except Exception as e:
            print(f"merjs: unable to install the mer binary: {e}", file=sys.stderr)
            sys.exit(1)

    result = subprocess.run(
        [str(bin_path)] + sys.argv[1:],
        env=os.environ,
        cwd=os.getcwd()
    )
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
