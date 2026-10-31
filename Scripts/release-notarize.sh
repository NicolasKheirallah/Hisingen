#!/bin/sh
set -eu
: "${TAG:?}" "${IDENTITY:?}" "${RUNNER_TEMP:?}" "${SPARKLE_TOOLS_SHA256:?}" "${SPARKLE_PUBLIC_ED_KEY:?}" "${SPARKLE_PRIVATE_ED_KEY:?}"
python3 Scripts/release-support.py verify-manifest signed-checkpoint.json "$TAG"
# A failed job can resume known Apple requests and a completed DMG without rebuilding.
if [ -f recovery-manifest.json ]; then
    python3 Scripts/release-support.py verify-manifest recovery-manifest.json "$TAG"
fi
checkpoint() {
    python3 - "$TAG" <<'PYTHON'
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location("release_support", "Scripts/release-support.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
files = [str(p) for p in Path("notary-state").glob("*.json")]
if Path("Hisingen.dmg").is_file(): files.append("Hisingen.dmg")
if files: module.create_manifest("recovery-manifest.json", sys.argv[1], files)
PYTHON
    rm -f "$RUNNER_TEMP/hisingen-sparkle-private.key"
    if [ -n "${archive_check_dir:-}" ]; then rm -rf "$archive_check_dir"; fi
}
trap checkpoint EXIT
rm -rf Hisingen.app
ditto -x -k signed-app.zip .
NOTARIZE=require NOTARY_STATE_DIR=notary-state NOTARY_SUBMISSION_ARCHIVE=signed-app.zip sh Scripts/notarize.sh Hisingen.app
if [ ! -f Hisingen.dmg ]; then
    NOTARIZE=never make package-dmg OUTPUT_DIR=. IDENTITY="$IDENTITY"
fi
codesign --verify --verbose=2 Hisingen.dmg
NOTARIZE=require NOTARY_STATE_DIR=notary-state sh Scripts/notarize.sh Hisingen.dmg
ditto -c -k --keepParent Hisingen.app Hisingen.zip
cp Hisingen.zip Hisingen.app.zip
archive_check_dir=$(mktemp -d "$RUNNER_TEMP/hisingen-archives.XXXXXX")
for archive in Hisingen.zip Hisingen.app.zip; do
    destination="$archive_check_dir/$archive"
    mkdir -p "$destination"
    ditto -x -k "$archive" "$destination"
    codesign --verify --deep --strict --verbose=2 "$destination/Hisingen.app"
    lipo "$destination/Hisingen.app/Contents/MacOS/Hisingen" -verify_arch arm64 x86_64
    spctl --assess --type execute --verbose=2 "$destination/Hisingen.app"
done
APP_PATH=Hisingen.app DMG_PATH=Hisingen.dmg REQUIRE_UNIVERSAL=true sh Scripts/validate-release.sh --artifacts Hisingen.app Hisingen.dmg
shasum -a 256 Hisingen.dmg Hisingen.zip Hisingen.app.zip > SHA256SUMS
archive="$RUNNER_TEMP/Sparkle-2.10.1.tar.xz"
curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 180 -o "$archive" https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz
printf '%s  %s\n' "$SPARKLE_TOOLS_SHA256" "$archive" | shasum -a 256 -c -
mkdir -p "$RUNNER_TEMP/sparkle-tools"
tar -xJf "$archive" -C "$RUNNER_TEMP/sparkle-tools"
tools=$(find "$RUNNER_TEMP/sparkle-tools" -type f -path '*/bin/generate_appcast' -print | head -n 1)
test -n "$tools" && test -x "$tools"
tools_dir=$(dirname "$(dirname "$tools")")
umask 077
private_key="$RUNNER_TEMP/hisingen-sparkle-private.key"
printf '%s' "$SPARKLE_PRIVATE_ED_KEY" > "$private_key"
node Scripts/verify-sparkle-keypair.mjs "$private_key"
sh Scripts/publish-appcast.sh "$tools_dir" "${TAG#v}" "$TAG" Hisingen.app.zip updates "$private_key"
node Scripts/verify-updater.mjs appcast updates/appcast.xml Hisingen.app.zip updates/Hisingen.app.md Hisingen.app/Contents/Info.plist "$TAG"
mkdir -p site/updates
cp updates/appcast.xml site/updates/appcast.xml
python3 Scripts/release-support.py manifest release-manifest.json "$TAG" Hisingen.dmg Hisingen.zip Hisingen.app.zip SHA256SUMS updates/appcast.xml updates/Hisingen.app.md
