#!/bin/sh
set -eu

# Prefer a valid distribution identity even when a local development certificate
# appears first in the keychain. Explicit IDENTITY overrides remain supported.
security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '
/"Developer ID Application:/ { if (!distribution) distribution = $2 }
/"Apple Development:/ { if (!development) development = $2 }
/"Hisingen Development"/ { local = $2 }
END {
    if (distribution) print distribution
    else if (development) print development
    else if (local) print local
}'
