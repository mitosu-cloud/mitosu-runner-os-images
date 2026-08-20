#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/podman.sh
source "$SCRIPT_DIR/lib/podman.sh"

image_reference=

usage() {
  cat <<'EOF'
Usage: scripts/verify-images.sh --image IMAGE

Run the common offline smoke suite, compare the installed runner byte-for-byte
with the marker's digest-pinned runner image, and inspect the exported OCI
layers to validate the resolver stored in the image root filesystem.
EOF
}

while (($# > 0)); do
  case $1 in
    --image)
      (($# >= 2)) || die '--image requires a value'
      image_reference=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n $image_reference ]] || die '--image is required'
require_command awk
require_command cmp
require_command jq
require_command rg
require_command tar

"$SCRIPT_DIR/smoke-images.sh" --image "$image_reference"

staging_directory=$(make_private_temp_dir verify-image)
trap 'rm -rf -- "$staging_directory"' EXIT
marker_path="$staging_directory/image.json"
archive_path="$staging_directory/image.oci.tar"
layout_directory="$staging_directory/layout"
mkdir -p -- "$layout_directory"

run_podman run --rm --network none --read-only \
  --entrypoint /bin/cat "$image_reference" /usr/share/mitosu/image.json > "$marker_path"
runner_image=$(jq -r '.runner_source_digest' "$marker_path")
architecture=$(jq -r '.architecture' "$marker_path")
runner_architecture=$(run_podman image inspect --format '{{.Architecture}}' "$runner_image")
[[ $runner_architecture == "$architecture" ]] || die 'runner source architecture does not match image marker'

final_runner_sha256=$(run_podman run --rm --network none --read-only \
  --entrypoint /usr/bin/sha256sum "$image_reference" /usr/local/bin/mitosurunner | awk '{print $1}')
source_runner_sha256=$(run_podman run --rm --network none --read-only \
  --entrypoint /bin/busybox "$runner_image" sha256sum /usr/local/bin/mitosurunner | awk '{print $1}')
[[ $final_runner_sha256 == "$source_runner_sha256" ]] ||
  die 'installed runner does not match the declared source image'

run_podman save --format oci-archive --output "$archive_path" "$image_reference" >/dev/null
tar -xf "$archive_path" -C "$layout_directory"
manifest_digest=$(jq -r '.manifests[0].digest' "$layout_directory/index.json")
manifest_path="$layout_directory/blobs/sha256/${manifest_digest#sha256:}"
mapfile -t layers < <(jq -r '.layers[].digest' "$manifest_path")

resolver_found=false
for ((layer_index=${#layers[@]} - 1; layer_index >= 0; layer_index--)); do
  layer_path="$layout_directory/blobs/sha256/${layers[$layer_index]#sha256:}"
  if tar -tf "$layer_path" | rg --quiet '(^|\./)etc/\.wh\.resolv\.conf$'; then
    die 'resolver is absent from the effective image root filesystem'
  fi
  resolver_path=$(tar -tf "$layer_path" | rg '(^|\./)etc/resolv\.conf$' | tail -n 1 || true)
  if [[ -n $resolver_path ]]; then
    tar -xOf "$layer_path" "$resolver_path" > "$staging_directory/resolv.conf"
    resolver_found=true
    break
  fi
done

[[ $resolver_found == true ]] || die 'resolver is absent from the image layers'
cmp "$REPOSITORY_ROOT/images/common/resolv.conf" "$staging_directory/resolv.conf" ||
  die 'stored resolver does not match the repository contract'

printf 'verified runner sha256: %s\n' "$final_runner_sha256"
printf 'verified stored resolver layer: %s\n' "${layers[$layer_index]}"
