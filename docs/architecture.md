# Architecture

The OCI root filesystem is the only canonical guest filesystem produced by
this repository. Apple Containerization and Docker consume the OCI image
directly. A Cloud Hypervisor backend may materialize a verified read-only disk
from the same OCI layers, cached by immutable digest; it must not maintain a
separately configured VM image.

Each final image will contain the exact statically linked runner copied from a
digest-pinned published runner image at
`/usr/local/bin/mitosurunner`. Agent models, model runtimes, ACP adapters,
credentials, host policy, and VM lifecycle code are outside this repository.

The guest contract reserves these stable identities and paths:

| Purpose | Contract |
| --- | --- |
| Tool user | `mitosu`, UID/GID `1000:1000` |
| Home | `/home/mitosu` |
| Projects | `/workspace/<mount-name>` |
| Application data | `/var/lib/mitosu/apps` |
| Language caches | `/var/cache/mitosu/<toolchain>` |
| Runner | `/usr/local/bin/mitosurunner` |
| Image marker | `/usr/share/mitosu/image.json` |

The root filesystem defaults `/etc/resolv.conf` to the runner-owned synthetic
resolver at `127.0.0.53`. Images contain public CA roots but configure no HTTP
proxy, replacement CA, SSH server, `sudo`, container daemon, credentials, or
models. Runtime egress destinations are untrusted suggestions until accepted
by signed host policy or explicit user approval.

## Declarative matrix

`locks/image-matrix.json` is the source of truth. It defines distributions,
development profiles, supported architectures, and the eight image IDs. Each
distribution and profile points at a separate input lock. Scripts resolve the
matrix; Containerfiles and workflows must not duplicate it.

The schema allows a new profile definition and its image rows to be added in
that one data file. Cross-reference validation rejects image rows that name an
undefined distribution or profile. The resolver expands each image over the
declared architecture set and emits stable, sorted JSON.

## Temporary and build data

All large or generated build state belongs under
`${MITOSU_BUILD_ROOT:-/tmp/mitosu-runner-os-images}`. The scripts reject a
relative build root and any build root located inside the source checkout.
Private transient directories use `mktemp` beneath that root and cleanup traps
remove only the directory created by the current process.
