# Adding a distribution or profile

Start with `locks/image-matrix.json`:

1. Add a distribution or profile definition with a unique ID.
2. Add the desired image rows. Image IDs are
   `<distribution-id>-<profile-id>`.
3. Add the referenced OS or toolchain lock when the definition is intended to
   build. A synthetic contract-test profile may use a null toolchain lock.
4. Run `make validate` and inspect `make resolve`.

Unknown fields are errors. Distribution families and architectures are closed
sets in the current schema, so extending either also requires a reviewed schema
change. Profile IDs are extensible data, but an image cannot reference a
profile that is not defined in the same matrix.

An input lock may be committed as `pending` while a new profile is designed,
but build code must accept only `locked` inputs. A locked OS base requires an
OCI index digest and immutable repository snapshot metadata. A locked external
toolchain artifact requires an exact version, architecture, URL, and SHA-256.

Do not copy an existing Containerfile merely to change matrix data. Put shared
guest setup under `images/common` and keep genuine distribution differences in
the family Containerfile.
