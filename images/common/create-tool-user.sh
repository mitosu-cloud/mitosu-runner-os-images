#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

existing_group=$(getent group 1000 | cut -d: -f1 || true)
if [[ -z $existing_group ]]; then
  groupadd --gid 1000 mitosu
elif [[ $existing_group != mitosu ]]; then
  groupmod --new-name mitosu "$existing_group"
fi

existing_user=$(getent passwd 1000 | cut -d: -f1 || true)
if [[ -z $existing_user ]]; then
  useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash mitosu
elif [[ $existing_user != mitosu ]]; then
  usermod --login mitosu --home /home/mitosu --move-home --shell /bin/bash "$existing_user"
fi

test "$(id -u mitosu)" = 1000
test "$(id -g mitosu)" = 1000
install -d -m 0750 -o 1000 -g 1000 /home/mitosu
