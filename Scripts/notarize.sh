#!/bin/sh
set -eu
artifact=${1:?Usage: notarize.sh PATH/TO/Hisingen.app OR PATH/TO/Hisingen.dmg}
case "${NOTARIZE:-auto}" in
    never) echo "Skipping notarization (NOTARIZE=never)"; exit 0 ;;
    auto|require) ;;
    *) echo "NOTARIZE must be auto, require, or never" >&2; exit 2 ;;
esac
if [ -z "${NOTARY_APPLE_ID:-}" ] || [ -z "${NOTARY_TEAM_ID:-}" ] || [ -z "${NOTARY_APP_PASSWORD:-}" ]; then
    if ! xcrun notarytool history --keychain-profile "${NOTARYTOOL_PROFILE:-hisingen-notary}" --output-format json >/dev/null 2>&1; then
        if [ "${NOTARIZE:-auto}" = require ]; then
            echo "Notarization credentials are required" >&2; exit 1
        fi
        echo "Skipping notarization: no usable credentials"
        exit 0
    fi
fi
exec python3 "$(dirname "$0")/release-support.py" notarize "$artifact"
