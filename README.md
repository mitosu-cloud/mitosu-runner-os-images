# Mitosu runner OS images

This repository defines the Linux development root filesystems used by
`mitosurunner`. The canonical outputs are digest-pinned, multi-platform OCI
images; container and virtual-machine backends consume the same root
filesystem.

The first release matrix contains Rust, Go, Node.js, and C/C++ development
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

`make resolve` prints the 16 fully resolved image/architecture combinations as
JSON. It does not invoke a container engine or download build inputs.

The checked-in OS and toolchain locks initially have `status: "pending"`.
They document the lock format but are deliberately not buildable inputs. A
later phase must replace every pending value with verified digests, versions,
and checksums before image construction can succeed. No script may silently
interpret a pending lock as a tag or floating version.

## Local requirements

- Bash 4 or newer
- GNU Make
- `jq` 1.6 or newer
- the Python `jsonschema` command for JSON Schema validation
- ShellCheck for `make lint`
- Podman for image builds and smoke tests

Build-time state defaults to `/tmp/mitosu-runner-os-images`. Set
`MITOSU_BUILD_ROOT` to another absolute path only when the build host requires
it. The repository never uses a directory under the checkout for layer caches,
OCI layouts, or private staging.

Podman is invoked with explicit graph root, run root, and temporary directories
below that build root. It does not use the default container store.

## Common image builds

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

The checked-in runner lock remains pending until a multi-platform
`ghcr.io/mitosu-cloud/mitosurunner` image is published and its digest is
verified. Local pipeline work may provide `RUNNER_IMAGE` and
`RUNNER_SOURCE_DIGEST` explicitly; both must be immutable digest references and
the override is recorded in build and smoke reports. Overrides never update or
bypass the release lock.

Smoke a built image with no network and a read-only root filesystem:

```sh
make smoke IMAGE=localhost/mitosu/ubuntu-26.04-common:<commit>-amd64
```

Machine-readable build and smoke reports are written beneath
`/tmp/mitosu-runner-os-images/reports` by default.

See [architecture](docs/architecture.md),
[adding an image](docs/adding-an-image.md), and
[release policy](docs/release.md) for the contracts that future build phases
must preserve.

## License

Apache-2.0. See [LICENSE](LICENSE).
