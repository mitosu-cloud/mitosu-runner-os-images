#!/usr/bin/env bash

if [[ -n ${MITOSU_COMMON_SH_LOADED:-} ]]; then
  return 0
fi
readonly MITOSU_COMMON_SH_LOADED=1

REPOSITORY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPOSITORY_ROOT
readonly DEFAULT_MITOSU_BUILD_ROOT="/tmp/mitosu-runner-os-images"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name=$1
  command -v -- "$command_name" >/dev/null 2>&1 ||
    die "required command not found: $command_name"
}

sha256_file() {
  local path=$1

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$path" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$path" | awk '{print $1}'
    return
  fi
  die 'sha256sum or shasum is required'
}

mitosu_build_root() {
  local requested=${MITOSU_BUILD_ROOT:-$DEFAULT_MITOSU_BUILD_ROOT}
  local normalized

  [[ $requested == /* ]] || die 'MITOSU_BUILD_ROOT must be an absolute path'
  require_command realpath
  normalized=$(realpath -m -- "$requested")

  [[ $normalized != / ]] || die 'MITOSU_BUILD_ROOT must not be the filesystem root'
  case "$normalized/" in
    "$REPOSITORY_ROOT/"*)
      die 'MITOSU_BUILD_ROOT must be outside the source checkout'
      ;;
  esac

  requested=${requested%/}
  printf '%s\n' "$requested"
}

ensure_build_root() {
  local build_root
  build_root=$(mitosu_build_root)
  mkdir -p -- "$build_root"
  chmod 700 -- "$build_root"
  printf '%s\n' "$build_root"
}

make_private_temp_dir() {
  local prefix=${1:-staging}
  local build_root

  [[ $prefix =~ ^[a-zA-Z0-9._-]+$ ]] || die "unsafe temporary prefix: $prefix"
  build_root=$(ensure_build_root)
  mktemp -d -- "$build_root/$prefix.XXXXXXXX"
}

validate_json_schema() {
  local schema=$1
  local instance=$2

  require_command jsonschema
  jsonschema -i "$instance" "$schema"
}
