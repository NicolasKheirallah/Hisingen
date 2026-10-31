#!/bin/sh
set -eu
# pipefail is not POSIX; the guard keeps the script running on shells that lack it.
# shellcheck disable=SC3040
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

command_line_tools=/Library/Developer/CommandLineTools
selected_tools=${DEVELOPER_DIR:-}
if [ -z "$selected_tools" ]; then
    selected_tools=$(/usr/bin/xcode-select -p 2>/dev/null || true)
fi

# SwiftPM's manifest sandbox has to nest inside whatever sandbox the caller runs in. Where it
# cannot, manifest compilation dies with `sandbox-exec: sandbox_apply: Operation not permitted`
# before a single test runs. `--disable-sandbox` drops only the manifest/plugin sandbox for this
# local run, which is what the commands documented in GATES.md already pass explicitly.
# Capture the help text once instead of piping `swift test --help` into `grep -q`. A pipe that
# exits early would SIGPIPE swift, and pipefail would then report the probe as failed.
swift_test_help=$(swift test --help 2>&1 || true)
swift_testing_flag=
case "$swift_test_help" in
    *--enable-swift-testing*) swift_testing_flag=1 ;;
esac

sandbox_flag=
case "$swift_test_help" in
    *--disable-sandbox*) sandbox_flag=--disable-sandbox ;;
esac

for argument in "$@"; do
    case "$argument" in
        --help|-h|-help|--version|--list-tests|-l|list|last)
            exec swift test "$@"
            ;;
    esac
done

if [ "$selected_tools" = "$command_line_tools" ]; then
    set -- -Xswiftc -F -Xswiftc "$command_line_tools/Library/Developer/Frameworks" "$@"
fi
if [ -n "$swift_testing_flag" ]; then
    set -- --disable-xctest --enable-swift-testing "$@"
fi
if [ -n "$sandbox_flag" ]; then
    set -- "$sandbox_flag" "$@"
fi

root_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
if [ -n "${HISINGEN_TEST_OUTPUT_DIR:-}" ]; then
    report_dir=$HISINGEN_TEST_OUTPUT_DIR
    mkdir -p "$report_dir"
else
    report_dir=$(mktemp -d "${TMPDIR:-/tmp}/hisingen-tests.XXXXXX")
    trap 'rm -rf "$report_dir"' EXIT HUP INT TERM
fi
report_dir=$(CDPATH='' cd -- "$report_dir" && pwd)

# Discover with the same build and selection flags as execution; a typo cannot become a green run.
python3 "$root_dir/Scripts/check-test-selection.py" discover --output "$report_dir" -- swift test "$@"
python3 "$root_dir/Scripts/check-test-selection.py" selection \
    --output "$report_dir" "$report_dir/discovered-tests.txt" -- "$@"
case "$swift_test_help" in
    *--xunit-output*) result_flag=--xunit ;;
    *) echo "The selected Swift test runner must support --xunit-output" >&2; exit 1 ;;
esac
# The discovery run above already built everything, so `--skip-build` only saves seconds. With
# coverage it also breaks the run: SwiftPM clears its profile directory and recreates it only in
# the build step, so a fresh checkout would pass every test and then fail to merge coverage.
skip_build=--skip-build
for argument in "$@"; do
    if [ "$argument" = --enable-code-coverage ]; then skip_build=; fi
done
if [ -n "$skip_build" ]; then
    python3 "$root_dir/Scripts/check-test-selection.py" run --output "$report_dir" "$result_flag" \
        -- swift test "$@" "$skip_build"
else
    python3 "$root_dir/Scripts/check-test-selection.py" run --output "$report_dir" "$result_flag" \
        -- swift test "$@"
fi
