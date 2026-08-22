#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
usage: verify-runtime-pack.sh --pack-dir DIRECTORY [--public-key LOWERCASE-HEX]

If --public-key is omitted, ed25519-public-key.hex is read from the pack.
EOF
}

pack_dir=
public_key_hex=

while (($# > 0)); do
  case "$1" in
    --pack-dir)
      (($# >= 2)) || die '--pack-dir requires a value'
      pack_dir=$2
      shift 2
      ;;
    --public-key)
      (($# >= 2)) || die '--public-key requires a value'
      public_key_hex=$2
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
require_command openssl
require_command realpath
require_command jsonschema

[[ -n $pack_dir ]] || die '--pack-dir is required'
pack_dir=$(realpath -e -- "$pack_dir")
[[ -d $pack_dir && ! -L $pack_dir ]] || die '--pack-dir must be a non-symlink directory'
for control_file in manifest.json manifest.sig; do
  [[ -f $pack_dir/$control_file && ! -L $pack_dir/$control_file ]] ||
    die "$control_file is missing or unsafe"
done
if [[ -z $public_key_hex ]]; then
  [[ -f $pack_dir/ed25519-public-key.hex && ! -L $pack_dir/ed25519-public-key.hex ]] ||
    die 'ed25519-public-key.hex is missing or unsafe'
  public_key_hex=$(<"$pack_dir/ed25519-public-key.hex")
fi
[[ $public_key_hex =~ ^[a-f0-9]{64}$ ]] || die 'Ed25519 public key must be 64 lowercase hexadecimal characters'

validate_json_schema "$REPOSITORY_ROOT/schemas/runtime-pack.schema.json" "$pack_dir/manifest.json"
signature_hex=$(<"$pack_dir/manifest.sig")
[[ $signature_hex =~ ^[a-f0-9]{128}$ ]] || die 'manifest signature must be 128 lowercase hexadecimal characters'

staging=$(make_private_temp_dir runtime-pack-verify)
trap 'rm -rf -- "$staging"' EXIT

hex_to_binary() {
  local value=$1
  local offset

  (( ${#value} % 2 == 0 )) || die 'hexadecimal input has an odd length'
  for ((offset = 0; offset < ${#value}; offset += 2)); do
    printf '%b' "\\x${value:offset:2}"
  done
}

public_der="$staging/public.der"
signature_raw="$staging/signature.raw"
hex_to_binary "302a300506032b6570032100$public_key_hex" >"$public_der"
hex_to_binary "$signature_hex" >"$signature_raw"
openssl pkeyutl -verify -rawin -pubin -keyform DER \
  -inkey "$public_der" \
  -sigfile "$signature_raw" \
  -in "$pack_dir/manifest.json" >/dev/null || die 'manifest Ed25519 signature is invalid'

declare -A artifact_names=()
declare -A portable_paths=()
artifact_paths=()
total_size=0
while IFS=$'\t' read -r name relative_path expected_size expected_sha256 executable; do
  [[ -z ${artifact_names[$name]+present} ]] || die "duplicate artifact name: $name"
  artifact_names[$name]=present
  portable_path=${relative_path,,}
  [[ -z ${portable_paths[$portable_path]+present} ]] || die "duplicate or case-colliding artifact path: $relative_path"
  portable_paths[$portable_path]=present
  case "$portable_path/" in
    manifest.json/* | manifest.sig/* | complete/*)
      die "artifact path overlaps a runtime-pack control file: $relative_path"
      ;;
  esac
  artifact_paths+=("$portable_path")

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
  [[ $(sha256_file "$current_path") == "$expected_sha256" ]] || die "artifact SHA-256 mismatch: $relative_path"
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

manifest_sha256=$(sha256_file "$pack_dir/manifest.json")
pack_id=$(jq -er '.pack_id' "$pack_dir/manifest.json")
if [[ -e $pack_dir/release-handoff.json ]]; then
  [[ -f $pack_dir/release-handoff.json && ! -L $pack_dir/release-handoff.json ]] || die 'release-handoff.json is unsafe'
  validate_json_schema "$REPOSITORY_ROOT/schemas/release-handoff.schema.json" "$pack_dir/release-handoff.json"
  [[ $(jq -er '.pack_id' "$pack_dir/release-handoff.json") == "$pack_id" ]] || die 'release handoff pack ID mismatch'
  [[ $(jq -er '.manifest_sha256' "$pack_dir/release-handoff.json") == "$manifest_sha256" ]] || die 'release handoff manifest SHA-256 mismatch'
  [[ $(jq -er '.public_key_hex' "$pack_dir/release-handoff.json") == "$public_key_hex" ]] || die 'release handoff public key mismatch'
fi

jq -S -n \
  --arg pack_id "$pack_id" \
  --arg manifest_sha256 "$manifest_sha256" \
  --arg public_key_hex "$public_key_hex" \
  '{
    status: "verified",
    pack_id: $pack_id,
    manifest_sha256: $manifest_sha256,
    public_key_hex: $public_key_hex
  }'
