#!/bin/sh
set -eu

VERSION=${1:?Usage: extract-release-notes.sh VERSION CHANGELOG OUTPUT}
CHANGELOG=${2:?missing changelog path}
OUTPUT=${3:?missing output path}

[ -s "$CHANGELOG" ] || { echo "Missing changelog: $CHANGELOG" >&2; exit 1; }

# Headings in this repository include a release date. Match the complete bracketed
# version prefix, and stop before printing the next release's heading.
awk -v version="$VERSION" '
    BEGIN { target = "## [" version "]" }
    capture && $0 ~ /^## \[/ && index($0, target) != 1 { exit }
    index($0, target) == 1 { capture = 1 }
    capture { print }
' "$CHANGELOG" > "$OUTPUT"

[ -s "$OUTPUT" ] || {
    echo "$CHANGELOG has no release notes for $VERSION" >&2
    exit 1
}
