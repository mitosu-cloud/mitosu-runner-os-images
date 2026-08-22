# Release policy

Pull-request workflows have read-only repository permissions and never receive
registry credentials. They validate contracts, lint shell, build changed matrix
entries without publishing, run native smoke tests for the host architecture,
and label any cross-architecture result as emulated.

Publication remains restricted to protected tags or explicit approval in the
upstream repository. It must rebuild a clean, signed source revision on native
`amd64` and `arm64` builders, publish by digest, attach SBOM and provenance
attestations, generate `image-set.json`, and verify each published architecture
by pulling its manifest digest and rerunning smoke tests.

Tags are discovery aliases only. Runtime packs and handoff reports use immutable
OCI digests. A fork can publish images and keyless provenance under its own
identity but cannot issue an official Mitosu runtime-pack signature.

Do not claim byte-for-byte reproducibility or architecture support until CI has
produced the corresponding rebuild comparison or native smoke evidence.

## Runtime-pack release contract

The runtime-pack scripts implement the byte-level contract consumed by
`mitosuagent`:

- `manifest.json` is validated against
  `schemas/runtime-pack.schema.json` before signing;
- `manifest.sig` is the lowercase-hex Ed25519 signature over the exact
  `manifest.json` bytes, without prehashing or JSON reformatting;
- every bundled artifact has a measured size, SHA-256, portable path, and
  executable bit;
- every OCI input uses `repository@sha256:<digest>`; and
- verification rehashes every artifact and rejects symlinks, path collisions,
  prefix overlap, signature changes, or handoff mismatches.

`scripts/sign-runtime-pack.sh` emits `release-handoff.json` with:

```json
{
  "schema_version": 1,
  "pack_id": "apple-container-0.41.0-arm64",
  "source": {
    "type": "https",
    "base_url": "https://downloads.example/mitosu/runtime/apple-container-0.41.0-arm64/"
  },
  "manifest_sha256": "<64 lowercase hex characters>",
  "public_key_hex": "<64 lowercase hex characters>"
}
```

An HTTPS source must be a direct directory endpoint that returns pack files
without redirects. GitHub release asset URLs redirect and therefore are not a
valid runtime-pack base URL for the current fail-closed consumer. A release
archive may instead be downloaded separately, verified, and extracted to the
absolute directory recorded in the handoff.

## Signing-key boundary

The production Ed25519 private key is not generated, stored, or committed by
this repository. Release automation must receive it only from a protected
release environment or external signing service, write it to a private
temporary file, sign after all manifest bytes are final, and destroy that
temporary file. Only `ed25519-public-key.hex`, `manifest.sig`, and the handoff
are public.

Establishing or rotating the official Mitosu release key requires an explicit
application release decision because the matching public key and manifest
digest are pinned in trusted application/tool configuration. A development key
must never be promoted merely because its test pack verifies.

## Publication gates

The signed release job must stop unless all of the following are available:

1. supported tool images published as multi-platform OCI indexes;
2. native smoke evidence for every declared architecture;
3. the final validated `image-set.json` and its immutable image digests;
4. checksum-pinned kernel, runner, and initfs inputs for each runtime pack;
5. a protected Ed25519 signing key and approved public-key rotation plan; and
6. a direct HTTPS directory host or an installer-owned absolute directory.

The current feature branch deliberately does not claim these gates are met:
the development-profile locks remain pending, the native arm64 OS-image run is
not yet available, and no protected release key or environment is configured.
