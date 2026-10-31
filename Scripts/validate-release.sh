#!/bin/sh
set -eu

mode=${1:---source}
case "$mode" in
    --source)
        python3 Scripts/check-source-hygiene.py
        echo 'Release source validation passed'
        exit 0
        ;;
    --artifacts)
        APP_PATH=${2:?Usage: validate-release.sh --artifacts APP DMG}
        DMG_PATH=${3:?Usage: validate-release.sh --artifacts APP DMG}
        ;;
    *) echo 'Usage: validate-release.sh --source | --artifacts APP DMG' >&2; exit 2 ;;
esac

test -d "$APP_PATH" || { echo "Missing app: $APP_PATH" >&2; exit 1; }
test -s "$DMG_PATH" || { echo "Missing or empty DMG: $DMG_PATH" >&2; exit 1; }
test -x "$APP_PATH/Contents/MacOS/Hisingen"
plutil -lint "$APP_PATH/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP_PATH/Contents/Info.plist")" = true
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
if [ "${REQUIRE_UNIVERSAL:-false}" = true ]; then
    lipo "$APP_PATH/Contents/MacOS/Hisingen" -verify_arch arm64 x86_64
fi

attempt=1
until hdiutil verify "$DMG_PATH"; do
    test "$attempt" -lt 6 || exit 1
    attempt=$((attempt + 1))
    sleep 5
done

mount_dir=$(mktemp -d "${TMPDIR:-/tmp}/hisingen-validation.XXXXXX")
attached=false
cleanup() {
    if "$attached"; then HISINGEN_DETACH_ATTEMPTS=1 HISINGEN_DETACH_DELAY=0 sh Scripts/detach-image.sh "$mount_dir" >/dev/null 2>&1 || true; fi
    rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
attempt=1
until hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$mount_dir"; do
    test "$attempt" -lt 6 || exit 1
    attempt=$((attempt + 1))
    sleep 5
done
attached=true
packaged_app="$mount_dir/Hisingen.app"
test -x "$packaged_app/Contents/MacOS/Hisingen"
codesign --verify --deep --strict --verbose=2 "$packaged_app"
cmp "$APP_PATH/Contents/MacOS/Hisingen" "$packaged_app/Contents/MacOS/Hisingen"
cmp "$APP_PATH/Contents/Info.plist" "$packaged_app/Contents/Info.plist"
if [ "${REQUIRE_UNIVERSAL:-false}" = true ]; then
    lipo "$packaged_app/Contents/MacOS/Hisingen" -verify_arch arm64 x86_64
fi

signature=$(codesign -dvv "$APP_PATH" 2>&1)
case "$signature" in
    *'Authority=Developer ID Application'*)
        sh Scripts/stapler-validate.sh "$APP_PATH"
        sh Scripts/stapler-validate.sh "$DMG_PATH"
        spctl --assess --type execute --verbose=2 "$packaged_app"
        spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
        ;;
esac
"$packaged_app/Contents/MacOS/Hisingen" --ci-smoke-test
sh Scripts/detach-image.sh "$mount_dir"
attached=false
if [ -f "$DMG_PATH.sha256" ]; then
    (cd "$(dirname "$DMG_PATH")" && shasum -a 256 -c "$(basename "$DMG_PATH").sha256")
fi
echo 'Release artifact validation passed'
