#!/bin/sh
set -eu
# shellcheck disable=SC3040
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi
ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
phase=${1:?Usage: ci-checks.sh portable|macos|macos-test|build-arch ARCH|package}

# Shared setup for the macOS phases. Hosted CI runs them as separate jobs; `macos` runs the
# test phase and the universal package together for a local check or a release dry run.
macos_prepare() {
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
}

macos_test() {
    sh Scripts/test.sh --force-resolved-versions --enable-code-coverage -Xswiftc -warnings-as-errors --skip Live --no-parallel 2>&1 | tee "$output/build-and-test.log"
    coverage_path=$(swift test --show-codecov-path)
    python3 Scripts/ci-summary.py coverage "$coverage_path" "$output"
    sh Scripts/validate-release.sh --source
    node Scripts/verify-updater.mjs configuration
}

# Build one architecture and stage exactly what packaging needs from it: the binary, the
# Sparkle framework SwiftPM placed beside it, and Sparkle's license file.
macos_build_arch() {
    arch=$1
    make build-arch ARCH="$arch" SWIFT_FLAGS=--force-resolved-versions
    staged=".build-$arch/$arch-apple-macosx/release/Hisingen .build-$arch/$arch-apple-macosx/release/HisingenWidget"
    framework=$(find ".build-$arch" -type d -name Sparkle.framework -print | sed -n 1p)
    license=$(find ".build-$arch" -path '*artifacts/sparkle/Sparkle/LICENSE' -print | sed -n 1p)
    test -n "$framework" || { echo "Sparkle.framework was not produced for $arch" >&2; exit 1; }
    for product in $staged; do
        test -x "$product" || { echo "Missing $product" >&2; exit 1; }
    done
    # shellcheck disable=SC2086 # staged and license are plain paths without spaces, or empty
    tar -cf "$output/arch-$arch.tar" $staged "$framework" $license
    echo "Staged $arch build: $(wc -c < "$output/arch-$arch.tar") bytes"
}

macos_restore_arch_builds() {
    dir=${HISINGEN_ARCH_DIR:?Set HISINGEN_ARCH_DIR to the folder holding arch-arm64.tar and arch-x86_64.tar}
    for arch in arm64 x86_64; do
        test -f "$dir/arch-$arch.tar" || { echo "Missing $dir/arch-$arch.tar" >&2; exit 1; }
        tar -xf "$dir/arch-$arch.tar"
    done
}

macos_package_checks() {
    make package-dmg OUTPUT_DIR="$output" IDENTITY=- NOTARIZE=never
    REQUIRE_UNIVERSAL=true sh Scripts/validate-release.sh --artifacts "$output/Hisingen.app" "$output/Hisingen.dmg"
    "$output/Hisingen.app/Contents/MacOS/Hisingen" --ci-smoke-test
    shasum -a 256 "$output/Hisingen.dmg" > "$output/Hisingen.dmg.sha256"
}

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
        sh Scripts/test-home-assistant-component.sh
        node Scripts/verify-sparkle-keypair.mjs --self-test
        node Scripts/verify-updater.mjs appcast-self-test
        node Scripts/verify-updater.mjs release-pipeline
        node Scripts/verify-updater.mjs release-notes
        node Scripts/verify-polestar-decode.mjs
        python3 Scripts/verify-ci-contract.py
        ;;
    macos-test|build-arch|package|macos)
        macos_prepare
        case "$phase" in
            macos-test) macos_test ;;
            build-arch) macos_build_arch "${2:?Usage: ci-checks.sh build-arch arm64|x86_64}" ;;
            package)
                macos_restore_arch_builds
                make package-universal OUTPUT_DIR="$output" IDENTITY=- NOTARIZE=never
                macos_package_checks
                ;;
            macos)
                macos_test
                if [ "${HISINGEN_CI_PACKAGE:-true}" = true ]; then
                    make app-universal OUTPUT_DIR="$output" IDENTITY=- NOTARIZE=never
                    macos_package_checks
                fi
                ;;
        esac
        ;;
    *) echo "Unknown CI phase: $phase" >&2; exit 2 ;;
esac
printf 'ci-%s-passed\n' "$phase"
