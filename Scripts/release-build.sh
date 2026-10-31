#!/bin/sh
set -eu
stage=${1:?Usage: release-build.sh signing-setup|build|signing-cleanup}
case "$stage" in
signing-setup)
    : "${MACOS_CERT_P12:?Certificate required}" "${MACOS_CERT_PASSWORD:?Certificate password required}" "${RUNNER_TEMP:?}"
    certificate="$RUNNER_TEMP/hisingen-signing.p12"
    keychain="$RUNNER_TEMP/hisingen-signing.keychain-db"
    password=$(uuidgen)
    echo "::add-mask::$password"
    umask 077
    printf '%s' "$MACOS_CERT_P12" | base64 --decode > "$certificate"
    security create-keychain -p "$password" "$keychain"
    security set-keychain-settings -lut 7200 "$keychain"
    security unlock-keychain -p "$password" "$keychain"
    security import "$certificate" -k "$keychain" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
    security list-keychains -d user -s "$keychain"
    identity=$(security find-identity -v -p codesigning "$keychain" | awk -F'"' '/Developer ID Application/ {print $2; exit}')
    test -n "$identity" || { echo "Developer ID identity not found" >&2; exit 1; }
    printf 'IDENTITY=%s\n' "$identity" >> "$GITHUB_ENV"
    rm -f "$certificate"
    ;;
build)
    : "${TAG:?}" "${IDENTITY:?}" "${VOLVO_CLIENT_ID:?}" "${VOLVO_CLIENT_SECRET:?}" "${VOLVO_VCC_API_KEY:?}" "${SPARKLE_PUBLIC_ED_KEY:?}"
    python3 Scripts/release-support.py validate "$TAG"
    NOTARIZE=never REQUIRE_SPARKLE_UPDATER=true make app-universal OUTPUT_DIR=. IDENTITY="$IDENTITY" SWIFT_FLAGS=--force-resolved-versions
    lipo Hisingen.app/Contents/MacOS/Hisingen -verify_arch arm64 x86_64
    codesign --verify --deep --strict --verbose=2 Hisingen.app
    ditto -c -k --keepParent Hisingen.app signed-app.zip
    python3 Scripts/release-support.py manifest signed-checkpoint.json "$TAG" signed-app.zip
    ;;
signing-cleanup)
    rm -f "${RUNNER_TEMP:?}/hisingen-signing.p12" "$RUNNER_TEMP/hisingen-sparkle-private.key"
    security delete-keychain "$RUNNER_TEMP/hisingen-signing.keychain-db" 2>/dev/null || true
    ;;
*) echo "Unknown release build phase: $stage" >&2; exit 2 ;;
esac
