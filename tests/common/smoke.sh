#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

marker=/usr/share/mitosu/image.json
test -r "$marker"
test "$(jq -r '.schema_version' "$marker")" = 1
profile=$(jq -r '.development_profile' "$marker")
test "$profile" = "${EXPECTED_PROFILE:-common}"
test "$(jq -r '.runner_protocol' "$marker")" = mitosu.runner.v1
test "$(jq -r '.tool_user.name' "$marker")" = mitosu
test "$(jq -r '.tool_user.uid' "$marker")" = 1000
test "$(jq -r '.tool_user.gid' "$marker")" = 1000

case $(uname -m) in
  x86_64) running_architecture=amd64 ;;
  aarch64|arm64) running_architecture=arm64 ;;
  *) printf 'unsupported running architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac
test "$(jq -r '.architecture' "$marker")" = "$running_architecture"

test "$(id -u)" = 1000
test "$(id -g)" = 1000
test "$(id -un)" = mitosu
test "$HOME" = /home/mitosu
test "$(locale charmap)" = UTF-8

for command_name in bash git ssh curl tar gzip bzip2 xz unzip file find patch diff jq rg ps ip ping lsof; do
  command -v "$command_name" >/dev/null
done

if test -f /etc/debian_version; then
  test -s /etc/ssl/certs/ca-certificates.crt
else
  test -d /etc/pki/ca-trust/extracted
fi

for forbidden_command in sudo sshd docker podman kubectl; do
  if command -v "$forbidden_command" >/dev/null 2>&1; then
    printf 'forbidden command is installed: %s\n' "$forbidden_command" >&2
    exit 1
  fi
done

for proxy_name in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
  test -z "${!proxy_name:-}"
done

test ! -S /var/run/docker.sock
test ! -e /root/.ssh/id_rsa
test ! -e /root/.config/gcloud

if [[ $profile == common ]]; then
  writable_paths=(/home/mitosu /workspace/project /var/lib/mitosu/apps /var/cache/mitosu/common /tmp)
else
  writable_paths=(
    /home/mitosu
    /mitosu/workspace/project
    /mitosu/home
    /mitosu/scratch
    "/var/lib/mitosu/apps/$profile"
    "/var/cache/mitosu/$profile"
    /tmp
  )
  test "$PWD" = /mitosu/workspace
  test ! -e /.openshell
fi

for writable_path in "${writable_paths[@]}"; do
  mkdir -p "$writable_path"
  touch "$writable_path/.mitosu-write-test"
  rm -f "$writable_path/.mitosu-write-test"
done

case $profile in
  common) ;;
  node)
    test "$(node --version)" = v22.22.1
    test "$(npm --version)" = 10.9.4
    test "$(corepack --version)" = 0.34.6
    command -v cc >/dev/null
    command -v c++ >/dev/null
    ;;
  python)
    test "$(python3 --version)" = 'Python 3.14.4'
    test "$(uv --version)" = 'uv 0.10.8'
    command -v uvx >/dev/null
    command -v cc >/dev/null
    ;;
  *)
    printf 'unsupported smoke profile: %s\n' "$profile" >&2
    exit 1
    ;;
esac

test ! -w /usr
test ! -w /etc
printf 'common smoke checks passed\n'
