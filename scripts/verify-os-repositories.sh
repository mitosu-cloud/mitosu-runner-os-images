#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

distribution_id=
architecture=

usage() {
  cat <<'EOF'
Usage: scripts/verify-os-repositories.sh --distribution ID --architecture ARCH

Download every locked repository metadata file into private staging under
MITOSU_BUILD_ROOT and fail unless its SHA-256 matches the OS lock.
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
  '') die '--architecture is required' ;;
  *) die "unsupported architecture: $architecture" ;;
esac

require_command curl
require_command jq
"$SCRIPT_DIR/validate-locks.sh" >/dev/null

lock_path=$(jq -r --arg id "$distribution_id" \
  '.distributions[] | select(.id == $id) | .os_lock' \
  "$REPOSITORY_ROOT/locks/image-matrix.json")
[[ -n $lock_path ]] || die "unknown distribution: $distribution_id"
absolute_lock="$REPOSITORY_ROOT/$lock_path"
[[ $(jq -r '.status' "$absolute_lock") == locked ]] ||
  die "OS lock is not build-ready: $lock_path"

staging_directory=$(make_private_temp_dir repository-metadata)
trap 'rm -rf -- "$staging_directory"' EXIT

while IFS=$'\t' read -r repository_id url expected_sha256; do
  output="$staging_directory/$repository_id.metadata"
  curl --fail --silent --show-error --location --output "$output" "$url"
  actual_sha256=$(sha256_file "$output")
  [[ $actual_sha256 == "$expected_sha256" ]] ||
    die "repository metadata changed for $repository_id: expected $expected_sha256, got $actual_sha256"
  printf 'verified %s %s metadata: %s\n' "$distribution_id" "$repository_id" "$expected_sha256"
done < <(jq -r --arg architecture "$architecture" \
  '.package_repositories[] | [.id, .metadata[$architecture].url, .metadata[$architecture].sha256] | @tsv' \
  "$absolute_lock")
