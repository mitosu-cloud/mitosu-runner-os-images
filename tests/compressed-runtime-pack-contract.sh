#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPOSITORY_ROOT=$(cd -- "$TEST_DIR/.." && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$REPOSITORY_ROOT/scripts/lib/common.sh"
staging=$(make_private_temp_dir compressed-runtime-pack)
trap 'rm -rf -- "$staging"' EXIT
printf '[]\n' >"$staging/images.json"
printf '#!/bin/sh\nexit 0\n' >"$staging/host"
python3 - "$staging/rootfs" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'guest filesystem fixture' * 170000 + bytes(1024 * 1024))
PY
pack="$staging/pack"
"$REPOSITORY_ROOT/scripts/assemble-runtime-pack.sh" \
  --output "$pack" --pack-id compressed-fixture --target-os linux --target-arch x86_64 \
  --oci-images "$staging/images.json" --compression zstd \
  --artifact runner_vm_host "$staging/host" bin/mitosu-libkrun-host true \
  --artifact runner_rootfs "$staging/rootfs" images/root.ext4 false >/dev/null
[[ ! -e $pack/images/root.ext4 && -f $pack/runner_rootfs.zst ]] || die 'source pack retained an expanded disk'
[[ $(jq -r .schema_version "$pack/manifest.json") == 3 ]] || die 'compressed pack is not schema 3'
"$REPOSITORY_ROOT/scripts/verify-runtime-pack-candidate.sh" --pack-dir "$pack" >/dev/null
printf 'ok - compressed source inventory verifies expanded bytes and executable intent\n'

for variant in corrupt truncated concatenated oversized expanded-hash transport-path old-schema; do
  copy="$staging/$variant"
  cp -a -- "$pack" "$copy"
  python3 - "$copy" "$variant" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root = Path(sys.argv[1]); variant = sys.argv[2]
manifest = json.loads((root / 'manifest.json').read_text()); item = manifest['artifacts'][1]
payload = root / item['transport']['path']
if variant in ('corrupt', 'truncated', 'concatenated'):
    data = payload.read_bytes()
    if variant == 'corrupt': data = bytes([data[0] ^ 255]) + data[1:]
    elif variant == 'truncated': data = data[:-1]
    else: data += data
    payload.chmod(0o600); payload.write_bytes(data); payload.chmod(0o444)
    # Authenticate the bad transport so validation must actually decode it.
    item['transport']['size'] = len(data); item['transport']['sha256'] = hashlib.sha256(data).hexdigest()
elif variant == 'oversized': item['size'] -= 1
elif variant == 'expanded-hash': item['sha256'] = '0' * 64
elif variant == 'transport-path': item['transport']['path'] = 'manifest.json'
else: manifest['schema_version'] = 1
path = root / 'manifest.json'; path.chmod(0o600); path.write_text(json.dumps(manifest)); path.chmod(0o444)
PY
  if "$REPOSITORY_ROOT/scripts/verify-runtime-pack-candidate.sh" --pack-dir "$copy" \
      >"$staging/$variant.stdout" 2>"$staging/$variant.stderr"; then
    die "compressed verifier accepted $variant"
  fi
  printf 'ok - compressed verifier rejects %s\n' "$variant"
done

tar -C "$staging" -czf "$staging/candidate.tar.gz" pack
"$REPOSITORY_ROOT/scripts/extract-runtime-pack-candidate.py" "$staging/candidate.tar.gz" "$staging/extracted"
"$REPOSITORY_ROOT/scripts/verify-runtime-pack-candidate.sh" --pack-dir "$staging/extracted/pack" >/dev/null
openssl genpkey -algorithm ED25519 -out "$staging/key.pem" 2>/dev/null
"$REPOSITORY_ROOT/scripts/sign-runtime-pack.sh" --pack-dir "$pack" --private-key "$staging/key.pem" \
  --source https://github.com/mitosu-cloud/mitosu-runner-os-images/releases/download/runtime-pack-compressed-fixture/ >/dev/null
"$REPOSITORY_ROOT/scripts/verify-runtime-pack.sh" --pack-dir "$pack" >/dev/null
printf 'ok - compressed candidate survives archive extraction and signed GitHub handoff\n'

python3 - "$REPOSITORY_ROOT" <<'PY'
import importlib.util
from pathlib import Path
import sys
from urllib.error import HTTPError
from urllib.request import Request
spec = importlib.util.spec_from_file_location('release_fetch', Path(sys.argv[1]) / 'scripts/fetch-runtime-pack-release.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
assert module.release_base_valid('https://github.com/mitosu-cloud/mitosu-runner-os-images/releases/download/runtime-pack-fixture/')
for url in ['https://github.com/o/r/releases/latest/', 'https://github.com/o/r/releases/download/latest/', 'https://github.com/o/r/releases/download/a%2Fb/', 'https://github.com.evil.example/o/r/releases/download/tag/']:
    assert not module.release_base_valid(url), url
assert module.redirect_allowed('https://release-assets.githubusercontent.com/file?fixture=1')
for url in ['http://objects.githubusercontent.com/file', 'https://objects.githubusercontent.com.evil.example/file', 'https://github.com/login', 'https://objects.githubusercontent.com:444/file', 'https://user@objects.githubusercontent.com/file']:
    assert not module.redirect_allowed(url), url
handler = module.GitHubAssetRedirects()
request = Request('https://github.com/o/r/releases/download/tag/file')
for _ in range(3): handler.redirect_request(request, None, 302, '', {}, 'https://objects.githubusercontent.com/file')
try: handler.redirect_request(request, None, 302, '', {}, 'https://objects.githubusercontent.com/file')
except HTTPError: pass
else: raise AssertionError('redirect loop was not bounded')
PY
printf 'ok - public delivery rejects redirect escapes, mutable aliases and redirect loops\n'
