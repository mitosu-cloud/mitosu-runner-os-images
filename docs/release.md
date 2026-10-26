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

Official new packs use an explicit GitHub Release download directory:
`https://github.com/mitosu-cloud/mitosu-runner-os-images/releases/download/runtime-pack-<pack_id>/`.
Schema 3 preserves each installed artifact's path, size, SHA-256 and executable
bit and adds signed `transport` metadata: `compression: zstd`, flat source path,
compressed size and compressed SHA-256. Build with `--compression zstd` in
`scripts/assemble-runtime-pack.sh`. The source pack contains the compressed
payloads only; verification checks both representations. Each release asset
must be below GitHub's 2 GiB per-file limit.

Production OpenShell packs must also contain
`openshell_driver_vm_provenance`. Protected validation requires provenance
schema 2, a clean source commit shared by the driver and its source-sensitive
embedded runtime, and an explicit fresh supervisor-bundle build. It locates
each declared compressed runtime payload inside the driver, verifies both its
compressed and expanded identity without executing candidate code, and checks
that the embedded supervisor and sandbox versions identify the same source
commit. The supervisor must also contain the driver's
`--parent-liveness-stdin` contract. Reused or merely asserted embedded bytes are
rejected before the signing key is injected.

The agent authenticates transport bytes before bounded in-process expansion,
then verifies expanded bytes before atomic publication. Its storage admission
covers all expanded files plus the largest temporary compressed file and
metadata. Expansion accepts one zstd frame and a window no larger than 64 MiB.
No decompressor executable or resident service is needed on the agent machine.

GitHub public downloads may follow at most three HTTPS redirects, exclusively
to `release-assets.githubusercontent.com` or `objects.githubusercontent.com`.
Credentials, custom ports, login destinations, mutable `latest` aliases and
other redirect hosts are refused. Generic HTTPS directories keep redirects
disabled. Public consumers require no GitHub token. Existing schema 1/2 raw
packs and installer-owned absolute directories remain supported. Historical
Pages deployments remain untouched by this workflow; keep them available for
already-pinned configurations.

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
packaging. Public outputs contain only `manifest.json`, `ed25519-public-key.hex`,
`manifest.sig`, `release-handoff.json`, compressed payloads and `SHA256SUMS`.

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

Upload that archive to a **draft** release and pass its API asset URL to
`.github/workflows/stage-runtime-pack-candidate.yml`,
`https://api.github.com/repos/mitosu-cloud/mitosu-runner-os-images/releases/assets/ASSET_ID`.
GitHub requires push-capable access to private draft assets. Only the existing
protected `runtime-release` staging job fetches them, with its `GH_TOKEN`
through `gh api` for an exact same-repository asset URL. It checks
declared/downloaded lengths and the separately pinned candidate SHA-256, then
uploads the verified bytes as a one-day, uncompressed Actions artifact. The
staging job no longer depends on a particular self-hosted runner's filesystem.
Credentials do not enter argv or generic-origin requests. The draft need not be
published or made immutable; retain it on failure and remove it after the final
runtime release succeeds.

After staging succeeds, dispatch `.github/workflows/runtime-pack-release.yml`
with the exact source SHA, `runtime-pack-<pack_id>` release tag, successful
candidate staging run ID, candidate SHA-256, and the explicit GitHub Release
download directory URL for that tag.
The protected workflow requires schema 3, compressed flat source paths and
individual payloads below 2 GiB. A read-only job validates the reviewed source,
input URL/identity contract and repository tests first. After environment
approval, the protected job validates candidate bytes and OCI provenance before
the signing step receives the private key. It rejects path
traversal, links, special files, undeclared files, size or mode mismatches,
mutable or local OCI references, missing `openshell_driver_vm`, missing
OpenShell control images, and missing attested `ubuntu-26.04-node` or
`ubuntu-26.04-python` images for the selected guest architecture.

The protected job downloads the SHA-pinned candidate from its reviewed source,
extracts and validates it without executing bundled artifacts, verifies OCI
provenance, then injects the private key only into the subsequent signing step.
It signs and stages the exact signed manifest, signature, public handoff and
compressed payloads. The final job rechecks the source-controlled trust pin,
attests each release file, uploads a draft, independently downloads and compares
all draft assets, then publishes and checks `isImmutable`. It verifies every
public asset again without GitHub credentials using bounded HTTPS-only GitHub
asset redirects. Only a successful result removes the transient signed-output
Actions artifact. Existing tags are refused; an interrupted
draft is retained for inspection and is not silently overwritten. A public
verification failure leaves the immutable release and failed workflow as
evidence; it does not claim successful installation qualification.

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
6. compressed GitHub Release asset delivery verified anonymously, or an
   installer-owned absolute directory for explicitly local installation.

The workflow implements these gates but does not by itself claim a production
release exists. Each release record must identify the exact image, driver,
manifest, hosting, and qualification evidence produced by the successful run.
