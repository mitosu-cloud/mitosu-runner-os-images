# Contributing

Create a topic branch from `main`; do not commit image work directly to
`main`. Keep changes to the declarative matrix and locks separate from changes
to build behavior when practical.

Before opening a pull request, run:

```sh
make test
make lint
```

The contract tests require matrix data to reject unknown fields, duplicate
IDs, unknown references, and unsupported architectures. A new distribution or
profile belongs in `locks/image-matrix.json`; build scripts must not carry a
second hard-coded matrix.

Do not commit credentials, registry tokens, signing keys, model artifacts,
container-engine state, build caches, package indexes, or generated OCI
layouts. Record failed build and smoke-test evidence as bounded CI artifacts,
not as unreviewed binary files in the repository.

All generated and build-time state defaults to `/tmp/mitosu-runner-os-images`.
If `MITOSU_BUILD_ROOT` is set, it must be an absolute path outside the source
checkout. Scripts may remove only temporary directories they created.
