#!/usr/bin/env bash
# Install the reviewed GitHub CLI release without mutating the runner image.
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

(($# == 1)) || die 'usage: install-pinned-gh.sh ABSOLUTE-DESTINATION'
destination=$1
[[ $destination == /* && $destination != / && ! -L $destination ]] ||
  die 'GitHub CLI destination must be an absolute, non-symlink directory'

require_command curl
require_command tar
require_command uname

readonly version=2.100.0
case $(uname -m) in
  aarch64 | arm64)
    readonly architecture=arm64
    readonly expected_sha256=ea4e7a581a32ccad6cc7923cb1576ac5859ba4b9a16ab22eb8f8a96e78e2e961
    ;;
  x86_64 | amd64)
    readonly architecture=amd64
    readonly expected_sha256=e4d4bb4498e8d007abe545b6568926793ace1b6447da598294a610018cb164be
    ;;
  *) die "unsupported GitHub CLI architecture: $(uname -m)" ;;
esac

archive="gh_${version}_linux_${architecture}.tar.gz"
download_url="https://github.com/cli/cli/releases/download/v${version}/${archive}"
staging=$(mktemp -d -- /tmp/mitosu-gh-cli.XXXXXXXX)
trap 'rm -rf -- "$staging"' EXIT

curl --fail --location --max-redirs 3 \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --retry 5 --retry-all-errors \
  --output "$staging/$archive" "$download_url"
actual_sha256=$(sha256_file "$staging/$archive")
[[ $actual_sha256 == "$expected_sha256" ]] || die 'GitHub CLI archive checksum mismatch'

tar --extract --gzip --file "$staging/$archive" --directory "$staging" --no-same-owner
source_binary="$staging/gh_${version}_linux_${architecture}/bin/gh"
[[ -f $source_binary && -x $source_binary && ! -L $source_binary ]] ||
  die 'GitHub CLI archive did not contain the expected executable'
install -d -m 0700 -- "$destination"
install -m 0755 -- "$source_binary" "$destination/gh"
installed_version=$("$destination/gh" --version)
[[ ${installed_version%%$'\n'*} == "gh version $version "* ]] ||
  die 'installed GitHub CLI did not report the pinned version'
