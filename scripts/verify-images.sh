#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

if (($# == 0)); then
  printf 'usage: %s --image IMAGE\n' "$0" >&2
  exit 2
fi

exec "$SCRIPT_DIR/smoke-images.sh" "$@"
