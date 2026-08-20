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

Build-time state defaults to `/tmp/mitosu-runner-os-images`. Set
`MITOSU_BUILD_ROOT` to another absolute path only when the build host requires
it. The repository never uses a directory under the checkout for layer caches,
OCI layouts, or private staging.

See [architecture](docs/architecture.md),
[adding an image](docs/adding-an-image.md), and
[release policy](docs/release.md) for the contracts that future build phases
must preserve.

## License

Apache-2.0. See [LICENSE](LICENSE).
