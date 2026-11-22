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

# The widget is a hand-assembled .appex, so nothing in Xcode's build checks its shape. An app
# extension must be typed XPC! and declare the widget point, or pluginkit ignores it while every
# other check here still passes. Assert it before the signature, so a missing/wrong bundle fails
# the build instead of shipping a widget that never appears.
appex="$APP_PATH/Contents/PlugIns/HisingenWidget.appex"
test -d "$appex" || { echo "Missing widget appex: $appex" >&2; exit 1; }
test -x "$appex/Contents/MacOS/HisingenWidget" || { echo "Missing widget binary" >&2; exit 1; }
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$appex/Contents/Info.plist" 2>/dev/null)" = 'XPC!' || {
    echo 'Widget appex is not typed XPC!' >&2; exit 1; }
test "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$appex/Contents/Info.plist" 2>/dev/null)" = 'com.apple.widgetkit-extension' || {
    echo 'Widget appex does not declare the WidgetKit extension point' >&2; exit 1; }
plutil -lint "$appex/Contents/Info.plist" >/dev/null
codesign --verify --strict --verbose=2 "$appex"

# App Intents metadata is what makes the intents discoverable, and nothing else in the build
# notices when it is absent: the app runs, and Shortcuts simply lists nothing. A release either
# carries a populated bundle or says explicitly that it was built without one.
if [ "${REQUIRE_APPINTENTS:-true}" = true ]; then
    metadata="$APP_PATH/Contents/Resources/Metadata.appintents"
    test -d "$metadata" || { echo "Missing App Intents metadata: $metadata" >&2; exit 1; }
    test -s "$metadata/version.json" || { echo 'App Intents metadata has no version.json' >&2; exit 1; }
    test -s "$metadata/extract.actionsdata" || { echo 'App Intents metadata has no actions data' >&2; exit 1; }
    python3 -c '
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
intents = document.get("actions") or {}
shortcuts = document.get("autoShortcuts") or []
if not intents:
    raise SystemExit("App Intents metadata lists no intents")
if not shortcuts:
    raise SystemExit("App Intents metadata lists no App Shortcuts")
print(f"App Intents metadata: {len(intents)} intents, {len(shortcuts)} shortcut groups")
' "$metadata/extract.actionsdata"

    # The widget extension carries its own metadata: its intents live in the shared
    # HisingenIntents module, and a missing bundle makes every interactive button inert
    # without failing any other build step.
    widget_metadata="$appex/Contents/Resources/Metadata.appintents"
    test -d "$widget_metadata" || { echo "Missing widget App Intents metadata: $widget_metadata" >&2; exit 1; }
    test -s "$widget_metadata/version.json" || { echo 'Widget App Intents metadata has no version.json' >&2; exit 1; }
    test -s "$widget_metadata/extract.actionsdata" || { echo 'Widget App Intents metadata has no actions data' >&2; exit 1; }
    python3 -c '
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
intents = document.get("actions") or {}
expected = {"WidgetLockVehicleIntent", "WidgetUnlockVehicleIntent", "WidgetStartClimateIntent", "WidgetRefreshVehicleIntent"}
missing = sorted(expected - intents.keys())
if missing:
    raise SystemExit("Widget App Intents metadata is missing: " + ", ".join(missing))
print(f"Widget App Intents metadata: {len(intents)} intents")
' "$widget_metadata/extract.actionsdata"
fi

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
