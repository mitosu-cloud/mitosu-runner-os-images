#!/usr/bin/env python3
"""Verify the exact raw/compressed inventory of a runtime-pack source directory."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess

MAX_PACK_BYTES = 32 * 1024**3
CONTROLS = {"manifest.json", "manifest.sig", "complete", "ed25519-public-key.hex", "release-handoff.json"}


def fail(message):
    raise SystemExit(f"error: {message}")


def paths_valid(paths):
    folded = [path.lower() for path in paths]
    if len(set(folded)) != len(folded):
        fail("duplicate or case-colliding artifact path")
    for path in folded:
        parts = PurePosixPath(path).parts
        if not parts or parts[0] in CONTROLS:
            fail("artifact path overlaps a runtime-pack control file")
        if any(other != path and other.startswith(path + "/") for other in folded):
            fail("artifact path is a prefix of another path")


def hash_stream(stream, expected_size):
    digest = hashlib.sha256()
    size = 0
    while chunk := stream.read(128 * 1024):
        size += len(chunk)
        if size > expected_size:
            fail("artifact exceeds declared size")
        digest.update(chunk)
    if size != expected_size:
        fail("artifact size mismatch")
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pack", type=Path)
    parser.add_argument("--signed", action="store_true")
    args = parser.parse_args()
    manifest = json.loads((args.pack / "manifest.json").read_text())
    artifacts = manifest["artifacts"]
    paths_valid([item["path"] for item in artifacts])
    paths_valid([item.get("transport", item)["path"] for item in artifacts])
    if len({item["name"] for item in artifacts}) != len(artifacts):
        fail("duplicate artifact name")
    total = sum(item["size"] for item in artifacts)
    transport_total = sum(item.get("transport", item)["size"] for item in artifacts)
    if max(total, transport_total) > MAX_PACK_BYTES:
        fail("runtime pack exceeds 32 GiB")
    images = {item["name"] for item in manifest["oci_images"]}
    if manifest["schema_version"] == 3 and (
        ("openshell_supervisor_image" in images) != ("openshell_sandbox_runtime_image" in images)
    ):
        fail("OpenShell runtime images must be supplied together")

    expected = {"manifest.json"}
    if args.signed:
        expected.add("manifest.sig")
        expected.update(name for name in ["ed25519-public-key.hex", "release-handoff.json"] if (args.pack / name).exists())
    for item in artifacts:
        download = item.get("transport", item)
        relative = download["path"]
        expected.add(relative)
        source = args.pack
        for component in PurePosixPath(relative).parts:
            source /= component
            if source.is_symlink():
                fail(f"artifact path traverses a symlink: {relative}")
        if not source.is_file():
            fail(f"artifact is missing or not a regular file: {relative}")
        if source.stat().st_size != download["size"]:
            fail(f"artifact size mismatch: {relative}")
        executable = item["executable"] if "transport" not in item else False
        if bool(source.stat().st_mode & 0o111) != executable:
            fail(f"artifact executable mode mismatch: {relative}")
        with source.open("rb") as stream:
            if hash_stream(stream, download["size"]) != download["sha256"]:
                fail(f"artifact SHA-256 mismatch: {relative}")
        if "transport" in item:
            listing = subprocess.run(["zstd", "--list", "--quiet", str(source)], capture_output=True, text=True, check=True)
            rows = listing.stdout.splitlines()
            if len(rows) != 2 or rows[1].split()[:2] != ["1", "0"]:
                fail("compressed artifact must contain exactly one zstd frame without skippable frames")
            with subprocess.Popen(["zstd", "--decompress", "--stdout", "--quiet", "--memory=64MB", str(source)], stdout=subprocess.PIPE) as process:
                try:
                    actual_hash = hash_stream(process.stdout, item["size"])
                    if process.wait() != 0:
                        fail("compressed artifact decoding failed")
                    if actual_hash != item["sha256"]:
                        fail("compressed artifact expanded SHA-256 mismatch")
                finally:
                    if process.poll() is None:
                        process.kill()

    for directory, directories, files in os.walk(args.pack, followlinks=False):
        for name in directories + files:
            path = Path(directory) / name
            mode = path.lstat().st_mode
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                fail("runtime pack contains a symlink or special file")
            if stat.S_ISREG(mode) and path.relative_to(args.pack).as_posix() not in expected:
                fail(f"runtime pack contains an undeclared file: {path.name}")
    print(json.dumps({"status": "validated", "pack_id": manifest["pack_id"], "artifact_count": len(artifacts), "total_size": total, "transport_size": transport_total}, sort_keys=True))


if __name__ == "__main__":
    main()
