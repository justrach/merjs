#!/usr/bin/env python3
"""
CLI wrapper for the mer binary
"""

import sys
import subprocess
import os
from . import get_binary_path


def main():
    """Run the mer binary with passed arguments."""
    try:
        bin_path = get_binary_path()
    except RuntimeError as e:
        print(f"merjs error: {e}", file=sys.stderr)
        sys.exit(1)
    
    # Pass through all arguments and environment
    result = subprocess.run(
        [str(bin_path)] + sys.argv[1:],
        env=os.environ,
        cwd=os.getcwd()
    )
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
