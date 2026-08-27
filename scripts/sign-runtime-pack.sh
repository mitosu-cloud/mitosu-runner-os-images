#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
usage: sign-runtime-pack.sh \
  --pack-dir DIRECTORY \
  --private-key ED25519-PEM \
  --source HTTPS-DIRECTORY-URL|ABSOLUTE-DIRECTORY

Writes manifest.sig, ed25519-public-key.hex, and release-handoff.json without
ever copying the private key into the runtime pack.
EOF
}

pack_dir=
private_key=
source_value=

while (($# > 0)); do
  case "$1" in
    --pack-dir)
      (($# >= 2)) || die '--pack-dir requires a value'
      pack_dir=$2
      shift 2
      ;;
    --private-key)
      (($# >= 2)) || die '--private-key requires a value'
      private_key=$2
      shift 2
      ;;
    --source)
      (($# >= 2)) || die '--source requires a value'
      source_value=$2
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
[[ -n $private_key ]] || die '--private-key is required'
[[ -n $source_value ]] || die '--source is required'
pack_dir=$(realpath -e -- "$pack_dir")
private_key=$(realpath -e -- "$private_key")
[[ -d $pack_dir && ! -L $pack_dir ]] || die '--pack-dir must be a non-symlink directory'
[[ -f $private_key && ! -L $private_key ]] || die '--private-key must be a regular non-symlink file'
case "$private_key" in
  "$pack_dir"/*) die '--private-key must be outside the runtime pack' ;;
esac
[[ -f $pack_dir/manifest.json && ! -L $pack_dir/manifest.json ]] || die 'manifest.json is missing or unsafe'
for output_name in manifest.sig ed25519-public-key.hex release-handoff.json; do
  [[ ! -e $pack_dir/$output_name ]] || die "refusing to overwrite $pack_dir/$output_name"
done

validate_json_schema "$REPOSITORY_ROOT/schemas/runtime-pack.schema.json" "$pack_dir/manifest.json"
openssl pkey -in "$private_key" -check -noout >/dev/null

staging=$(make_private_temp_dir runtime-pack-sign)
outputs_installed=false
cleanup() {
  rm -rf -- "$staging"
  if [[ $outputs_installed == true ]]; then
    rm -f -- \
      "$pack_dir/manifest.sig" \
      "$pack_dir/ed25519-public-key.hex" \
      "$pack_dir/release-handoff.json"
  fi
}
trap cleanup EXIT
public_der="$staging/public.der"
signature_raw="$staging/signature.raw"
openssl pkey -in "$private_key" -pubout -outform DER -out "$public_der"
[[ $(wc -c <"$public_der") -eq 44 ]] || die 'signing key is not an Ed25519 key'
der_prefix=$(dd if="$public_der" bs=1 count=12 2>/dev/null | od -An -v -tx1 | tr -d '[:space:]')
[[ $der_prefix == 302a300506032b6570032100 ]] || die 'signing key is not an Ed25519 key'
public_key_hex=$(tail -c 32 "$public_der" | od -An -v -tx1 | tr -d '[:space:]')
[[ $public_key_hex =~ ^[a-f0-9]{64}$ ]] || die 'could not extract the Ed25519 public key'

openssl pkeyutl -sign -rawin \
  -inkey "$private_key" \
  -in "$pack_dir/manifest.json" \
  -out "$signature_raw"
[[ $(wc -c <"$signature_raw") -eq 64 ]] || die 'Ed25519 signature has the wrong size'
openssl pkeyutl -verify -rawin -pubin -keyform DER \
  -inkey "$public_der" \
  -sigfile "$signature_raw" \
  -in "$pack_dir/manifest.json" >/dev/null
signature_hex=$(od -An -v -tx1 "$signature_raw" | tr -d '[:space:]')
manifest_sha256=$(sha256_file "$pack_dir/manifest.json")
pack_id=$(jq -er '.pack_id' "$pack_dir/manifest.json")

if [[ $source_value == https://* ]]; then
  [[ $source_value == */ ]] || die 'HTTPS runtime-pack source must end with /'
  [[ $source_value != *\?* && $source_value != *\#* ]] || die 'HTTPS runtime-pack source cannot contain a query or fragment'
  authority=${source_value#https://}
  authority=${authority%%/*}
  [[ -n $authority && $authority != *@* ]] || die 'HTTPS runtime-pack source cannot contain credentials'
  source_json=$(jq -cn --arg base_url "$source_value" '{type: "https", base_url: $base_url}')
elif [[ $source_value == /* ]]; then
  source_directory=$(realpath -e -- "$source_value")
  [[ -d $source_directory && ! -L $source_directory ]] || die 'directory runtime-pack source must be a non-symlink directory'
  [[ $source_directory == "$pack_dir" ]] || die 'directory runtime-pack source must identify --pack-dir exactly'
  source_json=$(jq -cn --arg path "$source_directory" '{type: "directory", path: $path}')
else
  die '--source must be an HTTPS directory URL or absolute directory path'
fi

printf '%s\n' "$signature_hex" >"$staging/manifest.sig"
printf '%s\n' "$public_key_hex" >"$staging/ed25519-public-key.hex"
jq -S -n \
  --arg pack_id "$pack_id" \
  --argjson source "$source_json" \
  --arg manifest_sha256 "$manifest_sha256" \
  --arg public_key_hex "$public_key_hex" \
  '{
    schema_version: 1,
    pack_id: $pack_id,
    source: $source,
    manifest_sha256: $manifest_sha256,
    public_key_hex: $public_key_hex
  }' >"$staging/release-handoff.json"
validate_json_schema "$REPOSITORY_ROOT/schemas/release-handoff.schema.json" "$staging/release-handoff.json"

install -m 0444 -- "$staging/manifest.sig" "$pack_dir/manifest.sig"
install -m 0444 -- "$staging/ed25519-public-key.hex" "$pack_dir/ed25519-public-key.hex"
install -m 0444 -- "$staging/release-handoff.json" "$pack_dir/release-handoff.json"
outputs_installed=true
"$SCRIPT_DIR/verify-runtime-pack.sh" \
  --pack-dir "$pack_dir" \
  --public-key "$public_key_hex" >/dev/null
outputs_installed=false
rm -rf -- "$staging"
trap - EXIT
cat "$pack_dir/release-handoff.json"
