#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
case "${1:-}" in
    --committed)
        work=$(mktemp -d "${TMPDIR:-/tmp}/hisingen-committed-ci.XXXXXX")
        cleanup() { rm -rf "$work"; }
        trap cleanup EXIT HUP INT TERM
        snapshot_sha=$(git rev-parse HEAD)
        snapshot="$work/source"
        # Retain history so patch checks inspect the original commit rather than a synthetic root.
        git -c core.hooksPath=/dev/null clone --quiet --no-hardlinks --no-checkout --shared "$ROOT_DIR" "$snapshot"
        git -C "$snapshot" -c core.hooksPath=/dev/null checkout --quiet --detach "$snapshot_sha"
        unset CI_BASE_SHA
        cd "$snapshot"
        ;;
    '') ;;
    *) echo "Usage: ci-local.sh [--committed]" >&2; exit 2 ;;
esac
sh Scripts/ci-checks.sh portable
if [ "${1:-}" != --committed ]; then
    python3 Scripts/check-sync.py
fi
output=$(mktemp -d "${TMPDIR:-/tmp}/hisingen-ci-artifacts.XXXXXX")
export HISINGEN_CI_OUTPUT_DIR="$output"
# Keep diagnostics after failure and successful bundles available for inspection.
echo "CI artifacts and diagnostics: $output"
sh Scripts/ci-checks.sh macos
echo "Local CI passed for this checkout and selected toolchain. Hosted OS/architecture lanes run separately."
