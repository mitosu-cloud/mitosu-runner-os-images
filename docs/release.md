# Release policy

Pull-request workflows have read-only repository permissions and never receive
registry credentials. They validate contracts, lint shell, build changed matrix
entries without publishing, run native smoke tests for the host architecture,
and label any cross-architecture result as emulated.

Publication will be added in a later phase and must be restricted to protected
tags or explicit approval in the upstream repository. It must rebuild a clean,
signed source revision on native `amd64` and `arm64` builders, publish by digest,
attach SBOM and provenance attestations, generate `image-set.json`, and verify
each published architecture by pulling its manifest digest and rerunning smoke
tests.

Tags are discovery aliases only. Runtime packs and handoff reports use immutable
OCI digests. A fork can publish images and keyless provenance under its own
identity but cannot issue an official Mitosu runtime-pack signature.

Do not claim byte-for-byte reproducibility or architecture support until CI has
produced the corresponding rebuild comparison or native smoke evidence.
