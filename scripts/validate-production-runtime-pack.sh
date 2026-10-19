#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

pack_dir=
github_release=false
while (($# > 0)); do
  case "$1" in
    --github-release)
      github_release=true
      shift
      ;;
    --pack-dir)
      (($# >= 2)) || die '--pack-dir requires a value'
      pack_dir=$2
      shift 2
      ;;
    -h | --help)
      printf 'usage: validate-production-runtime-pack.sh --pack-dir DIRECTORY [--github-release]\n'
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n $pack_dir ]] || die '--pack-dir is required'
pack_dir=$(realpath -e -- "$pack_dir")
"$SCRIPT_DIR/verify-runtime-pack-candidate.sh" --pack-dir "$pack_dir" >/dev/null
manifest="$pack_dir/manifest.json"

[[ $(jq -er '.schema_version' "$manifest") =~ ^[23]$ ]] ||
  die 'production OpenShell runtime packs must use schema version 2 or 3'
if [[ $github_release == true ]]; then
  jq -e '.schema_version == 3 and all(.artifacts[];
    .transport.compression == "zstd" and (.transport.path | contains("/") | not)
    and .transport.size < 2147483648)' "$manifest" >/dev/null ||
    die 'GitHub Release packs require schema 3, flat zstd transport paths, and assets under 2 GiB'
fi
[[ $(jq '[.artifacts[] | select(.name == "openshell_driver_vm" and .executable == true)] | length' "$manifest") -eq 1 ]] ||
  die 'production runtime pack must contain one executable openshell_driver_vm artifact'
for image_name in openshell_supervisor_image openshell_sandbox_runtime_image; do
  [[ $(jq --arg name "$image_name" '[.oci_images[] | select(.name == $name and .attestation == null)] | length' "$manifest") -eq 1 ]] ||
    die "production runtime pack must contain one unattested $image_name entry"
done

target_arch=$(jq -er '.target_arch' "$manifest")
guest_target="linux_$target_arch"
for image_id in ubuntu-26.04-node ubuntu-26.04-python; do
  [[ $(jq --arg image_id "$image_id" --arg guest_target "$guest_target" '
      [.oci_images[]
       | select(.attestation.image_id == $image_id
                and .attestation.guest_target == $guest_target)] | length
    ' "$manifest") -eq 1 ]] ||
    die "production runtime pack must contain one attested $image_id image for $guest_target"
done

jq -e '
  all(.oci_images[]; (.reference | startswith("ghcr.io/mitosu-cloud/")))
  and all(.oci_images[] | select(.attestation != null);
          (.attestation.runner_source_digest | startswith("ghcr.io/mitosu-cloud/")))
' "$manifest" >/dev/null ||
  die 'production OCI and runner references must be immutable mitosu-cloud GHCR digests'

jq -S -n \
  --arg pack_id "$(jq -er '.pack_id' "$manifest")" \
  --arg guest_target "$guest_target" \
  '{status: "production-candidate", pack_id: $pack_id, guest_target: $guest_target}'
