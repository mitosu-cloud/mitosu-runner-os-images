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
compressed_pack="$staging/compressed-production"
"$REPOSITORY_ROOT/scripts/assemble-runtime-pack.sh" \
  --output "$compressed_pack" --pack-id fixture-compressed-linux-x86_64 \
  --target-os linux --target-arch x86_64 --oci-images "$staging/oci-images.json" \
  --compression zstd \
  --artifact openshell_driver_vm "$staging/openshell-driver-vm" bin/openshell-driver-vm true >/dev/null
"$REPOSITORY_ROOT/scripts/validate-production-runtime-pack.sh" --pack-dir "$compressed_pack" --github-release >/dev/null
if "$REPOSITORY_ROOT/scripts/validate-production-runtime-pack.sh" --pack-dir "$pack" --github-release >/dev/null 2>&1; then
  fail 'GitHub Release validator accepted uncompressed source paths'
fi
pass 'production GitHub packs require compressed flat assets and preserve workload attestations'


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
mkdir -p "$staging/mock-bin"
cat >"$staging/mock-bin/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *'--jq .size'* ]]; then
  printf '17\n'
else
  printf 'candidate fixture'
fi
MOCK
chmod 0755 "$staging/mock-bin/gh"
GITHUB_REPOSITORY=mitosu-cloud/mitosu-runner-os-images PATH="$staging/mock-bin:$PATH" \
  "$REPOSITORY_ROOT/scripts/download-runtime-pack-candidate.sh" \
    https://api.github.com/repos/mitosu-cloud/mitosu-runner-os-images/releases/assets/123 \
    "$staging/downloaded-candidate"
[[ $(<"$staging/downloaded-candidate") == 'candidate fixture' ]] || fail 'draft candidate bytes changed'
if GITHUB_REPOSITORY=mitosu-cloud/mitosu-runner-os-images PATH="$staging/mock-bin:$PATH" \
  "$REPOSITORY_ROOT/scripts/download-runtime-pack-candidate.sh" \
    https://api.github.com/repos/mitosu-cloud/mitosu-runner-os-images/releases/assets/123/extra \
    "$staging/invalid-candidate" >/dev/null 2>&1; then
  fail 'draft candidate downloader accepted a malformed asset ID'
fi
[[ ! -e $staging/invalid-candidate ]] || fail 'failed candidate download retained output'
pass 'draft candidate staging authenticates only exact same-repository GitHub asset URLs'


openssl genpkey -algorithm ED25519 -out "$staging/pages-signing-key.pem" 2>/dev/null
prior_pack="$staging/prior-pack"
current_pack="$staging/current-pack"
for pages_pack_id in pages-prior-linux-x86_64 pages-current-linux-x86_64; do
  pages_pack="$current_pack"
  if [[ $pages_pack_id == pages-prior-linux-x86_64 ]]; then
    pages_pack="$prior_pack"
  fi
  "$REPOSITORY_ROOT/scripts/assemble-runtime-pack.sh" \
    --output "$pages_pack" \
    --pack-id "$pages_pack_id" \
    --target-os linux \
    --target-arch x86_64 \
    --oci-images "$staging/oci-images.json" \
    --artifact openshell_driver_vm "$staging/openshell-driver-vm" bin/openshell-driver-vm true \
    >/dev/null
  "$REPOSITORY_ROOT/scripts/sign-runtime-pack.sh" \
    --pack-dir "$pages_pack" \
    --private-key "$staging/pages-signing-key.pem" \
    --source "https://mitosu-cloud.github.io/mitosu-runner-os-images/runtime-packs/$pages_pack_id/" \
    >/dev/null
done
pages_public_key=$(tr -d '[:space:]' < "$current_pack/ed25519-public-key.hex")
prior_release_name=runtime-pack-pages-prior-linux-x86_64
prior_release_dir="$staging/prior-releases/$prior_release_name"
prior_archive_root="$staging/prior-archive-root"
mkdir -p "$prior_release_dir" "$prior_archive_root"
cp -a -- "$prior_pack" "$prior_archive_root/pack"
tar -C "$prior_archive_root" -czf "$prior_release_dir/$prior_release_name.tar.gz" pack
printf '%s  %s\n' \
  "$(sha256_file "$prior_release_dir/$prior_release_name.tar.gz")" \
  "$prior_release_name.tar.gz" > "$prior_release_dir/SHA256SUMS"
pages_site="$staging/pages-site"
"$REPOSITORY_ROOT/scripts/stage-runtime-pack-pages.sh" \
  --site-dir "$pages_site" \
  --current-pack "$current_pack" \
  --prior-releases-dir "$staging/prior-releases" \
  --public-key "$pages_public_key" >/dev/null
[[ -f $pages_site/runtime-packs/pages-prior-linux-x86_64/manifest.sig ]] ||
  fail 'Pages staging omitted a prior immutable runtime pack'
[[ -f $pages_site/runtime-packs/pages-current-linux-x86_64/manifest.sig ]] ||
  fail 'Pages staging omitted the current runtime pack'
pass 'Pages staging preserves prior signed packs beside the current release'

workflow="$REPOSITORY_ROOT/.github/workflows/runtime-pack-release.yml"
stage_workflow="$REPOSITORY_ROOT/.github/workflows/stage-runtime-pack-candidate.yml"
publish_workflow="$REPOSITORY_ROOT/.github/workflows/self-hosted-publish.yml"
control_workflow="$REPOSITORY_ROOT/.github/workflows/openshell-control-images.yml"
gh_installer="$REPOSITORY_ROOT/scripts/install-pinned-gh.sh"
release_uploader="$REPOSITORY_ROOT/scripts/upload-runtime-pack-release.sh"
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
grep -Fq 'needs: [validate-candidate, sign-runtime-pack]' "$workflow" ||
  fail 'release publication is not ordered after validation and protected signing'
grep -Fq -- '--draft=false' "$workflow" ||
  fail 'release is not finalized after draft byte verification'
grep -Fq 'scripts/fetch-runtime-pack-release.py' "$workflow" ||
  fail 'public GitHub assets are not independently verified'
grep -Fq 'scripts/upload-runtime-pack-release.sh' "$workflow" ||
  fail 'runtime-pack publication does not use the reviewed sequential uploader'
grep -Fq 'timeout-minutes: 180' "$workflow" ||
  fail 'runtime-pack publisher cannot accommodate measured release-upload throughput'
grep -Fq 'Remove incomplete draft after publication failure' "$workflow" ||
  fail 'runtime-pack publication does not clean failed draft releases'
grep -Fq 'candidate_run_id:' "$workflow" ||
  fail 'runtime-pack release does not require an immutable staging run ID'
grep -Fq 'stage-runtime-pack-candidate.yml' "$workflow" ||
  fail 'runtime-pack release does not authenticate the candidate staging workflow'
# GitHub expressions must remain literal here.
# shellcheck disable=SC2016
grep -Fq 'run-id: ${{ inputs.candidate_run_id }}' "$workflow" ||
  fail 'runtime-pack release does not download from the exact staging run'
[[ $(grep -Fc 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093' \
  "$workflow") -eq 2 ]] || fail 'runtime-pack release does not pin both artifact downloads'
[[ $(grep -Fc 'runs-on: [self-hosted, Linux, ARM64, runtime-pack-release]' "$workflow") -eq 2 ]] ||
  fail 'runtime-pack validation and signing must use the dedicated ARM64 release lane'
[[ $(grep -Fc 'runs-on: [self-hosted, Linux, ARM64, runtime-pack-publish]' "$workflow") -eq 1 ]] ||
  fail 'runtime-pack publication must use the dedicated ARM64 publisher lane'
if grep -Fq 'runs-on: [self-hosted, Linux, X64]' "$workflow"; then
  fail 'protected runtime-pack workflow still targets the lossy x86_64 lane'
fi
[[ $(grep -Fc 'scripts/install-pinned-gh.sh' "$workflow") -eq 2 ]] ||
  fail 'runtime-pack signing and publication do not install the pinned GitHub CLI'
grep -Fq 'packages+=(docker.io)' "$workflow" ||
  fail 'runtime-pack signing does not provision Docker on a bare runner'
# The workflow shell expression must remain literal here.
# shellcheck disable=SC2016
grep -Fq 'sudo setfacl -m "u:$(id -un):rw" /var/run/docker.sock' "$workflow" ||
  fail 'runtime-pack signing does not grant access to its Docker socket'
if grep -Fq 'actions/deploy-pages@' "$workflow"; then
  fail 'new Release asset publication would replace historical Pages downloads'
fi
[[ -f $stage_workflow && ! -L $stage_workflow ]] ||
  fail 'protected candidate staging workflow is missing or unsafe'
grep -Fq 'runs-on: [self-hosted, Linux, ARM64, runtime-pack-release]' "$stage_workflow" ||
  fail 'candidate staging does not use the dedicated ARM64 release lane'
grep -Fq 'environment: runtime-release' "$stage_workflow" ||
  fail 'candidate staging is not protected by the release environment'
grep -Fq 'candidate_asset_url:' "$stage_workflow" ||
  fail 'candidate staging does not require an exact draft-release asset URL'
grep -Fq 'https://api.github.com/repos/$GITHUB_REPOSITORY/releases/assets/' \
  "$stage_workflow" || fail 'candidate staging does not restrict authenticated ingress to its repository'
grep -Fq 'scripts/download-runtime-pack-candidate.sh' "$stage_workflow" ||
  fail 'candidate staging does not use the bounded reviewed downloader'
grep -Fq 'scripts/install-pinned-gh.sh' "$stage_workflow" ||
  fail 'candidate staging does not install the pinned GitHub CLI'
grep -Fq 'sha256sum --check --strict' "$stage_workflow" ||
  fail 'candidate staging does not verify the reviewed SHA-256'
grep -Fq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' \
  "$stage_workflow" || fail 'candidate staging does not pin artifact upload'
grep -Fq 'compression-level: 0' "$stage_workflow" ||
  fail 'candidate staging recompresses an already compressed runtime pack'
grep -Fq 'retention-days: 1' "$stage_workflow" ||
  fail 'candidate staging retains the transient artifact too long'
[[ $(grep -Fc 'compression-level: 0' "$workflow") -eq 1 ]] ||
  fail 'signed runtime-pack artifacts are recompressed in transit'
# GitHub expressions must remain literal here.
# shellcheck disable=SC2016
grep -Fq 'name: runtime-pack-candidate-${{ inputs.candidate_sha256 }}' "$stage_workflow" ||
  fail 'candidate staging artifact is not bound to the reviewed SHA-256'
if grep -Fq 'gh release upload' "$stage_workflow"; then
  fail 'candidate staging still uses the non-resumable GitHub Release upload path'
fi
if grep -Fq 'STAGING_ROOT:' "$stage_workflow"; then
  fail 'candidate staging still depends on one runner host filesystem'
fi
[[ -x $gh_installer && ! -L $gh_installer ]] ||
  fail 'pinned GitHub CLI installer is missing, unsafe, or not executable'
grep -Fq 'readonly version=2.100.0' "$gh_installer" ||
  fail 'GitHub CLI installer does not pin the reviewed version'
grep -Fq 'ea4e7a581a32ccad6cc7923cb1576ac5859ba4b9a16ab22eb8f8a96e78e2e961' \
  "$gh_installer" || fail 'GitHub CLI installer does not pin the reviewed ARM64 checksum'
grep -Fq 'e4d4bb4498e8d007abe545b6568926793ace1b6447da598294a610018cb164be' \
  "$gh_installer" || fail 'GitHub CLI installer does not pin the reviewed x86_64 checksum'
[[ -x $release_uploader && ! -L $release_uploader ]] ||
  fail 'sequential release uploader is missing, unsafe, or not executable'
grep -Fq -- '--http1.1' "$release_uploader" ||
  fail 'release uploader does not force HTTP/1.1'
grep -Fq -- '--max-time 7200' "$release_uploader" ||
  fail 'release uploader does not allow a measured large-asset transfer to finish'
grep -Fq 'speed_upload=%{speed_upload}' "$release_uploader" ||
  fail 'release uploader does not report safe transport throughput diagnostics'
grep -Fq 'server_digest' "$release_uploader" ||
  fail 'release uploader does not verify server-recorded digests'
grep -Fq 'release must not contain assets before upload' "$release_uploader" ||
  fail 'release uploader does not require an empty draft'
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
grep -Fq 'RUSTFLAGS="-C relocation-model=static"' "$control_workflow" ||
  fail 'OpenShell sandbox is not forced to a launchable static MUSL executable'
# GitHub expressions must remain literal here.
# shellcheck disable=SC2016
grep -Fq 'targets: ${{ matrix.gnu_target }},${{ matrix.musl_target }}' "$control_workflow" ||
  fail 'OpenShell publication does not install both Rust targets on bare runners'
grep -Fq 'dtolnay/rust-toolchain@4360b52568e2003a75bf9bc1d59f33a8e3fc893c' "$control_workflow" ||
  fail 'OpenShell publication does not pin its rustup bootstrap action'
[[ $(grep -Fc 'cache-binary: false' "$control_workflow") -eq 2 ]] ||
  fail 'OpenShell publication allows setup-buildx to use GitHub cache storage'
grep -Fq 'packages+=(docker.io)' "$control_workflow" ||
  fail 'OpenShell publication does not provision Docker on a bare self-hosted runner'
# The workflow shell expression must remain literal here.
# shellcheck disable=SC2016
grep -Fq 'sudo setfacl -m "u:$(id -un):rw" /var/run/docker.sock' "$control_workflow" ||
  fail 'OpenShell publication does not grant the runner access to its Docker socket'
pass 'protected workflows isolate signing and pin GitHub provenance actions'
