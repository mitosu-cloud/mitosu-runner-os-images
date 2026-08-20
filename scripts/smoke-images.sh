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
Usage: scripts/smoke-images.sh --image IMAGE

Run common smoke tests without external network and with a read-only root.
Writable home, project, application, cache, run, and scratch paths are supplied
as temporary filesystems. A machine-readable summary is written below the
build root.
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
require_command jq
require_command jsonschema

started_at=$(date +%s)
status=failed
image_id=unknown
architecture=unknown
source_revision=unknown
runner_version=unknown
execution=unknown
summary_path=
staging_directory=

write_summary() {
  local finished_at
  local duration_seconds
  local build_root
  local report_directory

  finished_at=$(date +%s)
  duration_seconds=$((finished_at - started_at))
  build_root=$(ensure_build_root)
  report_directory="$build_root/reports"
  mkdir -p -- "$report_directory"
  summary_path="$report_directory/$image_id-$architecture-smoke.json"
  jq -n \
    --arg image_id "$image_id" \
    --arg architecture "$architecture" \
    --arg source_revision "$source_revision" \
    --arg image_reference "$image_reference" \
    --arg runner_version "$runner_version" \
    --arg execution "$execution" \
    --arg status "$status" \
    --argjson duration_seconds "$duration_seconds" \
    '{
      schema_version: 1,
      image_id: $image_id,
      architecture: $architecture,
      source_revision: $source_revision,
      image_reference: $image_reference,
      runner_version: $runner_version,
      execution: $execution,
      duration_seconds: $duration_seconds,
      status: $status
  }' > "$summary_path"
  validate_json_schema "$REPOSITORY_ROOT/schemas/smoke-summary.schema.json" "$summary_path"
  if [[ -n $staging_directory && -d $staging_directory ]]; then
    rm -rf -- "$staging_directory"
  fi
  printf 'smoke summary: %s\n' "$summary_path" >&2
}
trap write_summary EXIT

staging_directory=$(make_private_temp_dir smoke)
marker_path="$staging_directory/image.json"
inspect_path="$staging_directory/inspect.json"
run_podman image inspect "$image_reference" > "$inspect_path"
run_podman run --rm --network none --read-only \
  --entrypoint /bin/cat "$image_reference" /usr/share/mitosu/image.json > "$marker_path"
validate_json_schema "$REPOSITORY_ROOT/schemas/image-marker.schema.json" "$marker_path"

image_id=$(jq -r '.image_id' "$marker_path")
architecture=$(jq -r '.architecture' "$marker_path")
source_revision=$(jq -r '.source_revision' "$marker_path")
inspect_architecture=$(jq -r '.[0].Architecture' "$inspect_path")
entrypoint=$(jq -r '.[0].Config.Entrypoint[0]' "$inspect_path")
label_image_id=$(jq -r '.[0].Config.Labels["dev.mitosu.image.id"]' "$inspect_path")

[[ $inspect_architecture == "$architecture" ]] || die 'OCI architecture does not match marker'
[[ $entrypoint == /usr/local/bin/mitosurunner ]] || die 'unexpected OCI entry point'
[[ $label_image_id == "$image_id" ]] || die 'OCI image ID label does not match marker'

host_architecture=$(host_oci_architecture)
if [[ $host_architecture == "$architecture" ]]; then
  execution=native
else
  execution=emulated
fi

runner_version=$(run_podman run --rm --network none --read-only \
  --tmpfs /run:rw,mode=0755 \
  --tmpfs /tmp:rw,mode=1777 \
  "$image_reference" --version)

run_podman run --rm --network none --read-only \
  --security-opt no-new-privileges \
  --env HOME=/home/mitosu \
  --env HTTP_PROXY= \
  --env HTTPS_PROXY= \
  --env ALL_PROXY= \
  --env http_proxy= \
  --env https_proxy= \
  --env all_proxy= \
  --entrypoint /bin/bash \
  --tmpfs /home/mitosu:rw,mode=0700 \
  --tmpfs /workspace:rw,mode=0750 \
  --tmpfs /var/lib/mitosu/apps:rw,mode=0750 \
  --tmpfs /var/cache/mitosu:rw,mode=0750 \
  --tmpfs /run:rw,mode=0755 \
  --tmpfs /tmp:rw,mode=1777 \
  --volume "$REPOSITORY_ROOT/tests/common/smoke.sh:/opt/mitosu-common-smoke:ro" \
  "$image_reference" -c \
  'chown 1000:1000 /home/mitosu /workspace /var/lib/mitosu/apps /var/cache/mitosu && exec setpriv --reuid=1000 --regid=1000 --init-groups /opt/mitosu-common-smoke'

status=passed
