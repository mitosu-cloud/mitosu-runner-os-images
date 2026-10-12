# Release policy

Pull-request workflows have read-only repository permissions and never receive
registry credentials. They validate contracts, lint shell, build changed matrix
entries without publishing, run native smoke tests for the host architecture,
and label any cross-architecture result as emulated.

Publication is restricted to the `runtime-release` environment. Its required
reviewers approve the exact source revision and dispatch inputs before any job
that can publish or use the runtime-pack signing key proceeds. Image jobs
rebuild a clean source revision, publish by digest, and use GitHub OIDC to put
build provenance beside the resulting OCI manifest. Runtime-pack jobs verify
that provenance before signing.

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
- every OCI input uses `repository@sha256:<digest>`;
- ACP workload image attestations match the agent's schema and are covered by
  the runtime-pack signature; and
- verification rehashes every artifact and rejects symlinks, undeclared files,
  path collisions, prefix overlap, signature changes, or handoff mismatches.

`scripts/sign-runtime-pack.sh` emits `release-handoff.json` with:

```json
{
  "schema_version": 1,
  "pack_id": "openshell-2026.10-linux-x86_64",
  "source": {
    "type": "https",
    "base_url": "https://downloads.example/mitosu/runtime/openshell-2026.10-linux-x86_64/"
  },
  "manifest_sha256": "<64 lowercase hex characters>",
  "public_key_hex": "<64 lowercase hex characters>"
}
```

An HTTPS source must be a direct directory endpoint that returns pack files
without redirects. GitHub release asset URLs redirect and therefore are not a
valid runtime-pack base URL for the current fail-closed consumer. A release
archive may instead be downloaded separately, verified, and extracted to an
installer-owned absolute directory.

## Protected release environment

Create a GitHub environment named `runtime-release` in this public repository.
Configure required reviewers and restrict deployment to the protected release
branch. The current single-maintainer environment requires `edhemphill` and
allows self-review; after a second trusted reviewer or team is added, prevent
self-review to obtain a two-person release gate. Enable immutable releases in the repository
settings so published tags and assets cannot be changed or deleted. The
workflow checks that setting before it accepts a candidate. Add this environment
secret:

- environment secret `MITOSU_RUNTIME_PACK_SIGNING_KEY_PEM`, containing one
  persistent Ed25519 private key in PEM form.

The corresponding raw 32-byte public key is checked in as 64 lowercase
hexadecimal characters at `release/runtime-pack-ed25519-public-key.hex`. Changing
the trust pin therefore requires source review and a new exact source revision;
an environment administrator cannot silently replace the private key and pin
together.

Generate the key on a trusted administrative machine and keep an encrypted
offline backup before installing the environment secret:

```sh
umask 077
openssl genpkey -algorithm ED25519 -out mitosu-runtime-pack-signing-key.pem
openssl pkey -in mitosu-runtime-pack-signing-key.pem \
  -pubout -outform DER -out mitosu-runtime-pack-public.der
tail -c 32 mitosu-runtime-pack-public.der | od -An -v -tx1 | tr -d '[:space:]'
```

Install that hexadecimal value at
`release/runtime-pack-ed25519-public-key.hex` in the same reviewed change that
introduces or rotates the environment secret.

The private key is never committed, uploaded as an artifact, passed to the
candidate-validation job, or used by the image publication job. The protected
signing job writes it to a mode-`0600` temporary file, unsets the environment
value, signs after all manifest bytes are final, checks the derived public key
against the source-controlled public-key pin, and removes the file before
packaging. Public outputs contain only `ed25519-public-key.hex`,
`manifest.sig`, `release-handoff.json`, and the signed pack archive.

Establishing or rotating the official key requires an application release
decision because each deployed runtime-pack configuration pins both the public
key and exact manifest digest. For rotation, create and back up a new key,
commit its public key through review and publish it in an application/configuration
release, wait for that release to reach the intended machines, then replace the
environment secret. Never reuse a pack ID or release tag across keys. If a
key may be compromised, delete the environment secret immediately, disable
the release workflows, remove affected pack configuration from managed
machines, and issue a new key and pack ID. Existing signatures have no online
revocation mechanism.

## Protected runtime-pack workflow

The unsigned candidate is a tar archive whose only top-level directory is
`pack/`. It can be produced from an assembled pack with:

```sh
tar -C /path/to/parent -czf candidate.tar.gz pack
sha256sum candidate.tar.gz
```

Dispatch `.github/workflows/runtime-pack-release.yml` with the exact source
SHA, `runtime-pack-<pack_id>` release tag, HTTPS candidate URL, candidate
SHA-256, and the final direct HTTPS directory URL for the unpacked signed
files. Candidate validation runs without the signing secret. It rejects path
traversal, links, special files, undeclared files, size or mode mismatches,
mutable or local OCI references, missing `openshell_driver_vm`, missing
OpenShell control images, and missing attested `ubuntu-26.04-node` or
`ubuntu-26.04-python` images for the selected guest architecture.

The protected job downloads the validated candidate through the Actions
artifact boundary, rechecks the original SHA-256, re-extracts and validates it,
signs it, creates deterministic release files, generates OIDC provenance, and
creates the GitHub release. It refuses an existing release tag. The GitHub
release archive is a transport artifact; deploy the unpacked signed files to
the approved `source_base_url`, or install the archive into a trusted absolute
directory and configure that directory in the agent.

## Publication gates

The signed release job must stop unless all of the following are available:

1. supported tool and OpenShell control images published as immutable
   `mitosu-cloud` GHCR digests with GitHub build provenance;
2. native smoke evidence for every declared architecture;
3. signed marker attestations for the selected Node and Python workload images;
4. a checksum-pinned and executable `openshell_driver_vm` input for each host
   target;
5. the protected Ed25519 environment secret, matching source-controlled public
   key, required reviewers, and approved rotation plan; and
6. a direct HTTPS directory host or an installer-owned absolute directory.

The workflow implements these gates but does not claim a production release
exists. The Node and Python profile locks and Containerfile stages, native
arm64 publication evidence, protected environment/key configuration, and final
direct-directory deployment must all be completed before dispatching an
official pack release.
