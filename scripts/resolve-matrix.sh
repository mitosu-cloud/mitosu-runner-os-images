#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

matrix_path="$REPOSITORY_ROOT/locks/image-matrix.json"
output_path=

usage() {
  cat <<'EOF'
Usage: scripts/resolve-matrix.sh [--matrix PATH] [--output PATH]

Print stable JSON containing every image/architecture combination. This command
does not build images or require resolved build-input locks.
EOF
}

while (($# > 0)); do
  case $1 in
    --matrix)
      (($# >= 2)) || die '--matrix requires a path'
      matrix_path=$2
      shift 2
      ;;
    --output)
      (($# >= 2)) || die '--output requires a path'
      output_path=$2
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

require_command jq
"$SCRIPT_DIR/validate-locks.sh" --matrix "$matrix_path" >/dev/null
matrix_digest=$(sha256_file "$matrix_path")

resolve() {
  jq --arg matrix_digest "$matrix_digest" '
    . as $matrix |
    {
      schema_version: 1,
      matrix_sha256: $matrix_digest,
      entries: ([
        $matrix.images[] as $image |
        ($matrix.distributions[] | select(.id == $image.distribution)) as $distribution |
        ($matrix.profiles[] | select(.id == $image.profile)) as $profile |
        $matrix.architectures[] as $architecture |
        {
          image_id: $image.id,
          architecture: $architecture,
          distribution: $distribution.family,
          distribution_version: $distribution.version,
          development_profile: $profile.id,
          profile_revision: $profile.revision,
          capabilities: ($profile.capabilities | sort),
          containerfile: $distribution.containerfile,
          os_lock: $distribution.os_lock,
          toolchain_lock: $profile.toolchain_lock,
          runner_lock: $matrix.runner_lock,
          suggested_runtime_egress: ($profile.suggested_runtime_egress | sort)
        }
      ] | sort_by(.image_id, .architecture))
    }
  ' "$matrix_path"
}

if [[ -z $output_path ]]; then
  resolve
  exit 0
fi

output_directory=$(dirname -- "$output_path")
mkdir -p -- "$output_directory"
staging_directory=$(make_private_temp_dir resolve)
trap 'rm -rf -- "$staging_directory"' EXIT
resolve >"$staging_directory/resolved-matrix.json"
validate_json_schema \
  "$REPOSITORY_ROOT/schemas/resolved-matrix.schema.json" \
  "$staging_directory/resolved-matrix.json"
mv -- "$staging_directory/resolved-matrix.json" "$output_path"
printf 'wrote resolved matrix: %s\n' "$output_path" >&2
