#!/bin/sh
set -eu
# shellcheck disable=SC3040
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi
ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
phase=${1:?Usage: ci-checks.sh portable OR macos}
case "$phase" in
    portable)
        python3 Scripts/ci-summary.py lint-workflows
        shellcheck Scripts/*.sh
        sh Scripts/validate-release.sh --source
        python3 Scripts/check-localization.py
        python3 Scripts/check-docs-links.py
        python3 Scripts/check-third-party-notices.py
        python3 Scripts/check-vin-scoping.py
        python3 Scripts/verify-app-contrast.py
        node Scripts/verify-surface-discipline.mjs
        node Scripts/verify-ui-discipline.mjs
        node Scripts/verify-l10n-usage.mjs
        node Scripts/audit-l10n-literals.mjs
        python3 Scripts/test-repository-checks.py
        python3 Scripts/test-release-pipeline.py
        python3 Scripts/test-release-validation.py
        python3 Scripts/test-test-selection.py
        node Scripts/verify-sparkle-keypair.mjs --self-test
        node Scripts/verify-updater.mjs appcast-self-test
        node Scripts/verify-updater.mjs release-pipeline
        node Scripts/verify-updater.mjs release-notes
        node Scripts/verify-polestar-decode.mjs
        python3 Scripts/verify-ci-contract.py
        ;;
    macos)
        export HISINGEN_BUILD_CONFIGURATION=fixture
        selection=$(sh Scripts/select-xcode.sh)
        DEVELOPER_DIR=${selection#Selected Xcode developer directory: }
        export DEVELOPER_DIR
        output=${HISINGEN_CI_OUTPUT_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/hisingen-ci}
        mkdir -p "$output"
        touch "$output/started"
        trap 'python3 Scripts/ci-summary.py diagnostics "$output"' EXIT
        export HISINGEN_TEST_OUTPUT_DIR="$output/test-results"
        python3 Scripts/ci-summary.py toolchain "$output"
        make doctor inject-secrets
        sh Scripts/test.sh --force-resolved-versions --enable-code-coverage -Xswiftc -warnings-as-errors --skip Live --no-parallel 2>&1 | tee "$output/build-and-test.log"
        coverage_path=$(swift test --show-codecov-path)
        python3 Scripts/ci-summary.py coverage "$coverage_path" "$output"
        sh Scripts/validate-release.sh --source
        node Scripts/verify-updater.mjs configuration
        if [ "${HISINGEN_CI_PACKAGE:-true}" = true ]; then
            make app-universal OUTPUT_DIR="$output" IDENTITY=- NOTARIZE=never
            make package-dmg OUTPUT_DIR="$output" IDENTITY=- NOTARIZE=never
            REQUIRE_UNIVERSAL=true sh Scripts/validate-release.sh --artifacts "$output/Hisingen.app" "$output/Hisingen.dmg"
            "$output/Hisingen.app/Contents/MacOS/Hisingen" --ci-smoke-test
            shasum -a 256 "$output/Hisingen.dmg" > "$output/Hisingen.dmg.sha256"
        fi
        ;;
    *) echo "Unknown CI phase: $phase" >&2; exit 2 ;;
esac
printf 'ci-%s-passed\n' "$phase"
