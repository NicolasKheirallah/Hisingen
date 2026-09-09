#!/bin/sh
set -eu

# Notarize and staple a .app bundle or .dmg image with notarytool, so a locally
# built Hisingen gets the same Gatekeeper trust as CI releases.
#
# Usage: sh Scripts/notarize.sh <PATH/TO/Hisingen.app | PATH/TO/Hisingen.dmg>
#
# Credentials, first match wins:
#   1. NOTARY_APPLE_ID + NOTARY_TEAM_ID + NOTARY_APP_PASSWORD environment
#      variables (the same names the release workflow uses as GitHub secrets)
#   2. A notarytool keychain profile, created once with:
#        xcrun notarytool store-credentials hisingen-notary \
#          --apple-id <APPLE_ID> --team-id <TEAM_ID> --password <APP_PASSWORD>
#      Override the profile name with NOTARYTOOL_PROFILE.
#
# NOTARIZE controls behavior when no credentials are found:
#   auto (default) — skip with a notice and exit 0, so development builds
#                    without Apple Developer Program access keep working
#   require        — fail hard; use for release builds that must be notarized
#   never          — skip unconditionally, even when credentials exist

MODE=${NOTARIZE:-auto}
NOTARYTOOL_PROFILE=${NOTARYTOOL_PROFILE:-hisingen-notary}
NOTARY_RETRIES=${NOTARY_RETRIES:-3}

ARTIFACT=${1:?Usage: notarize.sh PATH/TO/Hisingen.app OR PATH/TO/Hisingen.dmg}

if [ "$MODE" = 'never' ]; then
    echo "==> Skipping notarization (NOTARIZE=never)"
    exit 0
fi

AUTH_MODE=''

if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_APP_PASSWORD:-}" ]; then
    AUTH_MODE='env'
else
    # notarytool profiles live in the iCloud/Local Items keychain, which the
    # legacy `security` CLI cannot search, so probe with notarytool itself —
    # a missing profile fails fast with "No Keychain password item found".
    PROFILE_ERR=$(xcrun notarytool history --keychain-profile "$NOTARYTOOL_PROFILE" 2>&1 >/dev/null || true)
    if ! printf '%s' "$PROFILE_ERR" | grep -q 'No Keychain password item found'; then
        AUTH_MODE='profile'
    fi
fi

if [ -z "$AUTH_MODE" ]; then
    MESSAGE="no notarization credentials found; export NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_APP_PASSWORD, or create a keychain profile with 'xcrun notarytool store-credentials $NOTARYTOOL_PROFILE --apple-id <APPLE_ID> --team-id <TEAM_ID> --password <APP_PASSWORD>'"
    if [ "$MODE" = 'require' ]; then
        echo "ERROR: $MESSAGE" >&2
        exit 1
    fi
    echo "==> Skipping notarization ($MESSAGE)"
    exit 0
fi

if [ -d "$ARTIFACT" ]; then
    ASSESS_TYPE='execute'
elif [ -f "$ARTIFACT" ]; then
    ASSESS_TYPE='open'
else
    echo "Notarization artifact not found: $ARTIFACT" >&2
    exit 1
fi

ZIP_PATH=$(mktemp "${TMPDIR:-/tmp}/hisingen-notarize.XXXXXX")
cleanup() { rm -f "$ZIP_PATH"; }
trap cleanup EXIT HUP INT TERM

echo "==> Compressing $(basename "$ARTIFACT") for notarization"
ditto -c -k --keepParent "$ARTIFACT" "$ZIP_PATH"

echo "==> Submitting $(basename "$ARTIFACT") to Apple notary service (this can take several minutes)"
attempt=1
while :; do
    if [ "$AUTH_MODE" = 'env' ]; then
        if xcrun notarytool submit "$ZIP_PATH" \
            --apple-id "$NOTARY_APPLE_ID" \
            --team-id "$NOTARY_TEAM_ID" \
            --password "$NOTARY_APP_PASSWORD" \
            --wait; then
            break
        fi
    else
        if xcrun notarytool submit "$ZIP_PATH" \
            --keychain-profile "$NOTARYTOOL_PROFILE" \
            --wait; then
            break
        fi
    fi
    if [ "$attempt" -ge "$NOTARY_RETRIES" ]; then
        echo "notarytool submit failed after $attempt attempt(s)" >&2
        exit 1
    fi
    echo "notarytool submit attempt $attempt of $NOTARY_RETRIES failed; retrying in 10s" >&2
    attempt=$((attempt + 1))
    sleep 10
done

echo "==> Stapling $(basename "$ARTIFACT")"
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
if [ "$ASSESS_TYPE" = 'open' ]; then
    spctl --assess --type open --context context:primary-signature --verbose=2 "$ARTIFACT"
else
    spctl --assess --type execute --verbose=2 "$ARTIFACT"
fi

echo "✅ $(basename "$ARTIFACT") is notarized and stapled"
