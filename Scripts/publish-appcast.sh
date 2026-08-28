#!/bin/sh
set -eu

# Generates one signed stable appcast item for the release being built. The appcast is
# generated from the signed archive rather than hand-authored, so its Ed25519 signature,
# byte length and release-notes signatures cannot drift from the uploaded asset.
TOOLS_DIR=${1:?Usage: publish-appcast.sh SPARKLE_TOOLS_DIR VERSION RELEASE_TAG ARCHIVE OUTPUT_DIR PRIVATE_KEY_FILE}
VERSION=${2:?missing version}
RELEASE_TAG=${3:?missing release tag}
ARCHIVE=${4:?missing archive}
OUTPUT_DIR=${5:?missing output directory}
PRIVATE_KEY_FILE=${6:?missing Sparkle private-key file}

for tool in "$TOOLS_DIR/bin/generate_appcast"; do
    [ -x "$tool" ] || { echo "Missing Sparkle tool: $tool" >&2; exit 1; }
done
[ -s "$ARCHIVE" ] || { echo "Missing Sparkle update archive: $ARCHIVE" >&2; exit 1; }
[ -s "$PRIVATE_KEY_FILE" ] || { echo "Missing Sparkle private-key file: $PRIVATE_KEY_FILE" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/hisingen-appcast.XXXXXX")
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT HUP INT TERM

cp "$ARCHIVE" "$STAGING/Hisingen.app.zip"
# Sparkle 2.9 renders Markdown release notes natively. Preserve the matching changelog
# section only, so users see clean headings/lists instead of a GitHub API response.
sh Scripts/extract-release-notes.sh "$VERSION" CHANGELOG.md "$STAGING/Hisingen.app.md"

DOWNLOAD_PREFIX="https://github.com/NicolasKheirallah/Hisingen/releases/download/$RELEASE_TAG/"
"$TOOLS_DIR/bin/generate_appcast" \
    --ed-key-file "$PRIVATE_KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --release-notes-url-prefix "$DOWNLOAD_PREFIX" \
    --full-release-notes-url "https://github.com/NicolasKheirallah/Hisingen/blob/main/CHANGELOG.md" \
    --maximum-deltas 0 \
    "$STAGING"

[ -s "$STAGING/appcast.xml" ] || { echo 'Sparkle did not generate appcast.xml' >&2; exit 1; }
cp "$STAGING/appcast.xml" "$OUTPUT_DIR/appcast.xml"
cp "$STAGING/Hisingen.app.md" "$OUTPUT_DIR/Hisingen.app.md"
echo "Sparkle appcast generated for Hisingen $VERSION"
