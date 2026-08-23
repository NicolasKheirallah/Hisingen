#!/bin/sh
# Updates the version and sha256 of the hisingen cask inside a homebrew-tap
# checkout. Platform-neutral: the caller computes the checksum.
#
# Usage: update-homebrew-cask.sh VERSION SHA256 [PATH_TO_TAP_CHECKOUT]
#
# Used by .github/workflows/release.yml ("homebrew-tap" job) and can be run
# locally after a release:
#   gh release download vX.Y.Z --repo NicolasKheirallah/Hisingen --pattern 'Hisingen.dmg'
#   SHASUM=$(shasum -a 256 Hisingen.dmg | cut -d' ' -f1)
#   git clone git@github.com:NicolasKheirallah/homebrew-tap.git /tmp/tap
#   sh Scripts/update-homebrew-cask.sh X.Y.Z "$SHASUM" /tmp/tap
set -eu

if [ "$#" -lt 2 ]; then
	echo "Usage: $0 VERSION SHA256 [PATH_TO_TAP_CHECKOUT]" >&2
	exit 1
fi

VERSION="$1"
SHA256="$2"
TAP_DIR="${3:-.}"

case "$VERSION" in
[0-9]*.[0-9]*.[0-9]*) ;;
*)
	echo "error: VERSION must be MAJOR.MINOR.PATCH, got '$VERSION'" >&2
	exit 1
	;;
esac

if [ "${#SHA256}" -ne 64 ] || ! printf '%s' "$SHA256" | grep -Eq '^[0-9a-f]+$'; then
	echo "error: SHA256 must be 64 lowercase hex characters" >&2
	exit 1
fi

CASK="$TAP_DIR/Casks/hisingen.rb"
if [ ! -f "$CASK" ]; then
	echo "error: $CASK not found — pass the tap checkout path as argument 3" >&2
	exit 1
fi

command -v perl >/dev/null 2>&1 || {
	echo "error: perl is required" >&2
	exit 1
}

perl -pi -e "s{^  version \".*\"\$}{  version \"$VERSION\"}" "$CASK"
perl -pi -e "s{^  sha256 \"[0-9a-f]{64}\"\$}{  sha256 \"$SHA256\"}" "$CASK"

grep -Fq "version \"$VERSION\"" "$CASK" || {
	echo "error: failed to update version line in $CASK" >&2
	exit 1
}
grep -Fq "sha256 \"$SHA256\"" "$CASK" || {
	echo "error: failed to update sha256 line in $CASK" >&2
	exit 1
}

echo "==> Updated $CASK to version $VERSION"
git -C "$TAP_DIR" diff --no-color -- Casks/hisingen.rb 2>/dev/null || true
