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

args=("$pack_dir")
if [[ $signed == true ]]; then
  args+=(--signed)
fi
python3 "$SCRIPT_DIR/verify-runtime-pack-files.py" "${args[@]}"
