#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

build_root=$(mitosu_build_root)
if [[ ! -e $build_root ]]; then
  printf 'build root does not exist: %s\n' "$build_root"
  exit 0
fi

case "$build_root" in
  /tmp/mitosu-runner-os-images|/tmp/mitosu-runner-os-images/*)
    ;;
  *)
    if [[ ${MITOSU_CONFIRM_CLEAN:-} != "$build_root" ]]; then
      die "refusing to clean custom build root without MITOSU_CONFIRM_CLEAN=$build_root"
    fi
    ;;
esac

rm -rf -- "$build_root"
printf 'removed build root: %s\n' "$build_root"
