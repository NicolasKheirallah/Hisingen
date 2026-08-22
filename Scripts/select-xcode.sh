#!/bin/sh
set -eu

is_xcode_developer_dir() {
    [ -n "$1" ] &&
        [ -d "$1" ] &&
        [ -x "$1/usr/bin/xcodebuild" ] &&
        "$1/usr/bin/xcodebuild" -version >/dev/null 2>&1
}

selected=""

if is_xcode_developer_dir "${DEVELOPER_DIR:-}"; then
    selected=$DEVELOPER_DIR
else
    active=$(/usr/bin/xcode-select -p 2>/dev/null || true)
    if is_xcode_developer_dir "$active"; then
        selected=$active
    fi
fi

if [ -z "$selected" ]; then
    for app in /Applications/Xcode.app /Applications/Xcode_*.app; do
        candidate="$app/Contents/Developer"
        if is_xcode_developer_dir "$candidate"; then
            selected=$candidate
            break
        fi
    done
fi

if [ -z "$selected" ]; then
    echo "No full Xcode installation was found" >&2
    exit 1
fi

if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'DEVELOPER_DIR=%s\n' "$selected" >> "$GITHUB_ENV"
fi

echo "Selected Xcode developer directory: $selected"
