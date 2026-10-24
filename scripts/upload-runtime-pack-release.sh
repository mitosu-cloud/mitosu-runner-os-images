#!/usr/bin/env bash
# Upload a reviewed release directory sequentially over explicit HTTP/1.1.
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

(($# == 3)) || die 'usage: upload-runtime-pack-release.sh OWNER/REPOSITORY RELEASE-ID RELEASE-DIRECTORY'
repository=$1
release_id=$2
release_dir=${3%/}

[[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'invalid GitHub repository'
[[ $release_id =~ ^[1-9][0-9]{0,19}$ ]] || die 'invalid GitHub release ID'
[[ $release_dir == /* && -d $release_dir && ! -L $release_dir ]] ||
  die 'release directory must be an absolute, non-symlink directory'
test "$(realpath -e -- "$release_dir")" = "$release_dir" ||
  die 'release directory must use its canonical path'
[[ -n ${GH_TOKEN:-} && $GH_TOKEN != *$'\n'* ]] || die 'GH_TOKEN is required and must be one line'

require_command curl
require_command gh
require_command jq
require_command realpath

staging=$(mktemp -d -- /tmp/mitosu-release-upload.XXXXXXXX)
curl_config="$staging/curl.conf"
response="$staging/response.json"
cleanup() {
  rm -rf -- "$staging"
}
trap cleanup EXIT
{
  printf 'header = "Accept: application/vnd.github+json"\n'
  printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN"
  printf 'header = "X-GitHub-Api-Version: 2022-11-28"\n'
} > "$curl_config"

existing_count=$(gh api "repos/$repository/releases/$release_id/assets" --paginate \
  --jq '. | length' | awk '{total += $1} END {print total + 0}')
test "$existing_count" -eq 0 || die 'release must not contain assets before upload'

entry_count=$(find "$release_dir" -mindepth 1 -maxdepth 1 -printf . | wc -c)
mapfile -d '' assets < <(
  find "$release_dir" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z
)
((entry_count > 0 && entry_count == ${#assets[@]})) ||
  die 'release directory must contain only regular files'

for asset in "${assets[@]}"; do
  [[ -f $asset && ! -L $asset ]] || die "unsafe release asset: $asset"
  name=${asset##*/}
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,191}$ ]] || die "unsafe release asset name: $name"
  expected_size=$(stat -c %s -- "$asset")
  expected_digest="sha256:$(sha256_file "$asset")"
  ((expected_size > 0 && expected_size < 2147483648)) ||
    die "release asset has unsafe size: $name"
  upload_url="https://uploads.github.com/repos/$repository/releases/$release_id/assets?name=$name"
  printf 'uploading %s (%s bytes) over HTTP/1.1\n' "$name" "$expected_size"
  : > "$response"
  if ! curl --config "$curl_config" \
      --http1.1 --fail-with-body --silent --show-error \
      --connect-timeout 30 --max-time 3600 \
      --speed-limit 32768 --speed-time 120 \
      --header 'Content-Type: application/octet-stream' \
      --request POST --data-binary "@$asset" \
      --output "$response" "$upload_url"; then
    while IFS=$'\t' read -r asset_id server_name state; do
      if [[ $server_name == "$name" && $state == starter ]]; then
        gh api --method DELETE "repos/$repository/releases/assets/$asset_id"
      fi
    done < <(
      gh api "repos/$repository/releases/$release_id/assets" --paginate \
        --jq '.[] | [.id, .name, .state] | @tsv'
    )
    die "HTTP/1.1 upload failed: $name"
  fi
  server_name=$(jq -er '.name' "$response")
  server_state=$(jq -er '.state' "$response")
  server_size=$(jq -er '.size' "$response")
  server_digest=$(jq -er '.digest' "$response")
  test "$server_name" = "$name" || die "uploaded asset name mismatch: $name"
  test "$server_state" = uploaded || die "uploaded asset is not complete: $name"
  test "$server_size" = "$expected_size" || die "uploaded asset size mismatch: $name"
  test "$server_digest" = "$expected_digest" || die "uploaded asset digest mismatch: $name"
  printf 'verified %s as %s\n' "$name" "$server_digest"
done
