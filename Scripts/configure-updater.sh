#!/bin/sh
set -eu

PLIST_PATH=${1:?Usage: configure-updater.sh PATH/TO/Info.plist}
PLACEHOLDER='__SPARKLE_PUBLIC_ED_KEY__'
PUBLIC_KEY=${SPARKLE_PUBLIC_ED_KEY:-}

if [ -n "$PUBLIC_KEY" ]; then
    # Ed25519 public keys are safe to embed, but validate the expected base64 form so a
    # broken secret cannot yield a release that silently disables verification.
    DECODED_KEY=$(mktemp "${TMPDIR:-/tmp}/hisingen-sparkle-public-key.XXXXXX")
    cleanup() { rm -f "$DECODED_KEY"; }
    trap cleanup EXIT HUP INT TERM
    printf '%s' "$PUBLIC_KEY" | base64 --decode >"$DECODED_KEY" 2>/dev/null || {
        echo 'SPARKLE_PUBLIC_ED_KEY is not valid base64' >&2; exit 1;
    }
    KEY_LENGTH=$(wc -c <"$DECODED_KEY" | tr -d '[:space:]')
    [ "$KEY_LENGTH" -eq 32 ] || {
        echo 'SPARKLE_PUBLIC_ED_KEY must decode to exactly 32 bytes' >&2; exit 1;
    }
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" "$PLIST_PATH"
elif [ "${REQUIRE_SPARKLE_UPDATER:-false}" = 'true' ]; then
    echo 'SPARKLE_PUBLIC_ED_KEY is required for a distributable updater build' >&2
    exit 1
else
    # Development builds must not point an unsigned/placeholder configuration at the
    # production update service. UpdateService treats this value as disabled.
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PLACEHOLDER" "$PLIST_PATH"
fi

plutil -lint "$PLIST_PATH" >/dev/null
