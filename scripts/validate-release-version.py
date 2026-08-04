#!/usr/bin/env python3
"""Validate release input and published version copies against build.zig.zon."""

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION_PATTERN = r"[0-9]+\.[0-9]+\.[0-9]+"


def match_version(path: str, pattern: str) -> str:
    text = (ROOT / path).read_text(encoding="utf-8")
    matches = re.findall(pattern, text, re.MULTILINE)
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one version in {path}, found {len(matches)}")
    return matches[0]


def source_version() -> str:
    return match_version("build.zig.zon", rf'^\s*\.version = "({VERSION_PATTERN})",$')


def validate_sources(version: str) -> None:
    versions = {
        "packages/npm/package.json": json.loads(
            (ROOT / "packages/npm/package.json").read_text(encoding="utf-8")
        )["version"],
        "packages/pypi/pyproject.toml": match_version(
            "packages/pypi/pyproject.toml", rf'^version = "({VERSION_PATTERN})"$'
        ),
        "packages/pypi/src/merjs/__init__.py": match_version(
            "packages/pypi/src/merjs/__init__.py",
            rf'^__version__ = "({VERSION_PATTERN})"$',
        ),
    }
    mismatches = [f"{path}: {actual}" for path, actual in versions.items() if actual != version]
    if mismatches:
        raise SystemExit(
            f"version sources must match build.zig.zon ({version}): " + ", ".join(mismatches)
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    release_input = parser.add_mutually_exclusive_group(required=True)
    release_input.add_argument("--tag", help="release tag, exactly v<source-version>")
    release_input.add_argument("--version", help="manual dispatch version, exactly <source-version>")
    args = parser.parse_args()

    version = source_version()
    validate_sources(version)
    expected = f"v{version}" if args.tag is not None else version
    actual = args.tag if args.tag is not None else args.version
    if actual != expected:
        raise SystemExit(f"release version mismatch: expected {expected}, got {actual}")
    print(f"release version {version} validated")


if __name__ == "__main__":
    main()
