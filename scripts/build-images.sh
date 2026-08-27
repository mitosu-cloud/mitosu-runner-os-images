#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/podman.sh
source "$SCRIPT_DIR/lib/podman.sh"

distribution_id=
architecture=$(host_oci_architecture)
runner_image=
runner_source_digest=

usage() {
  cat <<'EOF'
Usage: scripts/build-images.sh --distribution ID [options]

Build the Phase 2 common image for one distribution and architecture.

Options:
  --architecture amd64|arm64
  --runner-image IMAGE             digest-pinned local or registry image
  --runner-source-digest REPO@DIGEST

When the checked-in runner lock is pending, both runner override options are
required. Overrides are for local validation only and never modify the lock.
EOF
}

while (($# > 0)); do
  case $1 in
    --distribution)
      (($# >= 2)) || die '--distribution requires a value'
      distribution_id=$2
      shift 2
      ;;
    --architecture)
      (($# >= 2)) || die '--architecture requires a value'
      architecture=$2
      shift 2
      ;;
    --runner-image)
      (($# >= 2)) || die '--runner-image requires a value'
      runner_image=$2
      shift 2
      ;;
    --runner-source-digest)
      (($# >= 2)) || die '--runner-source-digest requires a value'
      runner_source_digest=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n $distribution_id ]] || die '--distribution is required'
case $architecture in
  amd64|arm64) ;;
  *) die "unsupported architecture: $architecture" ;;
esac

require_command git
require_command jq
"$SCRIPT_DIR/validate-locks.sh" >/dev/null

if ! git -C "$REPOSITORY_ROOT" diff --quiet \
  || ! git -C "$REPOSITORY_ROOT" diff --cached --quiet \
  || [[ -n $(git -C "$REPOSITORY_ROOT" ls-files --others --exclude-standard) ]]; then
  die 'refusing to build from a dirty source tree'
fi

matrix="$REPOSITORY_ROOT/locks/image-matrix.json"
distribution=$(jq -c --arg id "$distribution_id" \
  '.distributions[] | select(.id == $id)' "$matrix")
[[ -n $distribution ]] || die "unknown distribution: $distribution_id"
family=$(jq -r '.family' <<<"$distribution")
lock_path=$(jq -r '.os_lock' <<<"$distribution")
absolute_lock="$REPOSITORY_ROOT/$lock_path"
[[ $(jq -r '.status' "$absolute_lock") == locked ]] ||
  die "OS lock is not build-ready: $lock_path"

runner_lock="$REPOSITORY_ROOT/locks/runner.json"
if [[ -z $runner_image ]]; then
  [[ $(jq -r '.status' "$runner_lock") == locked ]] ||
    die 'runner lock is pending; supply an explicit local test override or publish and lock the runner image'
  runner_source_digest="$(jq -r '.repository' "$runner_lock")@$(jq -r '.index_digest' "$runner_lock")"
  runner_image=$runner_source_digest
else
  [[ -n $runner_source_digest ]] ||
    die '--runner-source-digest is required with --runner-image'
fi

[[ $runner_source_digest =~ ^[a-z0-9._/-]+@sha256:[a-f0-9]{64}$ ]] ||
  die 'runner source digest must be REPOSITORY@sha256:<64 lowercase hexadecimal characters>'
if [[ ! $runner_image =~ @sha256:[a-f0-9]{64}$ && ! $runner_image =~ ^sha256:[a-f0-9]{64}$ ]]; then
  die 'runner image must be selected by immutable repository digest or local image ID'
fi

"$SCRIPT_DIR/verify-os-repositories.sh" \
  --distribution "$distribution_id" --architecture "$architecture"

source_revision=$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)
source_date_epoch=$(git -C "$REPOSITORY_ROOT" show -s --format=%ct HEAD)
created=$(date -u -d "@$source_date_epoch" '+%Y-%m-%dT%H:%M:%SZ')
base_image="$(jq -r '.base.repository' "$absolute_lock")@$(jq -r '.base.index_digest' "$absolute_lock")"
lock_digest="sha256:$(sha256_file "$absolute_lock")"
common_packages=$(jq -r --arg architecture "$architecture" \
  '.packages[$architecture] | join(" ")' "$absolute_lock")
image_id="$distribution_id-common"
image_reference="localhost/mitosu/$image_id:${source_revision:0:12}-$architecture"
containerfile="$REPOSITORY_ROOT/$(jq -r '.containerfile' <<<"$distribution")"

build_arguments=(
  --arch "$architecture"
  --file "$containerfile"
  --target common
  --tag "$image_reference"
  --build-arg "BASE_IMAGE=$base_image"
  --build-arg "RUNNER_IMAGE=$runner_image"
  --build-arg "IMAGE_ID=$image_id"
  --build-arg "TARGET_ARCH=$architecture"
  --build-arg "RUNNER_SOURCE_DIGEST=$runner_source_digest"
  --build-arg "SOURCE_REVISION=$source_revision"
  --build-arg "SOURCE_DATE_EPOCH=$source_date_epoch"
  --build-arg "LOCK_DIGEST=$lock_digest"
  --build-arg "CREATED=$created"
)

case $family in
  ubuntu)
    snapshot_url=$(jq -r '.package_repositories[0].metadata.amd64.url' "$absolute_lock")
    ubuntu_snapshot=${snapshot_url#*snapshot.ubuntu.com/ubuntu/}
    ubuntu_snapshot=${ubuntu_snapshot%%/*}
    [[ $ubuntu_snapshot =~ ^[0-9]{8}T[0-9]{6}Z$ ]] ||
      die "could not resolve Ubuntu snapshot ID from lock: $snapshot_url"
    build_arguments+=(
      --build-arg "COMMON_PACKAGES=$common_packages"
      --build-arg "UBUNTU_SNAPSHOT=$ubuntu_snapshot"
    )
    ;;
  almalinux)
    epel_release_package=$(jq -r --arg architecture "$architecture" \
      '.packages[$architecture][] | select(startswith("epel-release-"))' "$absolute_lock")
    epel_packages=$(jq -r --arg architecture "$architecture" \
      '[.packages[$architecture][] | select(startswith("ripgrep-"))] | join(" ")' "$absolute_lock")
    common_packages=$(jq -r --arg architecture "$architecture" \
      '[.packages[$architecture][] | select((startswith("epel-release-") or startswith("ripgrep-")) | not)] | join(" ")' \
      "$absolute_lock")
    build_arguments+=(
      --build-arg "COMMON_PACKAGES=$common_packages"
      --build-arg "EPEL_RELEASE_PACKAGE=$epel_release_package"
      --build-arg "EPEL_PACKAGES=$epel_packages"
    )
    ;;
  *)
    die "unsupported distribution family: $family"
    ;;
esac

run_podman build "${build_arguments[@]}" "$REPOSITORY_ROOT"
image_digest=$(run_podman image inspect --format '{{.Id}}' "$image_reference")
build_root=$(ensure_build_root)
report_directory="$build_root/reports"
mkdir -p -- "$report_directory"
jq -n \
  --arg image_id "$image_id" \
  --arg architecture "$architecture" \
  --arg image_reference "$image_reference" \
  --arg image_digest "$image_digest" \
  --arg source_revision "$source_revision" \
  --arg runner_source_digest "$runner_source_digest" \
  --arg base_image "$base_image" \
  '{
    schema_version: 1,
    image_id: $image_id,
    architecture: $architecture,
    image_reference: $image_reference,
    local_image_digest: $image_digest,
    source_revision: $source_revision,
    runner_source_digest: $runner_source_digest,
    base_image: $base_image
  }' > "$report_directory/$image_id-$architecture-build.json"

printf '%s\n' "$image_reference"
