#!/usr/bin/env python3
"""Portable project identity gate for ZLMod."""

from __future__ import annotations

import argparse
from pathlib import Path


FORBIDDEN = ("Zync", "ZYNC", "zync")
SCANNED_FILES = {"Makefile", "README.md"}
SCANNED_DIRS = ("Sources", "Scripts", "Packaging", ".github")


def _candidate_files(root: Path):
    for name in SCANNED_FILES:
        path = root / name
        if path.is_file():
            yield path
    for dirname in SCANNED_DIRS:
        directory = root / dirname
        if not directory.exists():
            continue
        for path in directory.rglob("*"):
            if path.is_file() and path.name != Path(__file__).name:
                yield path


def audit_identity(root: Path) -> list[str]:
    root = Path(root)
    violations: list[str] = []
    for path in _candidate_files(root):
        relative = path.relative_to(root).as_posix()
        if any(token in relative for token in FORBIDDEN):
            violations.append(f"forbidden upstream identity in path: {relative}")
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for token in FORBIDDEN:
            if token in content:
                violations.append(f"forbidden upstream identity {token!r} in {relative}")
    return violations


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    violations = audit_identity(args.root)
    for violation in violations:
        print(violation)
    return 1 if violations else 0


if __name__ == "__main__":
    raise SystemExit(main())
