#!/bin/sh
set -eu
# Build the widget extension's Metadata.appintents.
#
# The widget-facing intents live in the shared HisingenIntents module: the app and the extension
# both link it, because an extension cannot link the app executable. A SwiftPM target dependency
# is static, so the processor folds that module's metadata into the extension's bundle through
# --static-metadata-file-list. Without this step the extension carries no intent metadata and an
# interactive widget button has nothing to resolve.
#
# Usage: generate-widget-appintents-metadata.sh --appex DIR [--scratch-path DIR]

APPEX=''
SCRATCH=''
while [ $# -gt 0 ]; do
    case "$1" in
        --appex) APPEX=${2:?--appex needs a directory}; shift 2 ;;
        --scratch-path) SCRATCH=${2:?--scratch-path needs a directory}; shift 2 ;;
        *) echo "usage: $0 --appex DIR [--scratch-path DIR]" >&2; exit 2 ;;
    esac
done
[ -n "$APPEX" ] || { echo "generate-widget-appintents-metadata: --appex is required" >&2; exit 2; }
[ -d "$APPEX" ] || { echo "generate-widget-appintents-metadata: $APPEX does not exist" >&2; exit 1; }

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/hisingen-widget-appintents.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

if [ -n "$SCRATCH" ]; then
    sh Scripts/generate-appintents-metadata.sh \
        --module HisingenIntents \
        --source-directory Sources/HisingenIntents \
        --output "$WORK/HisingenIntents.appintents" \
        --scratch-path "$SCRATCH"

    sh Scripts/generate-appintents-metadata.sh \
        --module HisingenWidget \
        --source-directory Sources/HisingenWidget \
        --dependency-metadata "$WORK/HisingenIntents.appintents" \
        --output "$APPEX/Contents/Resources/Metadata.appintents" \
        --scratch-path "$SCRATCH"
else
    sh Scripts/generate-appintents-metadata.sh \
        --module HisingenIntents \
        --source-directory Sources/HisingenIntents \
        --output "$WORK/HisingenIntents.appintents"

    sh Scripts/generate-appintents-metadata.sh \
        --module HisingenWidget \
        --source-directory Sources/HisingenWidget \
        --dependency-metadata "$WORK/HisingenIntents.appintents" \
        --output "$APPEX/Contents/Resources/Metadata.appintents"
fi

# The processor skips a dependency list it cannot read without failing the run, which would
# install an extension whose buttons never resolve. Assert the shared intents are present and
# keep their own module qualification: a copied module name would name a type that does not exist.
python3 - "$APPEX/Contents/Resources/Metadata.appintents/extract.actionsdata" <<'PY'
import json
import sys

document = json.load(open(sys.argv[1], encoding="utf-8"))
actions = document.get("actions") or {}
expected = {
    "WidgetLockVehicleIntent",
    "WidgetUnlockVehicleIntent",
    "WidgetStartClimateIntent",
    "WidgetHonkVehicleIntent",
    "WidgetChargeNowIntent",
    "WidgetStartPreCleaningIntent",
    "WidgetRefreshVehicleIntent",
}
missing = sorted(expected - actions.keys())
if missing:
    raise SystemExit("widget App Intents metadata is missing: " + ", ".join(missing))
for name in sorted(expected):
    qualified = actions[name].get("fullyQualifiedTypeName", "")
    if not qualified.startswith("HisingenIntents."):
        raise SystemExit(f"{name} has the wrong module qualification: {qualified!r}")
print(f"widget App Intents metadata: {len(actions)} intents from HisingenIntents")
PY
echo "generate-widget-appintents-metadata: wrote $APPEX/Contents/Resources/Metadata.appintents"
