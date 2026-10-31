#!/bin/sh
set -eu
# pipefail is not POSIX; the guard keeps the script running on shells that lack it.
# shellcheck disable=SC3040
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

ARTIFACT=${1:?Usage: stapler-validate.sh PATH/TO/ARTIFACT}
MAX_ATTEMPTS=${STAPLER_VALIDATE_RETRIES:-5}
RETRY_DELAY=${STAPLER_VALIDATE_RETRY_DELAY:-10}

case "$MAX_ATTEMPTS" in
    ''|*[!0-9]*|0)
        echo "STAPLER_VALIDATE_RETRIES must be a positive integer" >&2
        exit 2
        ;;
esac

case "$RETRY_DELAY" in
    ''|*[!0-9]*)
        echo "STAPLER_VALIDATE_RETRY_DELAY must be a non-negative integer" >&2
        exit 2
        ;;
esac

attempt=1
while :; do
    if xcrun stapler validate "$ARTIFACT"; then
        exit 0
    fi

    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "stapler validate failed after $attempt attempt(s): $ARTIFACT" >&2
        exit 1
    fi

    echo "stapler validate attempt $attempt of $MAX_ATTEMPTS failed; retrying in ${RETRY_DELAY}s" >&2
    attempt=$((attempt + 1))
    sleep "$RETRY_DELAY"
done
