#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

marker=/usr/share/mitosu/image.json
test -r "$marker"
test "$(jq -r '.schema_version' "$marker")" = 1
test "$(jq -r '.development_profile' "$marker")" = common
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

for writable_path in \
  /home/mitosu \
  /workspace/project \
  /var/lib/mitosu/apps \
  /var/cache/mitosu/common \
  /tmp; do
  mkdir -p "$writable_path"
  touch "$writable_path/.mitosu-write-test"
  rm -f "$writable_path/.mitosu-write-test"
done

test ! -w /usr
test ! -w /etc
printf 'common smoke checks passed\n'
