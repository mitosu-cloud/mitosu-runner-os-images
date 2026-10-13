#!/usr/bin/env python3
"""Extract an untrusted runtime-pack tar archive into a private directory."""

from __future__ import annotations

import argparse
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile

MAX_FILES = 128
MAX_BYTES = 32 * 1024 * 1024 * 1024 + 1024 * 1024


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    if not args.archive.is_file() or args.archive.is_symlink():
        fail("archive must be a regular non-symlink file")
    if args.output.exists():
        fail("output directory already exists")

    with tarfile.open(args.archive, mode="r:*") as archive:
        members = archive.getmembers()
        if not members or len(members) > MAX_FILES:
            fail(f"archive must contain 1..={MAX_FILES} members")
        seen: set[str] = set()
        total_size = 0
        for member in members:
            path = PurePosixPath(member.name)
            if (
                member.name in seen
                or path.is_absolute()
                or not path.parts
                or path.parts[0] != "pack"
                or any(part in ("", ".", "..") for part in path.parts)
                or any("\\" in part or any(ord(char) < 32 for char in part) for part in path.parts)
            ):
                fail(f"unsafe or duplicate archive path: {member.name!r}")
            seen.add(member.name)
            if not (member.isdir() or member.isfile()):
                fail(f"archive member is not a regular file or directory: {member.name}")
            if member.isfile():
                total_size += member.size
                if total_size > MAX_BYTES:
                    fail("archive expands beyond the runtime-pack size limit")

        if "pack/manifest.json" not in seen:
            fail("archive does not contain pack/manifest.json")

        args.output.mkdir(mode=0o700, parents=True)
        try:
            for member in members:
                relative = PurePosixPath(member.name)
                destination = args.output.joinpath(*relative.parts)
                if member.isdir():
                    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
                    os.chmod(destination, 0o700)
                    continue
                destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    fail(f"could not read archive member: {member.name}")
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                descriptor = os.open(destination, flags, 0o600)
                with source, os.fdopen(descriptor, "wb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                os.chmod(destination, 0o555 if member.mode & 0o111 else 0o444)
        except BaseException:
            shutil.rmtree(args.output, ignore_errors=True)
            raise


if __name__ == "__main__":
    main()
