#!/usr/bin/env bash

if [[ -n ${MITOSU_PODMAN_SH_LOADED:-} ]]; then
  return 0
fi
readonly MITOSU_PODMAN_SH_LOADED=1

# shellcheck source=scripts/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

run_podman() {
  local build_root
  local podman_root
  local podman_runroot
  local podman_tmp

  require_command podman
  build_root=$(ensure_build_root)
  podman_root="$build_root/podman/root"
  podman_runroot="$build_root/podman/run"
  podman_tmp="$build_root/podman/tmp"
  mkdir -p -- "$podman_root" "$podman_runroot" "$podman_tmp"
  chmod 700 -- "$podman_root" "$podman_runroot" "$podman_tmp"

  TMPDIR="$podman_tmp" XDG_RUNTIME_DIR="$podman_runroot" command podman \
    --root "$podman_root" \
    --runroot "$podman_runroot" \
    --tmpdir "$podman_tmp" \
    --storage-driver overlay \
    --cgroup-manager=cgroupfs \
    --events-backend=file \
    "$@"
}

host_oci_architecture() {
  case $(uname -m) in
    x86_64)
      printf 'amd64\n'
      ;;
    aarch64|arm64)
      printf 'arm64\n'
      ;;
    *)
      die "unsupported host architecture: $(uname -m)"
      ;;
  esac
}
