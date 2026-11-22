#!/usr/bin/env python3
"""Apply the reviewed SideSign fix without moving the pinned submodule revision."""

from pathlib import Path
import argparse
import subprocess


ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "scripts/patches/sidesign-memory-entitlements.patch"


def apply_patch(dependency: Path, patch: Path = PATCH) -> str:
    dependency = dependency.resolve()
    patch = patch.resolve()
    source = dependency / "Sources/CodeSigning/CodeSignerAPI.swift"
    if not source.is_file():
        raise RuntimeError("Initialize Dependencies/SideSign before applying signing fixes.")

    command = ["git", "-C", str(dependency), "apply", "--whitespace=nowarn"]
    check = subprocess.run(command + ["--check", str(patch)], capture_output=True, text=True)
    if check.returncode == 0:
        subprocess.run(command + [str(patch)], check=True)
        return "applied"

    reverse = subprocess.run(
        command + ["--reverse", "--check", str(patch)], capture_output=True, text=True
    )
    if reverse.returncode == 0:
        return "already applied"
    raise RuntimeError(
        "The pinned SideSign sources no longer match the signing fix; review the dependency "
        "before building.\n" + check.stderr.strip()
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dependency", type=Path, default=ROOT / "Dependencies/SideSign")
    args = parser.parse_args()
    print("SideSign memory-entitlement fix:", apply_patch(args.dependency))


if __name__ == "__main__":
    main()
