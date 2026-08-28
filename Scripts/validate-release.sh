#!/bin/sh
set -eu

command -v swift >/dev/null 2>&1 || { echo "Swift toolchain is required" >&2; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "shasum is required" >&2; exit 1; }

if git ls-files --error-unmatch Sources/Hisingen/Services/API/GeneratedVolvoSecrets.swift >/dev/null 2>&1; then
    echo "GeneratedVolvoSecrets.swift must remain ignored and untracked" >&2
    exit 1
fi

if git ls-files --error-unmatch Sources/Hisingen/Services/API/GeneratedPolestarSecrets.swift >/dev/null 2>&1; then
    echo "GeneratedPolestarSecrets.swift must remain ignored and untracked" >&2
    exit 1
fi

if git ls-files | grep -E '(^|/)(\.env|.*\.pem|.*\.p12|.*\.key)$' >/dev/null 2>&1; then
    echo "Tracked secret-like file detected" >&2
    exit 1
fi

if git ls-files -z | xargs -0 grep -IlE '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}' 2>/dev/null | grep . >/dev/null 2>&1; then
    echo "Credential pattern detected in tracked source" >&2
    exit 1
fi

git diff --check

OUTPUT_DIR=${OUTPUT_DIR:-releases}
APP_PATH=${APP_PATH:-"$OUTPUT_DIR/Hisingen.app"}
DMG_PATH=${DMG_PATH:-"$OUTPUT_DIR/Hisingen.dmg"}
DMG_CHECKSUM_PATH=${DMG_CHECKSUM_PATH:-"$OUTPUT_DIR/Hisingen.dmg.sha256"}

if [ -d "$APP_PATH" ]; then
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

if [ -f "$DMG_PATH" ]; then
    command -v hdiutil >/dev/null 2>&1 || { echo "hdiutil is required to validate a DMG" >&2; exit 1; }
    hdiutil verify "$DMG_PATH"
    if [ -f "$DMG_CHECKSUM_PATH" ]; then
        (
            cd "$(dirname "$DMG_CHECKSUM_PATH")"
            shasum -a 256 -c "$(basename "$DMG_CHECKSUM_PATH")"
        )
    fi
fi

echo "Release validation passed"
