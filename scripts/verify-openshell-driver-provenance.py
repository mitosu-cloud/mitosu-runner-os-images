#!/usr/bin/env python3
"""Verify that an OpenShell VM driver's declared runtime bytes are embedded."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile


ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
HEX_SHA256 = re.compile(r"[0-9a-f]{64}")
SOURCE_COMMIT = re.compile(r"[0-9a-f]{40}")
EMBEDDED_NAMES = {
    "libkrun.so.zst",
    "libkrunfw.so.5.zst",
    "openshell-sandbox.zst",
    "openshell-supervisor.zst",
    "openshell-vm-init.zst",
    "umoci.zst",
}
MAX_DRIVER_BYTES = 512 * 1024**2
MAX_PROVENANCE_BYTES = 1024**2
MAX_EMBEDDED_BYTES = 256 * 1024**2


def fail(message):
    raise SystemExit(f"error: {message}")


def require(condition, message):
    if not condition:
        fail(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"provenance contains duplicate key: {key}")
        result[key] = value
    return result


def artifact(manifest, name):
    matches = [item for item in manifest["artifacts"] if item["name"] == name]
    require(len(matches) == 1, f"production pack must contain one {name} artifact")
    return matches[0]


def safe_pack_path(pack, relative):
    path = PurePosixPath(relative)
    require(not path.is_absolute() and ".." not in path.parts, "unsafe artifact path")
    candidate = pack
    for part in path.parts:
        candidate /= part
        require(not candidate.is_symlink(), "artifact path traverses a symlink")
    require(candidate.is_file(), f"artifact is missing: {relative}")
    return candidate


def decode_zstd(source, expected_size, label):
    process = subprocess.Popen(
        ["zstd", "--decompress", "--stdout", "--quiet", "--memory=64MB", source],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        data = process.stdout.read(expected_size + 1)
        if len(data) > expected_size:
            process.kill()
            process.wait()
            fail(f"{label} exceeds its declared expanded size")
        stderr = process.stderr.read()
        require(process.wait() == 0, f"{label} failed to decode: {stderr.decode(errors='replace')}")
        require(len(data) == expected_size, f"{label} expanded size mismatch")
        return data
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


def expand_artifact(pack, item, maximum_size):
    require(0 < item["size"] <= maximum_size, f"artifact is too large: {item['name']}")
    transport = item.get("transport")
    if transport is None:
        data = safe_pack_path(pack, item["path"]).read_bytes()
    else:
        require(transport["compression"] == "zstd", "unsupported artifact compression")
        source = safe_pack_path(pack, transport["path"])
        data = decode_zstd(source, item["size"], f"compressed artifact {item['name']}")
    require(len(data) == item["size"], f"expanded size mismatch: {item['name']}")
    require(
        hashlib.sha256(data).hexdigest() == item["sha256"],
        f"expanded SHA-256 mismatch: {item['name']}",
    )
    return data


def version_matches_source(version, binary_name, source_commit, expanded):
    prefix = f"{binary_name} "
    require(version.startswith(prefix), f"invalid {binary_name} version")
    component = version[len(prefix) :]
    match = re.search(r"\+g([0-9a-f]{7,40})$", component)
    require(match is not None, f"{binary_name} version lacks a source revision")
    require(source_commit.startswith(match.group(1)), f"{binary_name} source revision mismatch")
    require(component.encode() in expanded, f"{binary_name} version is absent from embedded bytes")


def embedded_blob(driver, entry):
    compressed_size = entry.get("compressed_bytes")
    compressed_sha256 = entry.get("compressed_sha256")
    require(
        isinstance(compressed_size, int) and 0 < compressed_size <= MAX_EMBEDDED_BYTES,
        "invalid compressed byte count",
    )
    require(
        isinstance(compressed_sha256, str) and HEX_SHA256.fullmatch(compressed_sha256),
        "invalid compressed SHA-256",
    )
    matches = []
    offset = 0
    while True:
        offset = driver.find(ZSTD_MAGIC, offset)
        if offset < 0:
            break
        candidate = driver[offset : offset + compressed_size]
        if len(candidate) == compressed_size and hashlib.sha256(candidate).hexdigest() == compressed_sha256:
            matches.append(candidate)
        offset += 1
    require(len(matches) == 1, f"embedded bytes not found exactly once: {entry.get('name')}")
    expanded_size = entry.get("expanded_bytes")
    require(
        isinstance(expanded_size, int) and 0 < expanded_size <= MAX_EMBEDDED_BYTES,
        f"invalid embedded expanded size: {entry.get('name')}",
    )
    with tempfile.NamedTemporaryFile() as source:
        source.write(matches[0])
        source.flush()
        expanded = decode_zstd(source.name, expanded_size, f"embedded artifact {entry.get('name')}")
    require(
        isinstance(entry.get("expanded_sha256"), str)
        and HEX_SHA256.fullmatch(entry["expanded_sha256"])
        and hashlib.sha256(expanded).hexdigest() == entry["expanded_sha256"],
        f"embedded expanded SHA-256 mismatch: {entry.get('name')}",
    )
    return expanded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pack", type=Path)
    args = parser.parse_args()
    manifest = json.loads((args.pack / "manifest.json").read_text())
    driver_item = artifact(manifest, "openshell_driver_vm")
    provenance_item = artifact(manifest, "openshell_driver_vm_provenance")
    require(driver_item["executable"] is True, "OpenShell VM driver must be executable")
    require(provenance_item["executable"] is False, "driver provenance must not be executable")
    driver = expand_artifact(args.pack, driver_item, MAX_DRIVER_BYTES)
    provenance_bytes = expand_artifact(args.pack, provenance_item, MAX_PROVENANCE_BYTES)
    try:
        provenance = json.loads(provenance_bytes, object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"driver provenance is not valid JSON: {error}")

    require(provenance.get("schema_version") == 2, "driver provenance schema version must be 2")
    require(provenance.get("artifact") == "openshell_driver_vm", "driver provenance artifact mismatch")
    require(provenance.get("clean_build_checkout") is True, "driver build checkout was not clean")
    require(
        provenance.get("source_repository") == "https://github.com/mitosu-cloud/openshell",
        "driver source repository mismatch",
    )
    source_commit = provenance.get("source_commit")
    require(isinstance(source_commit, str) and SOURCE_COMMIT.fullmatch(source_commit), "invalid source commit")
    require(provenance.get("driver_bytes") == len(driver), "provenance driver size mismatch")
    require(
        provenance.get("driver_sha256") == hashlib.sha256(driver).hexdigest(),
        "provenance driver SHA-256 mismatch",
    )
    driver_version = provenance.get("driver_version")
    require(isinstance(driver_version, str), "driver version is missing")
    version_matches_source(driver_version, "openshell-driver-vm", source_commit, driver)

    runtime = provenance.get("embedded_runtime")
    require(isinstance(runtime, dict), "embedded runtime provenance is missing")
    require(runtime.get("source_commit") == source_commit, "embedded runtime source commit mismatch")
    require(runtime.get("source_sensitive_reused") is False, "source-sensitive runtime was reused")
    build_command = runtime.get("build_command")
    require(
        isinstance(build_command, str) and "build-supervisor-bundle.sh" in build_command,
        "embedded runtime build command is missing",
    )
    entries = runtime.get("artifacts")
    require(isinstance(entries, list), "embedded runtime artifact inventory is missing")
    by_name = {entry.get("name"): entry for entry in entries if isinstance(entry, dict)}
    require(len(by_name) == len(entries), "embedded runtime artifact names are missing or duplicated")
    require(set(by_name) == EMBEDDED_NAMES, "embedded runtime artifact inventory is incomplete")

    expanded = {name: embedded_blob(driver, entry) for name, entry in by_name.items()}
    for name, binary_name in [
        ("openshell-supervisor.zst", "openshell-supervisor"),
        ("openshell-sandbox.zst", "openshell-sandbox"),
    ]:
        version = by_name[name].get("version")
        require(isinstance(version, str), f"{binary_name} version is missing")
        version_matches_source(version, binary_name, source_commit, expanded[name])
    supervisor = by_name["openshell-supervisor.zst"]
    require(supervisor.get("parent_liveness_stdin") is True, "supervisor liveness contract is missing")
    require(
        b"parent-liveness-stdin" in expanded["openshell-supervisor.zst"],
        "embedded supervisor lacks the parent-liveness-stdin option",
    )
    print(
        json.dumps(
            {
                "driver_sha256": provenance["driver_sha256"],
                "source_commit": source_commit,
                "status": "embedded-runtime-provenance-verified",
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
