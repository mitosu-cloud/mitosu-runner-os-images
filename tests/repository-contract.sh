#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPOSITORY_ROOT=$(cd -- "$TEST_DIR/.." && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$REPOSITORY_ROOT/scripts/lib/common.sh"

require_command jq
test_staging=$(make_private_temp_dir contract-test)
trap 'rm -rf -- "$test_staging"' EXIT
matrix="$REPOSITORY_ROOT/locks/image-matrix.json"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

expect_invalid() {
  local name=$1
  local filter=$2
  local candidate="$test_staging/$name.json"

  jq "$filter" "$matrix" >"$candidate"
  if "$REPOSITORY_ROOT/scripts/validate-locks.sh" --matrix "$candidate" \
      >"$test_staging/$name.stdout" 2>"$test_staging/$name.stderr"; then
    fail "$name was accepted"
  fi
  pass "$name is rejected"
}

"$REPOSITORY_ROOT/scripts/validate-locks.sh" >/dev/null
pass 'checked-in matrix validates'

validate_json_schema \
  "$REPOSITORY_ROOT/schemas/image-marker.schema.json" \
  "$REPOSITORY_ROOT/tests/common/image-marker.valid.json"
validate_json_schema \
  "$REPOSITORY_ROOT/schemas/image-set.schema.json" \
  "$REPOSITORY_ROOT/tests/common/image-set.valid.json"
pass 'marker and release-manifest fixtures validate'

invalid_marker="$test_staging/invalid-marker.json"
jq '.tool_user.uid = 0' "$REPOSITORY_ROOT/tests/common/image-marker.valid.json" >"$invalid_marker"
if validate_json_schema "$REPOSITORY_ROOT/schemas/image-marker.schema.json" "$invalid_marker" \
    >"$test_staging/invalid-marker.stdout" 2>"$test_staging/invalid-marker.stderr"; then
  fail 'marker schema accepted root as the tool user'
fi
pass 'marker schema rejects a changed tool-user contract'

resolved="$test_staging/resolved.json"
"$REPOSITORY_ROOT/scripts/resolve-matrix.sh" --output "$resolved" >/dev/null
validate_json_schema "$REPOSITORY_ROOT/schemas/resolved-matrix.schema.json" "$resolved"

[[ $(jq '.entries | length' "$resolved") == 16 ]] || fail 'resolved matrix does not contain 16 entries'
jq -e '.entries | group_by([.image_id, .architecture]) | all(length == 1)' "$resolved" >/dev/null ||
  fail 'resolved image/architecture tuples are not unique'

expected_ids='["almalinux-10-cpp","almalinux-10-go","almalinux-10-node","almalinux-10-rust","ubuntu-26.04-cpp","ubuntu-26.04-go","ubuntu-26.04-node","ubuntu-26.04-rust"]'
jq -e --argjson expected "$expected_ids" \
  '[.entries[].image_id] | unique == $expected' "$resolved" >/dev/null ||
  fail 'resolved matrix does not contain the required eight image IDs'
pass 'eight images resolve for amd64 and arm64'

expect_invalid unknown_field '.unexpected = true'
expect_invalid unknown_architecture '.architectures += ["ppc64le"]'
expect_invalid duplicate_distribution '.distributions += [.distributions[0]]'
expect_invalid duplicate_profile '.profiles += [.profiles[0]]'
expect_invalid duplicate_image '.images += [.images[0]]'
expect_invalid unknown_distribution_reference '.images[0].distribution = "missing-1"'
expect_invalid unknown_profile_reference '.images[0].profile = "missing"'
expect_invalid mismatched_image_id '.images[0].id = "ubuntu-26.04-wrong"'

synthetic="$test_staging/synthetic.json"
jq '
  .profiles += [{
    id: "synthetic",
    revision: 1,
    capabilities: ["shell"],
    toolchain_lock: null,
    suggested_runtime_egress: []
  }] |
  .images += [
    {id: "ubuntu-26.04-synthetic", distribution: "ubuntu-26.04", profile: "synthetic"},
    {id: "almalinux-10-synthetic", distribution: "almalinux-10", profile: "synthetic"}
  ]
' "$matrix" >"$synthetic"
"$REPOSITORY_ROOT/scripts/validate-locks.sh" --matrix "$synthetic" >/dev/null
synthetic_resolved="$test_staging/synthetic-resolved.json"
"$REPOSITORY_ROOT/scripts/resolve-matrix.sh" \
  --matrix "$synthetic" --output "$synthetic_resolved" >/dev/null
[[ $(jq '.entries | length' "$synthetic_resolved") == 20 ]] ||
  fail 'synthetic profile did not resolve through data-only matrix changes'
pass 'a synthetic profile resolves through one matrix data change'

if "$REPOSITORY_ROOT/scripts/validate-locks.sh" --build-ready \
    >"$test_staging/build-ready.stdout" 2>"$test_staging/build-ready.stderr"; then
  fail 'pending input locks were accepted as build-ready'
fi
pass 'pending locks cannot be used as build inputs'
