#!/bin/sh
set -eu
# Build App Intents metadata for the Hisingen module.
#
# Why this exists: `appintentsmetadataprocessor` reads per-type constant values that the compiler
# extracts (titles, parameter names, shortcut phrases). SwiftPM has no setting that asks for them,
# so Shortcuts, Siri, the Focus filter and interactive widget buttons cannot discover the app's
# intents without this step.
#
# How: the release build compiles the module whole, in one `swift-frontend -c -filelist` call. This
# script reuses that exact command from SwiftPM's own verbose output, adds the constant-value flags,
# and compiles to /dev/null — only the constant values are wanted, so no second copy of the module
# lands in the build. The processor then turns those values into Metadata.appintents.
#
# Usage: generate-appintents-metadata.sh --output DIR [--scratch-path DIR]

OUTPUT=''
SCRATCH=''
while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUTPUT=${2:?--output needs a directory}; shift 2 ;;
        --scratch-path) SCRATCH=${2:?--scratch-path needs a directory}; shift 2 ;;
        *) echo "usage: $0 --output DIR [--scratch-path DIR]" >&2; exit 2 ;;
    esac
done
[ -n "$OUTPUT" ] || { echo "generate-appintents-metadata: --output is required" >&2; exit 2; }

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

command -v python3 >/dev/null 2>&1 || {
    echo "generate-appintents-metadata: python3 is required" >&2
    exit 1
}

if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR=$(xcode-select -p)
    export DEVELOPER_DIR
fi
SDK=$(xcrun --sdk macosx --show-sdk-path)
TOOLCHAIN_DIR="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain"
XCODE_CONTENTS=$(dirname "$DEVELOPER_DIR")
XCODE_BUILD=$(defaults read "$XCODE_CONTENTS/version.plist" ProductBuildVersion 2>/dev/null || true)
[ -n "$XCODE_BUILD" ] || {
    echo "generate-appintents-metadata: cannot read the Xcode build version from $XCODE_CONTENTS" >&2
    exit 1
}

if [ -z "$SCRATCH" ]; then
    for candidate in .build .build-arm64 .build-x86_64; do
        if [ -d "$candidate" ]; then SCRATCH=$candidate; break; fi
    done
fi
[ -n "$SCRATCH" ] || {
    echo "generate-appintents-metadata: no SwiftPM build found; run 'make build' first" >&2
    exit 1
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/hisingen-appintents.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# The compile flags are identical for every run of the same dependency graph, so they are cached
# under the scratch path. Without the cache a clean checkout would pay for one extra module
# rebuild just to read a command line.
FLAGS_CACHE="$SCRATCH/hisingen-appintents-flags.txt"
GRAPH_KEY=$(cat Package.swift Package.resolved 2>/dev/null | shasum -a 256 | cut -d' ' -f1)

flags_are_current() {
    [ -f "$FLAGS_CACHE" ] || return 1
    head -n 1 "$FLAGS_CACHE" | grep -qx "graph=$GRAPH_KEY" || return 1
    return 0
}

if ! flags_are_current; then
    # SwiftPM prints the module's compile command only when it compiles something. Touching the
    # intent file first guarantees the line is there; content and checksum are unchanged.
    touch Sources/Hisingen/App/AppIntents.swift
    if ! swift build -c release -v --scratch-path "$SCRATCH" >"$WORK/build.log" 2>&1; then
        echo "generate-appintents-metadata: swift build failed" >&2
        tail -n 20 "$WORK/build.log" >&2
        exit 1
    fi
    if COMMAND=$(python3 Scripts/appintents-capture-flags.py "$WORK/build.log"); then
        {
            printf 'graph=%s\n' "$GRAPH_KEY"
            printf '%s\n' "$COMMAND"
        } >"$FLAGS_CACHE"
    else
        echo "generate-appintents-metadata: could not read the module compile command" >&2
        exit 1
    fi
fi

COMMAND=$(tail -n 1 "$FLAGS_CACHE")

python3 Scripts/appintents-compile-consts.py \
    --command "$COMMAND" \
    --protocols "$WORK/protocols.json" \
    --const-values "$WORK/constvalues.json" \
    --object-output "$WORK/objects" \
    --source-list "$WORK/sources.txt" \
    --root "$ROOT"

xcrun appintentsmetadataprocessor \
    -o "$WORK/out" \
    -c "$TOOLCHAIN_DIR" \
    -m Hisingen \
    -r "$SDK" \
    -xcv "$XCODE_BUILD" \
    -pf macOS \
    -dt 15.0 \
    -t arm64-apple-macosx15.0 \
    -sl "$WORK/sources.txt" \
    -scl "$WORK/constvalues.json.list" \
    --quiet-warnings

[ -f "$WORK/out/Metadata.appintents/version.json" ] || {
    echo "generate-appintents-metadata: the processor produced no metadata bundle" >&2
    exit 1
}

rm -rf "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
ditto "$WORK/out/Metadata.appintents" "$OUTPUT"
echo "generate-appintents-metadata: wrote $OUTPUT"
