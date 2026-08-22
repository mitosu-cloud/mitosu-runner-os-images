#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPOSITORY_ROOT=$(cd -- "$TEST_DIR/.." && pwd -P)
COMMON_LIBRARY="$REPOSITORY_ROOT/scripts/lib/common.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

probe_build_root() {
  local requested=$1

  MITOSU_BUILD_ROOT=$requested bash -c \
    'source "$1"; mitosu_build_root' _ "$COMMON_LIBRARY"
}

accepted=$(probe_build_root /tmp/mitosu-runner-os-images-contract)
[[ $accepted == /tmp/mitosu-runner-os-images-contract ]] ||
  fail 'a dedicated /tmp build root was not retained'
pass 'build root accepts a dedicated directory beneath /tmp'

if probe_build_root /tmp > /dev/null 2>&1; then
  fail 'the shared /tmp root was accepted as a build root'
fi
pass 'build root rejects the shared /tmp root'

if probe_build_root /var/tmp/mitosu-runner-os-images > /dev/null 2>&1; then
  fail 'a build root outside /tmp was accepted'
fi
pass 'build root rejects storage outside /tmp'

if probe_build_root "$REPOSITORY_ROOT/.cache/build" > /dev/null 2>&1; then
  fail 'a checkout-local build root was accepted'
fi
pass 'build root rejects checkout-local storage'
