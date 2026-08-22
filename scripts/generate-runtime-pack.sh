#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
usage: generate-runtime-pack.sh \
  --output DIRECTORY \
  --pack-id ID \
  --kernel FILE \
  --runner FILE \
  --initfs REPOSITORY@sha256:DIGEST \
  --tool-image REPOSITORY@sha256:DIGEST \
  [--image-set FILE] \
  [--target-os macos] \
  [--target-arch aarch64]

The output directory must not exist and must be beneath MITOSU_BUILD_ROOT.
EOF
}

output=
pack_id=
kernel=
runner=
image_set=
initfs=
tool_image=
target_os=macos
target_arch=aarch64

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
    --kernel)
      (($# >= 2)) || die '--kernel requires a value'
      kernel=$2
      shift 2
      ;;
    --runner)
      (($# >= 2)) || die '--runner requires a value'
      runner=$2
      shift 2
      ;;
    --image-set)
      (($# >= 2)) || die '--image-set requires a value'
      image_set=$2
      shift 2
      ;;
    --initfs)
      (($# >= 2)) || die '--initfs requires a value'
      initfs=$2
      shift 2
      ;;
    --tool-image)
      (($# >= 2)) || die '--tool-image requires a value'
      tool_image=$2
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
[[ -n $kernel ]] || die '--kernel is required'
[[ -n $runner ]] || die '--runner is required'
[[ -n $initfs ]] || die '--initfs is required'
[[ -n $tool_image ]] || die '--tool-image is required'
[[ $pack_id =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$ ]] || die 'invalid pack ID'
[[ $initfs =~ ^.+@sha256:[a-f0-9]{64}$ ]] || die '--initfs must be an immutable OCI digest reference'
[[ $tool_image =~ ^.+@sha256:[a-f0-9]{64}$ ]] || die '--tool-image must be an immutable OCI digest reference'

build_root=$(ensure_build_root)
build_root=$(realpath -m -- "$build_root")
output=$(realpath -m -- "$output")
case "$output/" in
  "$build_root/"*) ;;
  *) die '--output must be beneath MITOSU_BUILD_ROOT' ;;
esac
[[ ! -e $output ]] || die "output already exists: $output"

require_regular_input() {
  local label=$1
  local path=$2

  [[ -f $path && ! -L $path ]] || die "$label must be a regular non-symlink file: $path"
}

require_regular_input kernel "$kernel"
require_regular_input runner "$runner"
if [[ -n $image_set ]]; then
  require_regular_input image-set "$image_set"
  validate_json_schema "$REPOSITORY_ROOT/schemas/image-set.schema.json" "$image_set"
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
install -d -m 0700 -- "$output/kernel" "$output/bin"
install -m 0444 -- "$kernel" "$output/kernel/vmlinux"
install -m 0555 -- "$runner" "$output/bin/mitosurunner"
if [[ -n $image_set ]]; then
  install -d -m 0700 -- "$output/metadata"
  install -m 0444 -- "$image_set" "$output/metadata/image-set.json"
fi

artifacts='[]'
add_artifact() {
  local name=$1
  local relative_path=$2
  local executable=$3
  local absolute_path="$output/$relative_path"
  local size
  local digest

  size=$(wc -c <"$absolute_path")
  size=${size//[[:space:]]/}
  digest=$(sha256_file "$absolute_path")
  artifacts=$(jq -cn \
    --argjson current "$artifacts" \
    --arg name "$name" \
    --arg path "$relative_path" \
    --argjson size "$size" \
    --arg sha256 "$digest" \
    --argjson executable "$executable" \
    '$current + [{name: $name, path: $path, size: $size, sha256: $sha256, executable: $executable}]')
}

add_artifact kernel kernel/vmlinux false
add_artifact runner bin/mitosurunner true
if [[ -n $image_set ]]; then
  add_artifact image_set metadata/image-set.json false
fi

manifest_staging="$output/.manifest.json.tmp"
jq -S -n \
  --arg pack_id "$pack_id" \
  --arg target_os "$target_os" \
  --arg target_arch "$target_arch" \
  --argjson artifacts "$artifacts" \
  --arg initfs "$initfs" \
  --arg tool_image "$tool_image" \
  '{
    schema_version: 1,
    pack_id: $pack_id,
    target_os: $target_os,
    target_arch: $target_arch,
    artifacts: $artifacts,
    oci_images: [
      {name: "initfs", reference: $initfs},
      {name: "tool_image", reference: $tool_image}
    ]
  }' >"$manifest_staging"
chmod 0444 -- "$manifest_staging"
mv -- "$manifest_staging" "$output/manifest.json"
validate_json_schema "$REPOSITORY_ROOT/schemas/runtime-pack.schema.json" "$output/manifest.json"

created_output=false
trap - EXIT
printf '%s\n' "$output"
