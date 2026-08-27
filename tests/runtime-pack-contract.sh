#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPOSITORY_ROOT=$(cd -- "$TEST_DIR/.." && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$REPOSITORY_ROOT/scripts/lib/common.sh"

require_command jq
require_command openssl
staging=$(make_private_temp_dir runtime-pack-contract)
trap 'rm -rf -- "$staging"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

printf 'fixture kernel bytes\n' >"$staging/vmlinux"
printf '#!/bin/sh\nprintf "mitosurunner fixture\\n"\n' >"$staging/mitosurunner"
chmod 0755 -- "$staging/mitosurunner"
openssl genpkey -algorithm ED25519 -out "$staging/signing-key.pem" 2>/dev/null
chmod 0600 -- "$staging/signing-key.pem"

pack="$staging/apple-container-test-pack"
initfs="ghcr.io/apple/containerization/vminit@sha256:$(printf '1%.0s' {1..64})"
tool_image="ghcr.io/mitosu-cloud/runner-os-test@sha256:$(printf '2%.0s' {1..64})"
"$REPOSITORY_ROOT/scripts/generate-runtime-pack.sh" \
  --output "$pack" \
  --pack-id apple-container-test-aarch64 \
  --kernel "$staging/vmlinux" \
  --runner "$staging/mitosurunner" \
  --initfs "$initfs" \
  --tool-image "$tool_image" >/dev/null
https_pack="$staging/apple-container-https-pack"
unsafe_pack="$staging/apple-container-unsafe-pack"
cp -a -- "$pack" "$https_pack"
cp -a -- "$pack" "$unsafe_pack"
"$REPOSITORY_ROOT/scripts/sign-runtime-pack.sh" \
  --pack-dir "$pack" \
  --private-key "$staging/signing-key.pem" \
  --source "$pack" >/dev/null
"$REPOSITORY_ROOT/scripts/sign-runtime-pack.sh" \
  --pack-dir "$https_pack" \
  --private-key "$staging/signing-key.pem" \
  --source 'https://downloads.example/mitosu/apple-container-test-aarch64/' >/dev/null

validate_json_schema "$REPOSITORY_ROOT/schemas/runtime-pack.schema.json" "$pack/manifest.json"
validate_json_schema "$REPOSITORY_ROOT/schemas/release-handoff.schema.json" "$pack/release-handoff.json"
verification=$("$REPOSITORY_ROOT/scripts/verify-runtime-pack.sh" --pack-dir "$pack")
[[ $(jq -r '.status' <<<"$verification") == verified ]] || fail 'signed pack did not verify'
[[ $(jq -r '.manifest_sha256' <<<"$verification") == "$(sha256_file "$pack/manifest.json")" ]] ||
  fail 'verification returned the wrong manifest digest'
[[ $(jq -r '.public_key_hex' <<<"$verification") == "$(tr -d '[:space:]' <"$pack/ed25519-public-key.hex")" ]] ||
  fail 'verification returned the wrong public key'
[[ $(jq -r '.source.type' "$pack/release-handoff.json") == directory ]] ||
  fail 'release handoff did not retain the directory source'
[[ $(jq -r '.source.base_url' "$https_pack/release-handoff.json") == \
    'https://downloads.example/mitosu/apple-container-test-aarch64/' ]] ||
  fail 'release handoff did not retain the HTTPS source'
"$REPOSITORY_ROOT/scripts/verify-runtime-pack.sh" --pack-dir "$https_pack" >/dev/null ||
  fail 'HTTPS-source runtime pack did not verify'
[[ $(jq -r '.oci_images[] | select(.name == "tool_image") | .reference' "$pack/manifest.json") == "$tool_image" ]] ||
  fail 'runtime pack did not retain the immutable tool-image reference'
[[ ! -e $pack/signing-key.pem ]] || fail 'private signing key leaked into the runtime pack'
pass 'runtime pack generation, signing, and handoff verification pass'

cp -- "$staging/signing-key.pem" "$unsafe_pack/signing-key.pem"
if "$REPOSITORY_ROOT/scripts/sign-runtime-pack.sh" \
    --pack-dir "$unsafe_pack" \
    --private-key "$unsafe_pack/signing-key.pem" \
    --source "$unsafe_pack" \
    >"$staging/unsafe-key.stdout" 2>"$staging/unsafe-key.stderr"; then
  fail 'signer accepted a private key stored inside the runtime pack'
fi
[[ ! -e $unsafe_pack/manifest.sig ]] || fail 'rejected signing attempt left a signature behind'
pass 'runtime pack signer rejects an embedded private key'

chmod 0644 -- "$pack/kernel/vmlinux"
printf 'tamper\n' >>"$pack/kernel/vmlinux"
if "$REPOSITORY_ROOT/scripts/verify-runtime-pack.sh" --pack-dir "$pack" \
    >"$staging/tamper.stdout" 2>"$staging/tamper.stderr"; then
  fail 'tampered runtime-pack artifact was accepted'
fi
pass 'runtime pack verification rejects artifact tampering'

openssl genpkey -algorithm ED25519 -out "$staging/wrong-key.pem" 2>/dev/null
openssl pkey -in "$staging/wrong-key.pem" -pubout -outform DER -out "$staging/wrong-key.der" 2>/dev/null
wrong_public_key=$(tail -c 32 "$staging/wrong-key.der" | od -An -v -tx1 | tr -d '[:space:]')
if "$REPOSITORY_ROOT/scripts/verify-runtime-pack.sh" \
    --pack-dir "$pack" --public-key "$wrong_public_key" \
    >"$staging/wrong-key.stdout" 2>"$staging/wrong-key.stderr"; then
  fail 'runtime pack verified with an unrelated public key'
fi
pass 'runtime pack verification rejects an unrelated Ed25519 key'
