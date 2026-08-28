#!/bin/sh
set -eu

# Assemble away from the working tree, then prove that the executable's @rpath dependency
# can resolve to the framework location used by the application bundle.
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/hisingen-updater-package.XXXXXX")
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT HUP INT TERM

APP_PATH="$STAGING/Hisingen.app"
make app SKIP_BUILD=1 APP="$APP_PATH" IDENTITY=- >/dev/null

test -d "$APP_PATH/Contents/Frameworks/Sparkle.framework"
otool -L "$APP_PATH/Contents/MacOS/Hisingen" | grep -Fq '@rpath/Sparkle.framework/'
otool -l "$APP_PATH/Contents/MacOS/Hisingen" | grep -Fq '@executable_path/../Frameworks'
codesign --verify --deep --strict "$APP_PATH"
grep -Eq '^SPARKLE_FRAMEWORK = ' Makefile

echo updater-package-passed
