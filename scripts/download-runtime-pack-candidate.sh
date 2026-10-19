#!/usr/bin/env bash
# Keep an unsigned candidate on GitHub without publishing a permanent release.
set -euo pipefail
IFS=$'\n\t'
umask 077
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

(($# == 2)) || die 'usage: download-runtime-pack-candidate.sh HTTPS-URL OUTPUT'
url=$1
output=$2
[[ $url == https://* && $url != *\?* && $url != *\#* ]] || die 'candidate URL must use HTTPS without query or fragment'
authority=${url#https://}
authority=${authority%%/*}
[[ -n $authority && $authority != *@* ]] || die 'candidate URL must not contain credentials'
[[ $output == /* && ! -e $output && ! -L $output ]] || die 'candidate output must be a new absolute path'
repository=${GITHUB_REPOSITORY:-mitosu-cloud/mitosu-runner-os-images}
prefix="https://api.github.com/repos/$repository/releases/assets/"
complete=false
cleanup() {
  if [[ $complete != true ]]; then rm -f -- "$output"; fi
}
trap cleanup EXIT
if [[ $url == "$prefix"* ]]; then
  asset_id=${url#"$prefix"}
  [[ $asset_id =~ ^[0-9]+$ ]] || die 'invalid GitHub candidate asset ID'
  require_command gh
  # gh obtains GH_TOKEN internally; no credential enters argv or another host.
  expected_size=$(gh api "repos/$repository/releases/assets/$asset_id" --jq .size)
  [[ $expected_size =~ ^[0-9]+$ ]] || die 'invalid GitHub candidate size'
  ((expected_size > 0 && expected_size < 2147483648)) || die 'GitHub candidate asset must be below 2 GiB'
  gh api "repos/$repository/releases/assets/$asset_id" \
    --header 'Accept: application/octet-stream' >"$output"
  actual_size=$(wc -c <"$output")
  actual_size=${actual_size//[[:space:]]/}
  [[ $actual_size == "$expected_size" ]] || die 'GitHub candidate size mismatch'
else
  require_command curl
  curl --fail --location --max-redirs 3 --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --max-filesize 34360786944 --output "$output" "$url"
fi
complete=true
