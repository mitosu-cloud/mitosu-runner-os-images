#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPOSITORY_ROOT=$(cd -- "$TEST_DIR/.." && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$REPOSITORY_ROOT/scripts/lib/common.sh"

staging=$(make_private_temp_dir protected-release-contract)
trap 'rm -rf -- "$staging"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

printf '#!/bin/sh\nprintf "driver fixture\\n"\n' >"$staging/openshell-driver-vm"
chmod 0755 -- "$staging/openshell-driver-vm"
digest() {
  local character=$1
  local index
  for ((index = 0; index < 64; index += 1)); do
    printf '%s' "$character"
  done
}
cat >"$staging/oci-images.json" <<EOF
[
  {
    "name": "openshell_supervisor_image",
    "reference": "ghcr.io/mitosu-cloud/openshell-supervisor@sha256:$(digest a)"
  },
  {
    "name": "openshell_sandbox_runtime_image",
    "reference": "ghcr.io/mitosu-cloud/openshell-sandbox@sha256:$(digest b)"
  },
  {
    "name": "ubuntu_26_04_node_linux_x86_64",
    "reference": "ghcr.io/mitosu-cloud/ubuntu-26.04-node@sha256:$(digest c)",
    "attestation": {
      "schema_version": 1,
      "image_id": "ubuntu-26.04-node",
      "profile_revision": 1,
      "guest_target": "linux_x86_64",
      "marker_sha256": "$(digest d)",
      "runner_protocol": "mitosu.runner.v1",
      "runner_source_digest": "ghcr.io/mitosu-cloud/mitosurunner@sha256:$(digest e)",
      "tool_uid": 1000,
      "tool_gid": 1000,
      "capabilities": ["shell", "git", "curl", "node"],
      "toolchains": {"node": "22.22.1"}
    }
  },
  {
    "name": "ubuntu_26_04_python_linux_x86_64",
    "reference": "ghcr.io/mitosu-cloud/ubuntu-26.04-python@sha256:$(digest f)",
    "attestation": {
      "schema_version": 1,
      "image_id": "ubuntu-26.04-python",
      "profile_revision": 1,
      "guest_target": "linux_x86_64",
      "marker_sha256": "$(digest 1)",
      "runner_protocol": "mitosu.runner.v1",
      "runner_source_digest": "ghcr.io/mitosu-cloud/mitosurunner@sha256:$(digest e)",
      "tool_uid": 1000,
      "tool_gid": 1000,
      "capabilities": ["shell", "git", "curl", "python", "uv"],
      "toolchains": {"python": "3.14.4", "uv": "0.10.8"}
    }
  }
]
EOF

pack="$staging/pack"
"$REPOSITORY_ROOT/scripts/assemble-runtime-pack.sh" \
  --output "$pack" \
  --pack-id fixture-linux-x86_64 \
  --target-os linux \
  --target-arch x86_64 \
  --oci-images "$staging/oci-images.json" \
  --artifact openshell_driver_vm "$staging/openshell-driver-vm" bin/openshell-driver-vm true \
  >/dev/null
"$REPOSITORY_ROOT/scripts/validate-production-runtime-pack.sh" --pack-dir "$pack" >/dev/null
[[ $(jq -r '.schema_version' "$pack/manifest.json") == 2 ]] ||
  fail 'production assembler did not select schema version 2'
[[ $(jq '[.oci_images[] | select(.attestation != null)] | length' "$pack/manifest.json") == 2 ]] ||
  fail 'production assembler did not retain both workload attestations'
pass 'production pack assembly validates OpenShell and attested Node/Python inputs'

printf 'undeclared\n' >"$pack/extra.txt"
if "$REPOSITORY_ROOT/scripts/verify-runtime-pack-candidate.sh" --pack-dir "$pack" \
    >"$staging/extra.stdout" 2>"$staging/extra.stderr"; then
  fail 'candidate verifier accepted an undeclared file'
fi
rm -- "$pack/extra.txt"
pass 'candidate verifier rejects undeclared pack files'

tar -C "$staging" -czf "$staging/candidate.tar.gz" pack
"$REPOSITORY_ROOT/scripts/extract-runtime-pack-candidate.py" \
  "$staging/candidate.tar.gz" "$staging/extracted"
"$REPOSITORY_ROOT/scripts/validate-production-runtime-pack.sh" \
  --pack-dir "$staging/extracted/pack" >/dev/null
[[ -x $staging/extracted/pack/bin/openshell-driver-vm ]] ||
  fail 'candidate extraction lost the driver executable bit'
pass 'candidate extractor preserves the validated pack contract'

mkdir -p "$staging/unsafe/pack"
chmod 0700 "$staging/unsafe" "$staging/unsafe/pack"
cp -- "$pack/manifest.json" "$staging/unsafe/pack/manifest.json"
ln -s /etc/passwd "$staging/unsafe/pack/escape"
tar -C "$staging/unsafe" -czf "$staging/unsafe.tar.gz" pack
if "$REPOSITORY_ROOT/scripts/extract-runtime-pack-candidate.py" \
    "$staging/unsafe.tar.gz" "$staging/unsafe-extracted" \
    >"$staging/unsafe.stdout" 2>"$staging/unsafe.stderr"; then
  fail 'candidate extractor accepted a symlink'
fi
pass 'candidate extractor rejects links and special archive members'

workflow="$REPOSITORY_ROOT/.github/workflows/runtime-pack-release.yml"
publish_workflow="$REPOSITORY_ROOT/.github/workflows/self-hosted-publish.yml"
release_public_key="$REPOSITORY_ROOT/release/runtime-pack-ed25519-public-key.hex"
[[ -f $release_public_key && ! -L $release_public_key ]] ||
  fail 'source-controlled release public key is missing or unsafe'
public_key_value=$(tr -d '[:space:]' < "$release_public_key")
[[ $public_key_value =~ ^[a-f0-9]{64}$ ]] ||
  fail 'source-controlled release public key is not 32-byte lowercase hexadecimal'
grep -Fq 'environment: runtime-release' "$workflow" ||
  fail 'runtime-pack signing job is not protected by the release environment'
grep -Fq 'MITOSU_RUNTIME_PACK_SIGNING_KEY_PEM' "$workflow" ||
  fail 'runtime-pack workflow does not use the protected signing secret'
grep -Fq 'release/runtime-pack-ed25519-public-key.hex' "$workflow" ||
  fail 'runtime-pack workflow does not compare against the source-controlled public key'
grep -Fq -- '--json isImmutable' "$workflow" ||
  fail 'runtime-pack workflow does not verify its published release is immutable'
grep -Fq 'actions/upload-pages-artifact@7b1f4a764d45c48632c6b24a0339c27f5614fb0b' "$workflow" ||
  fail 'runtime-pack workflow does not pin the reviewed Pages artifact action'
grep -Fq 'actions/deploy-pages@d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e' "$workflow" ||
  fail 'runtime-pack workflow does not pin the reviewed Pages deployment action'
grep -Fq 'needs: [validate-candidate, sign-runtime-pack, deploy-runtime-pack]' "$workflow" ||
  fail 'immutable release publication is not ordered after direct hosting'
grep -Fq -- "--proto '=https' --tlsv1.2 --max-redirs 0" "$workflow" ||
  fail 'published runtime-pack verification permits redirects'
provenance_pin_count=0
for workflow_file in "$workflow" "$publish_workflow"; do
  workflow_pin_count=$(grep -Fc \
    'actions/attest-build-provenance@977bb373ede98d70efdf65b84cb5f73e068dcc2a' \
    "$workflow_file" || true)
  provenance_pin_count=$((provenance_pin_count + workflow_pin_count))
done
[[ $provenance_pin_count -eq 2 ]] ||
  fail 'release workflows do not pin both provenance actions to the reviewed commit'
grep -Fq 'push-to-registry: true' "$publish_workflow" ||
  fail 'image provenance is not pushed beside the OCI manifest'
# GitHub expressions must remain literal here.
# shellcheck disable=SC2016
[[ $(grep -Fc 'HOME: ${{ runner.temp }}/mitosu-attest-${{ github.run_id }}-${{ github.run_attempt }}' \
  "$publish_workflow") -eq 3 ]] ||
  fail 'provenance credential setup, use, and cleanup do not share the isolated home'
# The workflow shell variable must remain literal here.
# shellcheck disable=SC2016
grep -Fq 'rm -f -- "$HOME/.docker/config.json"' "$publish_workflow" ||
  fail 'image publication does not remove provenance registry credentials'
if grep -Fq 'MITOSU_RUNTIME_PACK_SIGNING_KEY_PEM' "$publish_workflow"; then
  fail 'image publication job references the runtime-pack signing key'
fi
pass 'protected workflows isolate signing and pin GitHub provenance actions'
