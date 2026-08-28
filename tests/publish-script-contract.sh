#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPOSITORY_ROOT=$(cd -- "$TEST_DIR/.." && pwd -P)

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

staging=$(mktemp -d -- /tmp/mitosu-runner-os-images-publish-contract.XXXXXXXX)
trap 'rm -rf -- "$staging"' EXIT

plan=$("$REPOSITORY_ROOT/scripts/build-and-push-images.sh" \
  --tag contract-test \
  --dry-run)
[[ $(jq -r '.repository' <<<"$plan") == ghcr.io/mitosu-cloud/runner-os ]] ||
  fail 'dry-run plan returned the wrong registry repository'
[[ $(jq -r '.images | length' <<<"$plan") -eq 2 ]] ||
  fail 'dry-run plan did not include every current common image'
[[ $(jq -r '.images | sort | join(" ")' <<<"$plan") == \
    'almalinux-10-common ubuntu-26.04-common' ]] ||
  fail 'dry-run plan returned unexpected image IDs'
[[ $(jq -r '.architectures | length' <<<"$plan") -eq 1 ]] ||
  fail 'dry-run plan did not default to one native architecture'
pass 'GHCR publication dry run resolves every current image'

selected_plan=$("$REPOSITORY_ROOT/scripts/build-and-push-images.sh" \
  --tag contract-test-selected \
  --distribution almalinux-10 \
  --architecture arm64 \
  --allow-emulated \
  --dry-run)
[[ $(jq -r '.images | join(" ")' <<<"$selected_plan") == almalinux-10-common ]] ||
  fail 'dry-run distribution selector returned an unexpected image'
[[ $(jq -r '.architectures | join(" ")' <<<"$selected_plan") == arm64 ]] ||
  fail 'dry-run architecture selector returned an unexpected architecture'
pass 'GHCR publication dry run selects one distribution and architecture'

if "$REPOSITORY_ROOT/scripts/build-and-push-images.sh" \
    --tag contract-test-unknown \
    --distribution missing-1 \
    --dry-run \
    >"$staging/unknown-distribution.stdout" 2>"$staging/unknown-distribution.stderr"; then
  fail 'publication script accepted an unknown distribution'
fi
grep -Fq 'unknown distribution: missing-1' "$staging/unknown-distribution.stderr" ||
  fail 'publication script did not explain the unknown distribution'
pass 'GHCR publication rejects unknown distributions'

if "$REPOSITORY_ROOT/scripts/build-and-push-images.sh" \
    --tag Invalid \
    --dry-run \
    >"$staging/invalid.stdout" 2>"$staging/invalid.stderr"; then
  fail 'publication script accepted an unsafe release tag'
fi
grep -Fq -- '--tag must be' "$staging/invalid.stderr" ||
  fail 'publication script did not explain the rejected release tag'
pass 'GHCR publication rejects unsafe release tags'
