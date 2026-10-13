# Mitosu runner OS images

This repository defines the Linux development root filesystems used by
`mitosurunner`. The canonical outputs are digest-pinned, multi-platform OCI
images; container and virtual-machine backends consume the same root
filesystem.

The release matrix contains Rust, Go, Node.js, Python, and C/C++ development
profiles for Ubuntu 26.04 LTS and AlmaLinux 10 on `amd64` and `arm64`.

## Repository contract

Phase 1 establishes the data model and validation boundary before any image is
built. Run:

```sh
make validate
make resolve
make test
make lint
```

`make resolve` prints the 18 fully resolved image/architecture combinations as
JSON. It does not invoke a container engine or download build inputs.

The OS, runner, Ubuntu Node, and Ubuntu Python inputs are locked. Rust, Go,
C/C++, and non-Ubuntu language combinations remain pending and fail closed.
No script may interpret a pending lock as a tag or floating version.

## Local requirements

- Bash 4 or newer
- GNU Make
- `jq` 1.6 or newer
- the Python `jsonschema` command for JSON Schema validation
- ShellCheck for `make lint`
- Podman for image builds and smoke tests

Build-time state is confined to `/tmp` and defaults to
`/tmp/mitosu-runner-os-images`. `MITOSU_BUILD_ROOT` may select another dedicated
directory only when it still resolves beneath `/tmp`; paths in the checkout,
the home directory, and other local filesystems are rejected. The repository
never uses the checkout for layer caches, OCI layouts, reports, or private
staging.

Podman is invoked with explicit graph root, run root, and temporary directories
below that build root. It does not use the default container store.

## Image builds

The Ubuntu and AlmaLinux OS locks contain dated base-index digests, both
platform manifest digests, exact requested package versions, and checksums for
every package-repository metadata file. Verify the external repository state:

```sh
make verify-inputs
```

Build one native common image after the runner lock has been resolved:

```sh
make build DISTRIBUTION=ubuntu-26.04
```

Build the locked Ubuntu Node or Python profile with:

```sh
make build DISTRIBUTION=ubuntu-26.04 PROFILE=node
make build DISTRIBUTION=ubuntu-26.04 PROFILE=python
```

The Node image installs the checksum-pinned official Node 22.22.1 archive and
its bundled npm 10.9.4 and Corepack 0.34.6. The Python image builds the
checksum-pinned Python.org 3.14.4 source and installs checksum-pinned uv 0.10.8.
Both retain the snapshot-locked native build prerequisites, run as UID/GID
1000, use `/mitosu/workspace`, and contain no OpenShell policy.

The checked-in runner lock selects the public multi-platform
`ghcr.io/mitosu-cloud/mitosurunner` image by immutable OCI index digest. Local
pipeline work may provide `RUNNER_IMAGE` and `RUNNER_SOURCE_DIGEST` explicitly;
both must be immutable digest references and the override is recorded in build
and smoke reports. Overrides never update or bypass the release lock.

Smoke a built image with no network and a read-only root filesystem:

```sh
make smoke IMAGE=localhost/mitosu/ubuntu-26.04-common:<commit>-amd64
```

Run the complete common-image verification, including byte-for-byte runner
comparison and inspection of the resolver stored in the OCI layers:

```sh
make verify IMAGE=localhost/mitosu/ubuntu-26.04-common:<commit>-amd64
```

Build, verify, and push every currently implemented image to GHCR with a
release tag. The default destination is the intended public package
`ghcr.io/mitosu-cloud/runner-os`, and build storage remains under `/tmp`:

```sh
make publish RELEASE_TAG=v0.1.0
```

Select one protected language profile and distribution explicitly:

```sh
make publish RELEASE_TAG=v0.1.0-node DISTRIBUTION=ubuntu-26.04 PROFILE=node
make publish RELEASE_TAG=v0.1.0-python DISTRIBUTION=ubuntu-26.04 PROFILE=python
```

The native host architecture is selected by default. To intentionally build
both architectures with emulation available, invoke the script directly:

```sh
./scripts/build-and-push-images.sh \
  --tag v0.1.0 \
  --architecture amd64 \
  --architecture arm64 \
  --allow-emulated
```

Cross-architecture builds require an enabled `binfmt_misc` QEMU handler with
the fix-binary flag. On Ubuntu hosts, install `qemu-user-static` and activate
`systemd-binfmt` before selecting `--allow-emulated`. The publisher validates
the handler before it authenticates, builds, or pushes anything.

The script authenticates to GHCR with the current `gh` session, refuses to
overwrite an existing release tag, verifies every image before pushing, and
writes immutable references and registry digests beneath
`/tmp/mitosu-runner-os-images/releases/`. The current buildable set is the
Ubuntu and AlmaLinux common images plus Ubuntu Node and Python. Other
language-profile combinations remain excluded until their toolchain locks and
Containerfile stages are implemented.

The active `gh` token needs `read:packages` and `write:packages`. GitHub creates
a package pushed from the command line as private by default; after the first
push, make `runner-os` public in the organization package settings. The script
records the observed visibility and warns until that one-time setting is done.
Use a classic PAT and authorize it for organization SSO when the organization
requires SAML authorization; the publisher checks `write:packages` before it
starts a build.

Machine-readable build and smoke reports are written beneath
`/tmp/mitosu-runner-os-images/reports` by default. Podman storage, OCI archives,
and temporary inspection data also remain beneath
`/tmp/mitosu-runner-os-images`.

## Signed runtime-pack handoff

The repository can assemble and verify the exact runtime-pack format consumed
by `mitosuagent`. The general assembler accepts any declared runtime artifact,
including `openshell_driver_vm`, and a JSON array of digest-pinned OCI images.
Each ACP workload image may carry the signed marker attestation enforced by the
agent. Generation and signing are separate so a build job never needs the
protected release key:

```sh
make assemble-runtime-pack \
  PACK_ID=openshell-2026.10-linux-x86_64 \
  TARGET_OS=linux \
  TARGET_ARCH=x86_64 \
  OCI_IMAGES=/absolute/path/to/oci-images.json \
  ARTIFACT_ARGS='--artifact openshell_driver_vm /absolute/path/to/openshell-driver-vm bin/openshell-driver-vm true'
```

The older Apple Containerization pack generator remains available for
historical releases:

```sh
make runtime-pack \
  PACK_ID=apple-container-0.41.0-arm64 \
  KERNEL=/absolute/path/to/vmlinux \
  RUNNER=/absolute/path/to/mitosurunner \
  INITFS=ghcr.io/example/vminit@sha256:<digest> \
  TOOL_IMAGE=ghcr.io/example/tool-image@sha256:<digest> \
  IMAGE_SET=/absolute/path/to/image-set.json

make sign-runtime-pack \
  RUNTIME_PACK_DIR=/tmp/mitosu-runner-os-images/runtime-packs/apple-container-0.41.0-arm64 \
  SIGNING_KEY=/protected/path/to/ed25519-private-key.pem \
  RUNTIME_PACK_SOURCE=/absolute/installed/release/directory

make verify-runtime-pack \
  RUNTIME_PACK_DIR=/tmp/mitosu-runner-os-images/runtime-packs/apple-container-0.41.0-arm64
```

Signing writes `release-handoff.json`. That file supplies the three values a
trusted `mitosuagent` configuration needs: the HTTPS source URL or absolute
directory path, the SHA-256 of the exact `manifest.json` bytes, and the
lowercase-hex 32-byte Ed25519 public key. The private key is never copied into
the pack. The protected `runtime-pack-release.yml` workflow accepts a
checksum-pinned unsigned archive rooted at `pack/`, validates the required VM
driver and attested Ubuntu Node/Python images, verifies GitHub provenance for
every OCI digest, signs with the protected environment key, checks the derived
public key against the source-controlled pin, publishes the unpacked pack at a
canonical no-redirect GitHub Pages URL, rechecks every published byte, attests
the release files through GitHub OIDC, and publishes an immutable-tagged GitHub
release. See the
[release policy](docs/release.md) for environment setup, publication gates,
and key handling.

See [architecture](docs/architecture.md),
[adding an image](docs/adding-an-image.md), and
[release policy](docs/release.md) for the contracts that future build phases
must preserve.

## License

Apache-2.0. See [LICENSE](LICENSE).
