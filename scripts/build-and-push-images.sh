#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/podman.sh
source "$SCRIPT_DIR/lib/podman.sh"

repository=ghcr.io/mitosu-cloud/runner-os
release_tag=
allow_emulated=false
dry_run=false
architectures=()

usage() {
  cat <<'EOF'
Usage: scripts/build-and-push-images.sh --tag TAG [options]

Build, verify, and push every image target currently implemented by this
repository. Build storage and reports remain under MITOSU_BUILD_ROOT, which
defaults to /tmp/mitosu-runner-os-images and must resolve beneath /tmp.

Options:
  --tag TAG                  Release tag component, such as v0.1.0
  --repository REPOSITORY    Destination (default: ghcr.io/mitosu-cloud/runner-os)
  --architecture ARCH        Build amd64 or arm64; repeat to build both
                             (default: native host architecture)
  --allow-emulated           Permit a non-native architecture build and smoke
  --dry-run                  Validate and print the publication plan only
  -h, --help                 Show this help

Each architecture is pushed as:
  REPOSITORY:IMAGE_ID-TAG-ARCH

When both amd64 and arm64 are selected, an OCI index is also pushed as:
  REPOSITORY:IMAGE_ID-TAG

The current Containerfiles implement the Ubuntu and AlmaLinux common images.
The language-profile images are intentionally excluded until their checked-in
toolchain locks and Containerfile stages become build-ready.

The active GitHub CLI token must have read:packages and write:packages access.
EOF
}

while (($# > 0)); do
  case $1 in
    --tag)
      (($# >= 2)) || die '--tag requires a value'
      release_tag=$2
      shift 2
      ;;
    --repository)
      (($# >= 2)) || die '--repository requires a value'
      repository=$2
      shift 2
      ;;
    --architecture)
      (($# >= 2)) || die '--architecture requires a value'
      architectures+=("$2")
      shift 2
      ;;
    --allow-emulated)
      allow_emulated=true
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

require_command git
require_command grep
require_command find
require_command jq
require_command realpath

[[ -n $release_tag ]] || die '--tag is required'
[[ $release_tag =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] ||
  die '--tag must be 1-64 lowercase letters, digits, dots, underscores, or hyphens'
[[ $repository =~ ^ghcr\.io/[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$ ]] ||
  die '--repository must be ghcr.io/OWNER/PACKAGE using lowercase portable names'

"$SCRIPT_DIR/validate-locks.sh" >/dev/null

if ((${#architectures[@]} == 0)); then
  architectures=("$(host_oci_architecture)")
fi

declare -A selected_architectures=()
for architecture in "${architectures[@]}"; do
  case $architecture in
    amd64|arm64) ;;
    *) die "unsupported architecture: $architecture" ;;
  esac
  [[ -z ${selected_architectures[$architecture]+present} ]] ||
    die "duplicate architecture: $architecture"
  selected_architectures[$architecture]=present
done

host_architecture=$(host_oci_architecture)
for architecture in "${architectures[@]}"; do
  if [[ $architecture != "$host_architecture" && $allow_emulated != true ]]; then
    die "$architecture would be emulated on $host_architecture; use a native host or pass --allow-emulated"
  fi
done

require_emulation_handler() {
  local architecture=$1
  local handler_name
  local handler_path

  case $architecture in
    amd64) handler_name=qemu-x86_64 ;;
    arm64) handler_name=qemu-aarch64 ;;
    *) die "no emulation handler mapping for architecture: $architecture" ;;
  esac
  handler_path="/proc/sys/fs/binfmt_misc/$handler_name"
  [[ -r $handler_path ]] ||
    die "no $handler_name binfmt handler for $architecture; install qemu-user-static and activate systemd-binfmt before using --allow-emulated"
  grep -qx 'enabled' "$handler_path" ||
    die "$handler_name binfmt handler is not enabled"
  grep -Eq '^flags:.*F' "$handler_path" ||
    die "$handler_name binfmt handler lacks the fix-binary flag required for rootless container builds"
}

source_revision=$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)
source_short=${source_revision:0:12}
matrix="$REPOSITORY_ROOT/locks/image-matrix.json"
mapfile -t distributions < <(jq -r '.distributions[].id' "$matrix")
(( ${#distributions[@]} > 0 )) || die 'the image matrix contains no distributions'

build_root=$(ensure_build_root)
release_directory="$build_root/releases/$release_tag-$source_short"
report_path="$release_directory/push-report.json"

plan=$(jq -S -n \
  --arg repository "$repository" \
  --arg release_tag "$release_tag" \
  --arg source_revision "$source_revision" \
  --arg host_architecture "$host_architecture" \
  --argjson architectures "$(printf '%s\n' "${architectures[@]}" | jq -R . | jq -s .)" \
  --argjson distributions "$(printf '%s\n' "${distributions[@]}" | jq -R . | jq -s .)" \
  '{
    repository: $repository,
    release_tag: $release_tag,
    source_revision: $source_revision,
    host_architecture: $host_architecture,
    architectures: $architectures,
    images: [$distributions[] | . + "-common"]
  }')

if [[ $dry_run == true ]]; then
  printf '%s\n' "$plan"
  exit 0
fi

for architecture in "${architectures[@]}"; do
  if [[ $architecture != "$host_architecture" ]]; then
    require_emulation_handler "$architecture"
  fi
done

if ! git -C "$REPOSITORY_ROOT" diff --quiet \
  || ! git -C "$REPOSITORY_ROOT" diff --cached --quiet \
  || [[ -n $(git -C "$REPOSITORY_ROOT" ls-files --others --exclude-standard) ]]; then
  die 'refusing to publish from a dirty source tree'
fi

require_command gh
require_command podman
gh auth status --hostname github.com >/dev/null 2>&1 ||
  die 'GitHub CLI is not authenticated; run gh auth login --hostname github.com'
registry_user=$(gh api user --jq .login)
[[ -n $registry_user ]] || die 'could not resolve the authenticated GitHub user'

registry=${repository%%/*}
namespace_and_package=${repository#*/}
namespace=${namespace_and_package%%/*}
package_name=${repository##*/}

owner_type=$(gh api "users/$namespace" --jq .type)
case $owner_type in
  Organization)
    package_endpoint="orgs/$namespace/packages/container/$package_name"
    ;;
  User)
    [[ $namespace == "$registry_user" ]] ||
      die 'authenticated GitHub user does not own the destination package namespace'
    package_endpoint="user/packages/container/$package_name"
    ;;
  *)
    die "unsupported GHCR namespace owner type: $owner_type"
    ;;
esac

staging=$(make_private_temp_dir publish-images)
logged_in=false
cleanup() {
  if [[ $logged_in == true ]]; then
    run_podman logout "$registry" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$staging"
}
trap cleanup EXIT

auth_response="$staging/github-auth-response.txt"
gh api --include user >"$auth_response"
oauth_scopes=$(awk '
  BEGIN { IGNORECASE = 1 }
  /^x-oauth-scopes:/ {
    sub(/^[^:]+:[[:space:]]*/, "")
    gsub(/\r/, "")
    print
    exit
  }
' "$auth_response")
normalized_scopes=${oauth_scopes//[[:space:]]/}
case ",$normalized_scopes," in
  *,write:packages,*) ;;
  *)
    die 'active gh credential lacks write:packages; use a classic PAT with GHCR write access and authorize organization SSO if required'
    ;;
esac

existing_tags="$staging/existing-tags.txt"
package_error="$staging/package-error.txt"
if gh api --paginate "$package_endpoint/versions?per_page=100" \
    --jq '.[] | .metadata.container.tags[]?' \
    >"$existing_tags" 2>"$package_error"; then
  :
elif grep -Eq 'HTTP 404|Not Found' "$package_error"; then
  : >"$existing_tags"
else
  cat "$package_error" >&2
  die 'could not inspect existing GHCR package versions'
fi

target_tags=()
for distribution in "${distributions[@]}"; do
  image_id="$distribution-common"
  for architecture in "${architectures[@]}"; do
    target_tags+=("$image_id-$release_tag-$architecture")
  done
  if [[ -n ${selected_architectures[amd64]+present} \
      && -n ${selected_architectures[arm64]+present} ]]; then
    target_tags+=("$image_id-$release_tag")
  fi
done
for target_tag in "${target_tags[@]}"; do
  if grep -Fqx -- "$target_tag" "$existing_tags"; then
    die "refusing to overwrite existing GHCR tag: $repository:$target_tag"
  fi
done

gh auth token --hostname github.com | \
  run_podman login "$registry" --username "$registry_user" --password-stdin >/dev/null
logged_in=true

images='[]'
for distribution in "${distributions[@]}"; do
  image_id="$distribution-common"
  local_references=()
  architecture_reports='{}'

  for architecture in "${architectures[@]}"; do
    printf 'building %s for linux/%s\n' "$image_id" "$architecture" >&2
    "$SCRIPT_DIR/build-images.sh" \
      --distribution "$distribution" \
      --architecture "$architecture"

    local_reference="localhost/mitosu/$image_id:$source_short-$architecture"
    "$SCRIPT_DIR/verify-images.sh" --image "$local_reference"

    remote_tag="$image_id-$release_tag-$architecture"
    remote_reference="$repository:$remote_tag"
    digest_file="$staging/$image_id-$architecture.digest"
    printf 'pushing %s\n' "$remote_reference" >&2
    run_podman push \
      --digestfile "$digest_file" \
      "$local_reference" \
      "docker://$remote_reference"
    manifest_digest=$(<"$digest_file")
    [[ $manifest_digest =~ ^sha256:[a-f0-9]{64}$ ]] ||
      die "registry returned an invalid manifest digest for $remote_reference"

    if [[ $architecture == "$host_architecture" ]]; then
      execution=native
    else
      execution=emulated
    fi
    architecture_report=$(jq -n \
      --arg reference "$remote_reference@$manifest_digest" \
      --arg manifest_digest "$manifest_digest" \
      --arg verification "$execution" \
      '{
        reference: $reference,
        manifest_digest: $manifest_digest,
        verification: $verification
      }')
    architecture_reports=$(jq -c \
      --arg architecture "$architecture" \
      --argjson report "$architecture_report" \
      '. + {($architecture): $report}' <<<"$architecture_reports")
    local_references+=("$local_reference")
  done

  index_reference=
  index_digest=
  if [[ -n ${selected_architectures[amd64]+present} \
      && -n ${selected_architectures[arm64]+present} ]]; then
    index_tag="$image_id-$release_tag"
    local_index="localhost/mitosu/$image_id:index-$release_tag-$source_short"
    run_podman manifest create "$local_index" "${local_references[@]}" >/dev/null
    index_digest_file="$staging/$image_id-index.digest"
    printf 'pushing OCI index %s:%s\n' "$repository" "$index_tag" >&2
    run_podman manifest push \
      --format oci \
      --digestfile "$index_digest_file" \
      "$local_index" \
      "docker://$repository:$index_tag"
    index_digest=$(<"$index_digest_file")
    [[ $index_digest =~ ^sha256:[a-f0-9]{64}$ ]] ||
      die "registry returned an invalid index digest for $repository:$index_tag"
    index_reference="$repository@$index_digest"
  fi

  image_report=$(jq -n \
    --arg image_id "$image_id" \
    --arg index_reference "$index_reference" \
    --arg index_digest "$index_digest" \
    --argjson architectures "$architecture_reports" \
    '{
      image_id: $image_id,
      architectures: $architectures
    }
    + if $index_digest == "" then {} else {
        index_reference: $index_reference,
        index_digest: $index_digest
      } end')
  images=$(jq -c --argjson image "$image_report" '. + [$image]' <<<"$images")
done

package_visibility=$(gh api "$package_endpoint" --jq .visibility)
release_parent=$(dirname -- "$release_directory")
mkdir -p -- "$release_parent"
chmod 0700 -- "$release_parent"
if [[ -e $release_directory ]]; then
  [[ -d $release_directory && ! -L $release_directory ]] ||
    die "release report path is not a safe directory: $release_directory"
  [[ -z $(find "$release_directory" -mindepth 1 -maxdepth 1 -print -quit) ]] ||
    die "refusing to overwrite a non-empty release report directory: $release_directory"
  chmod 0700 -- "$release_directory"
else
  mkdir -m 0700 -- "$release_directory"
fi
jq -S -n \
  --arg repository "$repository" \
  --arg release_tag "$release_tag" \
  --arg source_revision "$source_revision" \
  --arg package_visibility "$package_visibility" \
  --argjson images "$images" \
  '{
    schema_version: 1,
    repository: $repository,
    release_tag: $release_tag,
    source_revision: $source_revision,
    package_visibility: $package_visibility,
    images: $images
  }' >"$report_path"
chmod 0444 -- "$report_path"

cat "$report_path"
printf 'push report: %s\n' "$report_path" >&2
if [[ $package_visibility != public ]]; then
  printf 'warning: GHCR package visibility is %s; make %s public in GitHub package settings\n' \
    "$package_visibility" "$repository" >&2
fi
