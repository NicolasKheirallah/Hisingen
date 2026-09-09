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

# A Developer ID-signed artifact is only Gatekeeper-trustworthy once notarized
# and stapled. Ad-hoc and development-identity builds are local-only and skip
# this check.
is_developer_id_signed() {
    codesign -dvv "$1" 2>&1 | grep -q 'Authority=Developer ID Application'
}

if [ -d "$APP_PATH" ]; then
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    if is_developer_id_signed "$APP_PATH"; then
        xcrun stapler validate "$APP_PATH" || {
            echo "$APP_PATH is Developer ID signed but has no notarization ticket stapled." >&2
            echo "Configure notarization credentials (see docs/operations/build.md), rebuild, or build with a development identity instead." >&2
            exit 1
        }
        spctl --assess --type execute --verbose=2 "$APP_PATH" || {
            echo "$APP_PATH failed Gatekeeper assessment — a Developer ID-signed app must be notarized and stapled." >&2
            echo "Configure notarization credentials (see docs/operations/build.md) and rebuild, or build with a development identity instead." >&2
            exit 1
        }
    fi
fi

if [ -f "$DMG_PATH" ]; then
    command -v hdiutil >/dev/null 2>&1 || { echo "hdiutil is required to validate a DMG" >&2; exit 1; }
    hdiutil verify "$DMG_PATH"
    if is_developer_id_signed "$DMG_PATH"; then
        xcrun stapler validate "$DMG_PATH" || {
            echo "$DMG_PATH is Developer ID signed but has no notarization ticket stapled." >&2
            echo "Configure notarization credentials (see docs/operations/build.md) and rebuild." >&2
            exit 1
        }
        spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH" || {
            echo "$DMG_PATH failed Gatekeeper assessment — a Developer ID-signed disk image must be notarized and stapled." >&2
            echo "Configure notarization credentials (see docs/operations/build.md) and rebuild." >&2
            exit 1
        }
    fi
    if [ -f "$DMG_CHECKSUM_PATH" ]; then
        (
            cd "$(dirname "$DMG_CHECKSUM_PATH")"
            shasum -a 256 -c "$(basename "$DMG_CHECKSUM_PATH")"
        )
    fi
fi

echo "Release validation passed"
