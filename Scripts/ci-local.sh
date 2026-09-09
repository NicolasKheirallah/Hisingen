#!/bin/sh
# Run the ci.yml job set locally, in the same order, so a sync to GitHub
# cannot fail on a check that only exists there. actionlint and shellcheck
# must be installed (brew install actionlint shellcheck).
set -eu

fail() {
    echo "$1" >&2
    exit 1
}

command -v actionlint >/dev/null 2>&1 || fail "actionlint is required — brew install actionlint"
command -v shellcheck >/dev/null 2>&1 || fail "shellcheck is required — brew install shellcheck"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

echo "==> lint-workflows-and-scripts (ci: ubuntu job)"
actionlint
shellcheck Scripts/*.sh

echo "==> check-localization (ci: ubuntu job)"
python3 Scripts/check-localization.py

echo "==> check-docs (ci: ubuntu job)"
python3 Scripts/check-docs-links.py

echo "==> check-sync (local: uncommitted build inputs CI would lose)"
python3 Scripts/check-sync.py

echo "==> build-and-test (ci: macos-15 job)"
make doctor inject-secrets
swift build
sh Scripts/test.sh --skip Live
sh Scripts/validate-release.sh

echo "==> ad-hoc app bundle (ci: build-and-test)"
make app OUTPUT_DIR=. IDENTITY=-
test -x Hisingen.app/Contents/MacOS/Hisingen
plutil -lint Hisingen.app/Contents/Info.plist >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' Hisingen.app/Contents/Info.plist)" = "true"
codesign --verify --deep --strict --verbose=2 Hisingen.app

echo "==> ad-hoc DMG validation (ci: build-and-test)"
make dmg OUTPUT_DIR=. IDENTITY=-
test -s Hisingen.dmg
# hdiutil on hosted runners intermittently returns "Resource temporarily
# unavailable" right after create; the same retry as ci.yml, so a local run
# does not fail where CI would have retried.
for attempt in 1 2 3 4 5 6; do
    if hdiutil verify Hisingen.dmg; then
        break
    fi
    if [ "$attempt" -eq 6 ]; then
        echo "hdiutil verify still failing after $attempt attempts" >&2
        exit 1
    fi
    echo "hdiutil verify attempt $attempt failed; retrying in 5s" >&2
    sleep 5
done

rm -rf Hisingen.app Hisingen.dmg Hisingen.dmg.sha256

echo "✅ All ci.yml checks passed locally — a sync of the committed tree cannot fail on them."
