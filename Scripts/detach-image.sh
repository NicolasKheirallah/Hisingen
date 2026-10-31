#!/bin/sh
set -eu
mount_point=${1:?Usage: detach-image.sh MOUNT_POINT}
attempts=${HISINGEN_DETACH_ATTEMPTS:-6}
delay=${HISINGEN_DETACH_DELAY:-2}
case "$attempts" in ''|*[!0-9]*|0) echo 'Detach attempts must be a positive integer' >&2; exit 2 ;; esac
case "$delay" in ''|*[!0-9]*) echo 'Detach delay must be a nonnegative integer' >&2; exit 2 ;; esac
attempt=1
until hdiutil detach "$mount_point"; do
    if [ "$attempt" -ge "$attempts" ]; then
        # This helper is called only for our disposable, read-only validation mount.
        hdiutil detach -force "$mount_point"
        exit $?
    fi
    echo "Image is still busy; retrying detach ($attempt/$attempts)" >&2
    attempt=$((attempt + 1))
    sleep "$delay"
done
