#!/bin/sh
set -eu
# Build App Intents metadata for a SwiftPM module.
#
# Why this exists: `appintentsmetadataprocessor` reads per-type constant values that the compiler
# extracts (titles, parameter names, shortcut phrases). SwiftPM has no setting that asks for them,
# so Shortcuts, Siri, the Focus filter and interactive widget buttons cannot discover any intent
# without this step.
#
# How: the release build compiles a module whole, in one `swift-frontend -c -filelist` call. This
# script reuses that exact command from SwiftPM's own verbose output, adds the constant-value
# flags, and compiles to /dev/null — only the constant values are wanted, so no second copy of the
# module lands in the build. The processor then turns those values into Metadata.appintents.
#
# Modules:
#   Hisingen          the app (default)
#   HisingenIntents   the shared intent module the widget extension links
#   HisingenWidget    the widget extension itself; pass --dependency-metadata so the shared
#                     module's intents are folded into the extension's bundle
#
# Usage: generate-appintents-metadata.sh --output DIR
#            [--module NAME] [--source-directory DIR] [--dependency-metadata DIR]
#            [--scratch-path DIR]

OUTPUT=''
SCRATCH=''
MODULE='Hisingen'
SOURCE_DIRECTORY='Sources/Hisingen'
DEPENDENCY_METADATA=''
while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUTPUT=${2:?--output needs a directory}; shift 2 ;;
        --scratch-path) SCRATCH=${2:?--scratch-path needs a directory}; shift 2 ;;
        --module) MODULE=${2:?--module needs a name}; shift 2 ;;
        --source-directory) SOURCE_DIRECTORY=${2:?--source-directory needs a path}; shift 2 ;;
        --dependency-metadata) DEPENDENCY_METADATA=${2:?--dependency-metadata needs a directory}; shift 2 ;;
        *) echo "usage: $0 --output DIR [--module NAME] [--source-directory DIR] [--dependency-metadata DIR] [--scratch-path DIR]" >&2; exit 2 ;;
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

[ -d "$SOURCE_DIRECTORY" ] || {
    echo "generate-appintents-metadata: no source directory at $SOURCE_DIRECTORY" >&2
    exit 1
}
if [ -n "$DEPENDENCY_METADATA" ] && [ ! -d "$DEPENDENCY_METADATA" ]; then
    echo "generate-appintents-metadata: dependency metadata not found at $DEPENDENCY_METADATA" >&2
    exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/hisingen-appintents.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# The compile flags are identical for every run of the same module and dependency graph, so they
# are cached under the scratch path. Without the cache a clean checkout would pay for one extra
# module rebuild just to read a command line. Each module keeps its own cache: the same build log
# carries one compile command per module.
FLAGS_CACHE="$SCRATCH/hisingen-appintents-flags-$MODULE.txt"
GRAPH_KEY=$(cat Package.swift Package.resolved 2>/dev/null | shasum -a 256 | cut -d' ' -f1)

flags_are_current() {
    [ -f "$FLAGS_CACHE" ] || return 1
    head -n 1 "$FLAGS_CACHE" | grep -qx "graph=$GRAPH_KEY" || return 1
    head -n 2 "$FLAGS_CACHE" | tail -n 1 | grep -qx "module=$MODULE" || return 1
    head -n 3 "$FLAGS_CACHE" | tail -n 1 | grep -qx "sources=$SOURCE_DIRECTORY" || return 1
    return 0
}

if ! flags_are_current; then
    # SwiftPM prints a module's compile command only when it compiles something. Touching one
    # source guarantees the line is there; content and checksum are unchanged.
    FIRST_SOURCE=$(find "$SOURCE_DIRECTORY" -name '*.swift' | sort | head -n 1)
    [ -n "$FIRST_SOURCE" ] || {
        echo "generate-appintents-metadata: no Swift sources in $SOURCE_DIRECTORY" >&2
        exit 1
    }
    touch "$FIRST_SOURCE"
    if ! swift build -c release -v --scratch-path "$SCRATCH" >"$WORK/build.log" 2>&1; then
        echo "generate-appintents-metadata: swift build failed" >&2
        tail -n 20 "$WORK/build.log" >&2
        exit 1
    fi
    if COMMAND=$(python3 Scripts/appintents-capture-flags.py "$WORK/build.log" "$MODULE" "$SOURCE_DIRECTORY"); then
        {
            printf 'graph=%s\n' "$GRAPH_KEY"
            printf 'module=%s\n' "$MODULE"
            printf 'sources=%s\n' "$SOURCE_DIRECTORY"
            printf '%s\n' "$COMMAND"
        } >"$FLAGS_CACHE"
    else
        echo "generate-appintents-metadata: could not read the $MODULE module compile command" >&2
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
    --root "$ROOT" \
    --source-directory "$SOURCE_DIRECTORY"

# A SwiftPM target dependency is linked statically, so its metadata belongs in the static
# metadata list. Passing it as a normal dependency list leaves the actions out of the bundle.
set -- -o "$WORK/out" \
    -c "$TOOLCHAIN_DIR" \
    -m "$MODULE" \
    -r "$SDK" \
    -xcv "$XCODE_BUILD" \
    -pf macOS \
    -dt 15.0 \
    -t arm64-apple-macosx15.0 \
    -sl "$WORK/sources.txt" \
    -scl "$WORK/constvalues.json.list" \
    --quiet-warnings
if [ -n "$DEPENDENCY_METADATA" ]; then
    # The list names the dependency's actions data file, not its bundle directory: the
    # processor decodes a directory entry as an unreadable file and silently writes nothing.
    dependency_actions="$DEPENDENCY_METADATA/extract.actionsdata"
    [ -f "$dependency_actions" ] || {
        echo "generate-appintents-metadata: dependency metadata has no extract.actionsdata at $DEPENDENCY_METADATA" >&2
        exit 1
    }
    printf '%s\n' "$dependency_actions" >"$WORK/dependency-metadata.txt"
    set -- "$@" -smfl "$WORK/dependency-metadata.txt"
fi

xcrun appintentsmetadataprocessor "$@"

[ -f "$WORK/out/Metadata.appintents/version.json" ] || {
    echo "generate-appintents-metadata: the processor produced no metadata bundle for $MODULE" >&2
    exit 1
}

rm -rf "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
ditto "$WORK/out/Metadata.appintents" "$OUTPUT"
echo "generate-appintents-metadata: wrote $OUTPUT ($MODULE)"
