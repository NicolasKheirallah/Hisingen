#!/bin/sh
set -eu
# pipefail is not POSIX; the guard keeps the script running on shells that lack it.
# shellcheck disable=SC3040
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

# Builds and runs the debug binary under the same code identity as the shipped app.
#
# `swift run` leaves the binary ad-hoc signed, so its identity is a code hash that changes on
# every rebuild. The Keychain items it reads and writes (service io.kheirallah.hisingen) are
# guarded by an access list keyed to the app's signing identity, so each rebuild is a stranger
# that macOS asks the login password for, and anything it writes can reset the list for the
# signed app too. Signing with the same identifier and team gives the binary the app's
# designated requirement, which macOS already trusts.
#
# Falls back to a plain run, with a warning, when no signing identity is installed.

IDENTIFIER="io.kheirallah.hisingen"

swift build "$@"
BIN="$(swift build --show-bin-path "$@")/Hisingen"

IDENTITY="${IDENTITY:-$(sh Scripts/signing-identity.sh)}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    codesign --force --sign "$IDENTITY" --identifier "$IDENTIFIER" "$BIN"
else
    echo "run-signed: no code-signing identity found; running ad-hoc, so macOS will ask for the Keychain password after every rebuild." >&2
fi

exec "$BIN"
