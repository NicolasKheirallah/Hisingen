#!/bin/sh
set -eu
# Answers one question in a single step: can this checkout produce App Intents metadata right
# now? Shortcuts, Siri and the Focus filter all read the app's `Metadata.appintents`, and the
# widget extension reads its own; without the second one, interactive widget buttons and Control
# Center actions have no intent to resolve. It is worth knowing in seconds instead of repeating
# the investigation recorded in docs/development/app-intents-metadata.md.
#
# Exit 0 when both bundles are present; exit 1 with the reason when they are not.

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

bundle=${1:-releases/Hisingen.app}
appex="$bundle/Contents/PlugIns/HisingenWidget.appex"
app_metadata="$bundle/Contents/Resources/Metadata.appintents"
widget_metadata="$appex/Contents/Resources/Metadata.appintents"

count_intents() {
    python3 - "$1" <<'PY'
import json
import sys

document = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(document.get("actions") or {}))
PY
}

app_ok=false
if [ -d "$app_metadata" ]; then
    echo "OK   App Metadata.appintents is present in $bundle"
    for entry in "$app_metadata"/*; do
        [ -e "$entry" ] || continue
        printf '     %s\n' "${entry##*/}"
    done
    if [ -f "$app_metadata/extract.actionsdata" ]; then
        printf '     %s intents\n' "$(count_intents "$app_metadata/extract.actionsdata")"
    fi
    app_ok=true
else
    if [ -d "$bundle" ]; then
        echo "MISSING  $bundle has no Contents/Resources/Metadata.appintents"
        echo "         The app's intents are therefore invisible to Shortcuts, Siri and Focus."
    else
        echo "MISSING  $bundle does not exist yet; build it with 'make app' first."
    fi
fi

if [ -d "$appex" ]; then
    if [ -d "$widget_metadata" ]; then
        echo "OK   Widget Metadata.appintents is present in $appex"
        printf '     %s intents\n' "$(count_intents "$widget_metadata/extract.actionsdata")"
    else
        echo "MISSING  $appex has no Contents/Resources/Metadata.appintents"
        echo "         Interactive widget buttons and Control Center actions cannot resolve an intent."
    fi
else
    echo "MISSING  $appex does not exist yet; build it with 'make app' first."
fi

if [ "$app_ok" = true ]; then
    if [ -d "$widget_metadata" ]; then
        exit 0
    fi
    echo "BLOCKED  The app's metadata is present but the extension's is not. Rebuild with"
    echo "         'make app' (without SKIP_APPINTENTS=1) to produce both."
    exit 1
fi

processor=$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)
if [ -z "$processor" ]; then
    echo "BLOCKED  appintentsmetadataprocessor is not installed (needs Xcode, not Command Line Tools)."
    exit 1
fi

# The processor is the authority on whether a run can succeed. Run it the way a build would and
# report its own verdict, so this script never guesses about toolchain behavior.
intent_sources=$(find Sources/Hisingen -name '*.swift' \
    \( -path '*AppIntents*' -o -path '*App/*Intent*' \) | sort)
if [ -z "$intent_sources" ]; then
    echo "BLOCKED  No App Intents sources found; nothing to extract."
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/hisingen-appintents.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
printf '%s\n' "$intent_sources" > "$tmp/sources.txt"

toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
sdk=$(xcrun --sdk macosx --show-sdk-path)
version=$(xcodebuild -version -build 2>/dev/null | tr '\n' ' ' | sed 's/Trailing.*//')
version=$(printf '%s' "$version" | cut -d' ' -f1)

set +e
verdict=$("$processor" \
    --module-name Hisingen \
    --output "$tmp/out" \
    --source-file-list "$tmp/sources.txt" \
    --toolchain-dir "$toolchain" \
    --sdk-root "$sdk" \
    --deployment-target 15.0 \
    --target-triple arm64-apple-macos15.0 \
    --platform-family macos \
    --xcode-version "$version" \
    --compile-time-extraction \
    --force 2>&1)
code=$?
set -e

if [ -d "$tmp/out/Metadata.appintents" ]; then
    echo "PRODUCIBLE  The processor wrote metadata from the sources alone."
    echo "            Wire this into the bundle; see docs/development/app-intents-metadata.md."
    exit 0
fi

echo "BLOCKED  The processor produced no metadata (exit $code). Its own words:"
printf '%s\n' "$verdict" | sed 's/^/         /'
echo ""
echo "This is the known SwiftPM limitation recorded in docs/development/app-intents-metadata.md:"
echo "the processor needs Swift compiler const values, and a SwiftPM build does not produce them."
exit 1
