#!/bin/sh
set -eu
# pipefail is not POSIX; the guard keeps the script running on shells that lack it.
# shellcheck disable=SC3040
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

ARTIFACT=${1:?Usage: stapler-staple.sh PATH/TO/ARTIFACT}
MAX_ATTEMPTS=${STAPLER_STAPLE_RETRIES:-5}
RETRY_DELAY=${STAPLER_STAPLE_RETRY_DELAY:-10}

case "$MAX_ATTEMPTS" in
    ''|*[!0-9]*|0)
        echo "STAPLER_STAPLE_RETRIES must be a positive integer" >&2
        exit 2
        ;;
esac

case "$RETRY_DELAY" in
    ''|*[!0-9]*)
        echo "STAPLER_STAPLE_RETRY_DELAY must be a non-negative integer" >&2
        exit 2
        ;;
esac

attempt=1
while :; do
    if xcrun stapler staple "$ARTIFACT"; then
        sh "$(dirname "$0")/stapler-validate.sh" "$ARTIFACT"
        exit 0
    fi

    # stapler can attach the ticket successfully, then report failure when its
    # final online validation loses connectivity. Accept a valid ticket before
    # retrying a staple that may already have been applied.
    if xcrun stapler validate "$ARTIFACT"; then
        echo "The ticket is stapled and valid despite the staple command error."
        exit 0
    fi

    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "stapler staple failed after $attempt attempt(s): $ARTIFACT" >&2
        exit 1
    fi

    echo "stapler staple attempt $attempt of $MAX_ATTEMPTS failed; retrying in ${RETRY_DELAY}s" >&2
    attempt=$((attempt + 1))
    sleep "$RETRY_DELAY"
done
