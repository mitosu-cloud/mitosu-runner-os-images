#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 022

: "${IMAGE_ID:?IMAGE_ID is required}"
: "${DISTRIBUTION:?DISTRIBUTION is required}"
: "${DISTRIBUTION_VERSION:?DISTRIBUTION_VERSION is required}"
: "${TARGET_ARCH:?TARGET_ARCH is required}"
: "${DEVELOPMENT_PROFILE:?DEVELOPMENT_PROFILE is required}"
: "${PROFILE_REVISION:?PROFILE_REVISION is required}"
: "${RUNNER_SOURCE_DIGEST:?RUNNER_SOURCE_DIGEST is required}"
: "${SOURCE_REVISION:?SOURCE_REVISION is required}"
: "${LOCK_DIGEST:?LOCK_DIGEST is required}"
: "${CAPABILITIES_JSON:?CAPABILITIES_JSON is required}"
: "${TOOLCHAINS_JSON:?TOOLCHAINS_JSON is required}"

install -d -m 0755 /usr/share/mitosu
jq -n \
  --arg image_id "$IMAGE_ID" \
  --arg distribution "$DISTRIBUTION" \
  --arg distribution_version "$DISTRIBUTION_VERSION" \
  --arg architecture "$TARGET_ARCH" \
  --arg development_profile "$DEVELOPMENT_PROFILE" \
  --arg runner_source_digest "$RUNNER_SOURCE_DIGEST" \
  --arg source_revision "$SOURCE_REVISION" \
  --arg lock_digest "$LOCK_DIGEST" \
  --argjson profile_revision "$PROFILE_REVISION" \
  --argjson capabilities "$CAPABILITIES_JSON" \
  --argjson toolchains "$TOOLCHAINS_JSON" \
  '{
    schema_version: 1,
    image_id: $image_id,
    profile_revision: $profile_revision,
    distribution: $distribution,
    distribution_version: $distribution_version,
    architecture: $architecture,
    development_profile: $development_profile,
    runner_protocol: "mitosu.runner.v1",
    runner_source_digest: $runner_source_digest,
    tool_user: {name: "mitosu", uid: 1000, gid: 1000},
    capabilities: $capabilities,
    toolchains: $toolchains,
    source_revision: $source_revision,
    lock_digest: $lock_digest
  }' > /usr/share/mitosu/image.json

chmod 0644 /usr/share/mitosu/image.json
