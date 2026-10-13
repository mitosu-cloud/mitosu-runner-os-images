#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
usage: verify-runtime-pack-candidate.sh --pack-dir DIRECTORY [--signed]

Validates the manifest, artifact bytes, modes, uniqueness constraints, and
exact file inventory. By default signing outputs are forbidden. --signed
allows manifest.sig, ed25519-public-key.hex, and release-handoff.json.
EOF
}

pack_dir=
signed=false
while (($# > 0)); do
  case "$1" in
    --pack-dir)
      (($# >= 2)) || die '--pack-dir requires a value'
      pack_dir=$2
      shift 2
      ;;
    --signed)
      signed=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

require_command find
require_command jq
require_command realpath
require_command jsonschema

[[ -n $pack_dir ]] || die '--pack-dir is required'
pack_dir=$(realpath -e -- "$pack_dir")
[[ -d $pack_dir && ! -L $pack_dir ]] || die '--pack-dir must be a non-symlink directory'
[[ -f $pack_dir/manifest.json && ! -L $pack_dir/manifest.json ]] ||
  die 'manifest.json is missing or unsafe'
validate_json_schema "$REPOSITORY_ROOT/schemas/runtime-pack.schema.json" "$pack_dir/manifest.json"

if [[ $signed == true ]]; then
  [[ -f $pack_dir/manifest.sig && ! -L $pack_dir/manifest.sig ]] ||
    die 'manifest.sig is missing or unsafe'
else
  for control_file in manifest.sig ed25519-public-key.hex release-handoff.json complete; do
    [[ ! -e $pack_dir/$control_file ]] ||
      die "unsigned runtime-pack candidate contains $control_file"
  done
fi

jq -e '
  ([.artifacts[].name] | length == (unique | length))
  and ([.artifacts[].path | ascii_downcase] | length == (unique | length))
  and ([.oci_images[].name] | length == (unique | length))
  and ([.oci_images[] | select(.attestation != null)
        | [.attestation.image_id, .attestation.guest_target] | join("\u0000")]
       | length == (unique | length))
  and ([.oci_images[]
        | select((.name == "openshell_supervisor_image"
                  or .name == "openshell_sandbox_runtime_image")
                 and .attestation != null)] | length == 0)
' "$pack_dir/manifest.json" >/dev/null ||
  die 'runtime-pack manifest contains duplicate names, paths, attestations, or an attested OpenShell control image'

declare -A artifact_names=()
declare -A portable_paths=()
declare -A expected_files=([manifest.json]=present)
artifact_paths=()
total_size=0
while IFS=$'\t' read -r name relative_path expected_size expected_sha256 executable; do
  [[ -z ${artifact_names[$name]+present} ]] || die "duplicate artifact name: $name"
  artifact_names[$name]=present
  portable_path=${relative_path,,}
  [[ -z ${portable_paths[$portable_path]+present} ]] ||
    die "duplicate or case-colliding artifact path: $relative_path"
  portable_paths[$portable_path]=present
  case "$portable_path/" in
    manifest.json/* | manifest.sig/* | ed25519-public-key.hex/* | release-handoff.json/* | complete/*)
      die "artifact path overlaps a runtime-pack control file: $relative_path"
      ;;
  esac
  artifact_paths+=("$portable_path")
  expected_files[$relative_path]=present

  current_path=$pack_dir
  IFS='/' read -r -a path_components <<<"$relative_path"
  for component in "${path_components[@]}"; do
    current_path="$current_path/$component"
    [[ ! -L $current_path ]] || die "artifact path traverses a symlink: $relative_path"
  done
  [[ -f $current_path ]] || die "artifact is missing or not a regular file: $relative_path"
  actual_size=$(wc -c <"$current_path")
  actual_size=${actual_size//[[:space:]]/}
  [[ $actual_size == "$expected_size" ]] || die "artifact size mismatch: $relative_path"
  [[ $(sha256_file "$current_path") == "$expected_sha256" ]] ||
    die "artifact SHA-256 mismatch: $relative_path"
  if [[ $executable == true ]]; then
    [[ -x $current_path ]] || die "artifact is not executable as declared: $relative_path"
  else
    [[ ! -x $current_path ]] || die "artifact is executable but declared non-executable: $relative_path"
  fi
  total_size=$((total_size + expected_size))
  ((total_size <= 34359738368)) || die 'runtime pack exceeds 32 GiB'
done < <(jq -r '.artifacts[] | [.name, .path, (.size | tostring), .sha256, (.executable | tostring)] | @tsv' "$pack_dir/manifest.json")

for path in "${artifact_paths[@]}"; do
  for other in "${artifact_paths[@]}"; do
    [[ $path == "$other" ]] && continue
    [[ "$other/" != "$path/"* ]] || die "artifact path is a prefix of another path: $path"
  done
done

if [[ $signed == true ]]; then
  expected_files[manifest.sig]=present
  [[ ! -e $pack_dir/ed25519-public-key.hex ]] || expected_files[ed25519-public-key.hex]=present
  [[ ! -e $pack_dir/release-handoff.json ]] || expected_files[release-handoff.json]=present
fi

special_path=$(find "$pack_dir" -mindepth 1 ! -type f ! -type d -print -quit)
if [[ -n $special_path ]]; then
  die 'runtime pack contains a symlink or special file'
fi
while IFS= read -r relative_path; do
  [[ -n ${expected_files[$relative_path]+present} ]] ||
    die "runtime pack contains an undeclared file: $relative_path"
done < <(find "$pack_dir" -mindepth 1 -type f -printf '%P\n')

jq -S -n \
  --arg pack_id "$(jq -er '.pack_id' "$pack_dir/manifest.json")" \
  --argjson artifact_count "${#artifact_names[@]}" \
  --argjson total_size "$total_size" \
  '{status: "validated", pack_id: $pack_id, artifact_count: $artifact_count, total_size: $total_size}'
