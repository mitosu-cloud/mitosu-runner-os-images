#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

matrix_path="$REPOSITORY_ROOT/locks/image-matrix.json"
build_ready=false

usage() {
  cat <<'EOF'
Usage: scripts/validate-locks.sh [--matrix PATH] [--build-ready]

Validate JSON Schemas, matrix cross-references, and every referenced lock.
--build-ready additionally rejects any pending input lock.
EOF
}

while (($# > 0)); do
  case $1 in
    --matrix)
      (($# >= 2)) || die '--matrix requires a path'
      matrix_path=$2
      shift 2
      ;;
    --build-ready)
      build_ready=true
      shift
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

require_command jq
[[ -f $matrix_path ]] || die "matrix does not exist: $matrix_path"

for schema_path in "$REPOSITORY_ROOT"/schemas/*.schema.json; do
  jq -e . "$schema_path" >/dev/null
done

validate_json_schema \
  "$REPOSITORY_ROOT/schemas/image-matrix.schema.json" \
  "$matrix_path"

unique_ids() {
  local collection=$1
  jq -e --arg collection "$collection" \
    '(.[$collection] | map(.id) | length) == (.[$collection] | map(.id) | unique | length)' \
    "$matrix_path" >/dev/null || die "duplicate ID in matrix collection: $collection"
}

unique_ids distributions
unique_ids profiles
unique_ids images

jq -e '
  . as $matrix |
  all($matrix.distributions[]; .id == ("\(.family)-\(.version)")) and
  all($matrix.distributions[]; .containerfile == ("images/\(.family)/Containerfile")) and
  all($matrix.images[];
    . as $image |
    any($matrix.distributions[]; .id == $image.distribution) and
    any($matrix.profiles[]; .id == $image.profile) and
    $image.id == ("\($image.distribution)-\($image.profile)"))
' "$matrix_path" >/dev/null ||
  die 'matrix contains a mismatched ID, Containerfile, distribution, or profile reference'

runner_lock=$(jq -r '.runner_lock' "$matrix_path")
runner_path="$REPOSITORY_ROOT/$runner_lock"
[[ -f $runner_path ]] || die "referenced runner lock does not exist: $runner_lock"
validate_json_schema "$REPOSITORY_ROOT/schemas/runner-lock.schema.json" "$runner_path"

if [[ $build_ready == true ]] && [[ $(jq -r '.status' "$runner_path") != locked ]]; then
  die "runner lock is not build-ready: $runner_lock"
fi

while IFS=$'\t' read -r distribution_id family version lock_path; do
  absolute_lock="$REPOSITORY_ROOT/$lock_path"
  [[ -f $absolute_lock ]] || die "referenced OS lock does not exist: $lock_path"
  validate_json_schema "$REPOSITORY_ROOT/schemas/os-lock.schema.json" "$absolute_lock"
  jq -e \
    --arg id "$distribution_id" \
    --arg family "$family" \
    --arg version "$version" \
    '.id == $id and .distribution == $family and .distribution_version == $version' \
    "$absolute_lock" >/dev/null || die "OS lock identity does not match matrix: $lock_path"
  if [[ $build_ready == true ]] && [[ $(jq -r '.status' "$absolute_lock") != locked ]]; then
    die "OS lock is not build-ready: $lock_path"
  fi
done < <(jq -r '.distributions[] | [.id, .family, .version, .os_lock] | @tsv' "$matrix_path")

while IFS=$'\t' read -r profile_id lock_path; do
  [[ $lock_path != null ]] || continue
  absolute_lock="$REPOSITORY_ROOT/$lock_path"
  [[ -f $absolute_lock ]] || die "referenced toolchain lock does not exist: $lock_path"
  validate_json_schema "$REPOSITORY_ROOT/schemas/toolchain-lock.schema.json" "$absolute_lock"
  jq -e --arg profile "$profile_id" '.profile == $profile' "$absolute_lock" >/dev/null ||
    die "toolchain lock profile does not match matrix: $lock_path"
  if [[ $build_ready == true ]] && [[ $(jq -r '.status' "$absolute_lock") != locked ]]; then
    die "toolchain lock is not build-ready: $lock_path"
  fi
done < <(jq -r '.profiles[] | [.id, (.toolchain_lock // "null")] | @tsv' "$matrix_path")

if [[ $build_ready == true ]] && jq -e '.profiles[] | select(.toolchain_lock == null)' "$matrix_path" >/dev/null; then
  die 'a profile without a toolchain lock is not build-ready'
fi

printf 'validated matrix and referenced locks: %s\n' "$matrix_path"
