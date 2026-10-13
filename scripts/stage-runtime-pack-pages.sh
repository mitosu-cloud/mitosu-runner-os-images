#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
usage: stage-runtime-pack-pages.sh \
  --site-dir DIRECTORY \
  --current-pack DIRECTORY \
  --prior-releases-dir DIRECTORY \
  --public-key LOWERCASE-HEX

Builds a complete GitHub Pages tree from the current signed runtime pack and
previous immutable-release archives. Each previous release directory must be
named runtime-pack-PACK_ID and contain that name plus .tar.gz and SHA256SUMS.
EOF
}

site_dir=
current_pack=
prior_releases_dir=
public_key=

while (($# > 0)); do
  case "$1" in
    --site-dir)
      (($# >= 2)) || die '--site-dir requires a value'
      site_dir=$2
      shift 2
      ;;
    --current-pack)
      (($# >= 2)) || die '--current-pack requires a value'
      current_pack=$2
      shift 2
      ;;
    --prior-releases-dir)
      (($# >= 2)) || die '--prior-releases-dir requires a value'
      prior_releases_dir=$2
      shift 2
      ;;
    --public-key)
      (($# >= 2)) || die '--public-key requires a value'
      public_key=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_command jq
require_command realpath
[[ -n $site_dir ]] || die '--site-dir is required'
[[ -n $current_pack ]] || die '--current-pack is required'
[[ -n $prior_releases_dir ]] || die '--prior-releases-dir is required'
[[ $public_key =~ ^[a-f0-9]{64}$ ]] || die '--public-key must be 32-byte lowercase hexadecimal'

current_pack=$(realpath -e -- "$current_pack")
prior_releases_dir=$(realpath -e -- "$prior_releases_dir")
[[ -d $current_pack && ! -L $current_pack ]] || die '--current-pack must be a non-symlink directory'
[[ -d $prior_releases_dir && ! -L $prior_releases_dir ]] ||
  die '--prior-releases-dir must be a non-symlink directory'
[[ ! -e $site_dir ]] || die '--site-dir must not already exist'
mkdir -p -- "$site_dir/runtime-packs"
site_dir=$(realpath -e -- "$site_dir")

staging=$(make_private_temp_dir runtime-pack-pages)
trap 'rm -rf -- "$staging"' EXIT

stage_pack() {
  local pack=$1
  local expected_pack_id=$2
  local pack_id source_url destination

  "$SCRIPT_DIR/verify-runtime-pack.sh" \
    --pack-dir "$pack" --public-key "$public_key" >/dev/null
  pack_id=$(jq -er '.pack_id' "$pack/manifest.json")
  [[ $pack_id == "$expected_pack_id" ]] ||
    die "runtime-pack archive identity mismatch: expected $expected_pack_id, found $pack_id"
  source_url=$(jq -er '.source.base_url' "$pack/release-handoff.json")
  [[ $source_url == "https://mitosu-cloud.github.io/mitosu-runner-os-images/runtime-packs/$pack_id/" ]] ||
    die "runtime-pack source URL is not canonical: $pack_id"
  destination="$site_dir/runtime-packs/$pack_id"
  [[ ! -e $destination ]] || die "duplicate runtime pack while staging Pages: $pack_id"
  mkdir -- "$destination"
  cp -a -- "$pack/." "$destination/"
}

while IFS= read -r release_dir; do
  release_name=${release_dir##*/}
  [[ $release_name == runtime-pack-* ]] || die "invalid prior release directory: $release_name"
  pack_id=${release_name#runtime-pack-}
  [[ $pack_id =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || die "invalid prior pack ID: $pack_id"
  archive="$release_dir/$release_name.tar.gz"
  sums="$release_dir/SHA256SUMS"
  [[ -f $archive && ! -L $archive ]] || die "prior release archive is missing or unsafe: $release_name"
  [[ -f $sums && ! -L $sums ]] || die "prior release checksums are missing or unsafe: $release_name"
  expected_sha=$(awk -v name="$release_name.tar.gz" '$2 == name { print $1 }' "$sums")
  [[ $expected_sha =~ ^[a-f0-9]{64}$ ]] || die "prior release archive checksum is missing or ambiguous: $release_name"
  [[ $(sha256_file "$archive") == "$expected_sha" ]] || die "prior release archive checksum changed: $release_name"
  extracted="$staging/$release_name"
  "$SCRIPT_DIR/extract-runtime-pack-candidate.py" "$archive" "$extracted"
  stage_pack "$extracted/pack" "$pack_id"
done < <(find "$prior_releases_dir" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort)

current_pack_id=$(jq -er '.pack_id' "$current_pack/manifest.json")
stage_pack "$current_pack" "$current_pack_id"
find "$site_dir" -type d -exec chmod 0755 {} +
find "$site_dir" -type f -exec chmod 0444 {} +
printf '{"status":"staged","current_pack_id":"%s","pack_count":%s}\n' \
  "$current_pack_id" "$(find "$site_dir/runtime-packs" -mindepth 1 -maxdepth 1 -type d | wc -l)"
