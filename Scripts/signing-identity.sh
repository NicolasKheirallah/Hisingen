#!/bin/sh
set -eu
# pipefail is not POSIX; the guard keeps the script running on shells that lack it.
# shellcheck disable=SC3040
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

# Prefer a valid distribution identity even when a local development certificate
# appears first in the keychain. Explicit IDENTITY overrides remain supported.
# security may exit non-zero with no identities; the group keeps that from failing the script under pipefail.
{ security find-identity -v -p codesigning 2>/dev/null || true; } | awk -F '"' '
/"Developer ID Application:/ { if (!distribution) distribution = $2 }
/"Apple Development:/ { if (!development) development = $2 }
/"Hisingen Development"/ { local = $2 }
END {
    if (distribution) print distribution
    else if (development) print development
    else if (local) print local
}'
