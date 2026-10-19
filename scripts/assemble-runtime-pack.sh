#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
usage: assemble-runtime-pack.sh \
  --output DIRECTORY \
  --pack-id ID \
  --target-os linux|macos|windows \
  --target-arch aarch64|x86_64 \
  --oci-images JSON-FILE \
  [--compression zstd] \
  --artifact NAME SOURCE RELATIVE-PATH EXECUTABLE \
  [--artifact NAME SOURCE RELATIVE-PATH EXECUTABLE ...]

Creates an unsigned runtime pack from exact local artifact bytes and a JSON
array of digest-pinned OCI image entries. EXECUTABLE must be true or false.
Schema version 2 is selected when both required OpenShell runtime images are
present; supplying only one is rejected. --compression zstd selects schema 3
and emits flat compressed source files with signed expanded-file identities.

The output directory must not exist and must be beneath MITOSU_BUILD_ROOT.
EOF
}

output=
pack_id=
target_os=
target_arch=
oci_images_file=
compression=
artifact_names=()
artifact_sources=()
artifact_paths=()
artifact_executables=()

while (($# > 0)); do
  case "$1" in
    --output)
      (($# >= 2)) || die '--output requires a value'
      output=$2
      shift 2
      ;;
    --pack-id)
      (($# >= 2)) || die '--pack-id requires a value'
      pack_id=$2
      shift 2
      ;;
    --target-os)
      (($# >= 2)) || die '--target-os requires a value'
      target_os=$2
      shift 2
      ;;
    --target-arch)
      (($# >= 2)) || die '--target-arch requires a value'
      target_arch=$2
      shift 2
      ;;
    --oci-images)
      (($# >= 2)) || die '--oci-images requires a value'
      oci_images_file=$2
      shift 2
      ;;
    --artifact)
      (($# >= 5)) || die '--artifact requires NAME SOURCE RELATIVE-PATH EXECUTABLE'
      artifact_names+=("$2")
      artifact_sources+=("$3")
      artifact_paths+=("$4")
      artifact_executables+=("$5")
      shift 5
      ;;
    --compression)
      (($# >= 2)) || die '--compression requires a value'
      [[ $2 == zstd ]] || die 'only zstd transport compression is supported'
      compression=$2
      shift 2
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

require_command jq
require_command realpath
require_command jsonschema

[[ -n $output ]] || die '--output is required'
[[ -n $pack_id ]] || die '--pack-id is required'
[[ -n $target_os ]] || die '--target-os is required'
[[ -n $target_arch ]] || die '--target-arch is required'
[[ -n $oci_images_file ]] || die '--oci-images is required'
((${#artifact_names[@]} > 0)) || die 'at least one --artifact is required'
[[ $pack_id =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$ ]] || die 'invalid pack ID'
[[ $target_os == linux || $target_os == macos || $target_os == windows ]] ||
  die 'unsupported target OS'
[[ $target_arch == aarch64 || $target_arch == x86_64 ]] ||
  die 'unsupported target architecture'
[[ -f $oci_images_file && ! -L $oci_images_file ]] ||
  die '--oci-images must be a regular non-symlink file'
jq -e 'type == "array" and length <= 32' "$oci_images_file" >/dev/null ||
  die '--oci-images must contain a JSON array with at most 32 entries'

build_root=$(ensure_build_root)
build_root=$(realpath -m -- "$build_root")
output=$(realpath -m -- "$output")
case "$output/" in
  "$build_root/"*) ;;
  *) die '--output must be beneath MITOSU_BUILD_ROOT' ;;
esac
[[ ! -e $output ]] || die "output already exists: $output"

declare -A seen_names=()
declare -A seen_paths=()
for index in "${!artifact_names[@]}"; do
  name=${artifact_names[$index]}
  source_path=${artifact_sources[$index]}
  relative_path=${artifact_paths[$index]}
  executable=${artifact_executables[$index]}
  [[ $name =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$ ]] ||
    die "invalid artifact name: $name"
  [[ $relative_path =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$ ]] ||
    die "invalid artifact path: $relative_path"
  [[ $executable == true || $executable == false ]] ||
    die "artifact executable must be true or false: $name"
  [[ -f $source_path && ! -L $source_path ]] ||
    die "artifact source must be a regular non-symlink file: $source_path"
  [[ -z ${seen_names[$name]+present} ]] || die "duplicate artifact name: $name"
  portable_path=${relative_path,,}
  [[ -z ${seen_paths[$portable_path]+present} ]] ||
    die "duplicate or case-colliding artifact path: $relative_path"
  seen_names[$name]=present
  seen_paths[$portable_path]=present
done

for path in "${!seen_paths[@]}"; do
  for other in "${!seen_paths[@]}"; do
    [[ $path == "$other" ]] && continue
    [[ "$other/" != "$path/"* ]] || die "artifact path is a prefix of another path: $path"
  done
done

supervisor_count=$(jq '[.[] | select(.name == "openshell_supervisor_image")] | length' "$oci_images_file")
sandbox_count=$(jq '[.[] | select(.name == "openshell_sandbox_runtime_image")] | length' "$oci_images_file")
[[ $supervisor_count -le 1 && $sandbox_count -le 1 ]] ||
  die 'OpenShell runtime image names must be unique'
if [[ $supervisor_count -eq 1 && $sandbox_count -eq 1 ]]; then
  schema_version=2
elif [[ $supervisor_count -eq 0 && $sandbox_count -eq 0 ]]; then
  schema_version=1
else
  die 'OpenShell supervisor and sandbox runtime images must be supplied together'
fi
if [[ $compression == zstd ]]; then
  require_command zstd
  schema_version=3
fi

created_output=false
cleanup() {
  if [[ $created_output == true && -d $output ]]; then
    rm -rf -- "$output"
  fi
}
trap cleanup EXIT
mkdir -m 0700 -- "$output"
created_output=true

artifacts='[]'
for index in "${!artifact_names[@]}"; do
  name=${artifact_names[$index]}
  source_path=${artifact_sources[$index]}
  relative_path=${artifact_paths[$index]}
  executable=${artifact_executables[$index]}
  size=$(wc -c <"$source_path")
  size=${size//[[:space:]]/}
  digest=$(sha256_file "$source_path")
  transport=null
  if [[ $compression == zstd ]]; then
    # Release assets use a flat namespace; expanded cache paths stay unchanged.
    transport_path="$name.zst"
    destination="$output/$transport_path"
    zstd -3 -T1 --quiet --stdout -- "$source_path" >"$destination"
    chmod 0444 -- "$destination"
    transport_size=$(wc -c <"$destination")
    transport_size=${transport_size//[[:space:]]/}
    transport=$(jq -cn --arg path "$transport_path" --argjson size "$transport_size" \
      --arg sha256 "$(sha256_file "$destination")" \
      '{compression: "zstd", path: $path, size: $size, sha256: $sha256}')
  else
    destination="$output/$relative_path"
    install -d -m 0700 -- "$(dirname -- "$destination")"
    if [[ $executable == true ]]; then
      install -m 0555 -- "$source_path" "$destination"
    else
      install -m 0444 -- "$source_path" "$destination"
    fi
  fi
  artifacts=$(jq -cn \
    --argjson current "$artifacts" \
    --arg name "$name" \
    --arg path "$relative_path" \
    --argjson size "$size" \
    --arg sha256 "$digest" \
    --argjson executable "$executable" \
    --argjson transport "$transport" \
    '$current + [{name: $name, path: $path, size: $size, sha256: $sha256, executable: $executable}
      + (if $transport == null then {} else {transport: $transport} end)]')
done

manifest_staging="$output/.manifest.json.tmp"
jq -S -n \
  --arg pack_id "$pack_id" \
  --arg target_os "$target_os" \
  --arg target_arch "$target_arch" \
  --argjson schema_version "$schema_version" \
  --argjson artifacts "$artifacts" \
  --slurpfile oci_images "$oci_images_file" \
  '{
    schema_version: $schema_version,
    pack_id: $pack_id,
    target_os: $target_os,
    target_arch: $target_arch,
    artifacts: $artifacts,
    oci_images: $oci_images[0]
  }' >"$manifest_staging"
chmod 0444 -- "$manifest_staging"
mv -- "$manifest_staging" "$output/manifest.json"
"$SCRIPT_DIR/verify-runtime-pack-candidate.sh" --pack-dir "$output" >/dev/null

created_output=false
trap - EXIT
printf '%s\n' "$output"
