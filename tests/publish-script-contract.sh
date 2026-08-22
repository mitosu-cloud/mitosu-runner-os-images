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

if "$REPOSITORY_ROOT/scripts/build-and-push-images.sh" \
    --tag Invalid \
    --dry-run \
    >"$staging/invalid.stdout" 2>"$staging/invalid.stderr"; then
  fail 'publication script accepted an unsafe release tag'
fi
rg --fixed-strings --quiet -- '--tag must be' "$staging/invalid.stderr" ||
  fail 'publication script did not explain the rejected release tag'
pass 'GHCR publication rejects unsafe release tags'
