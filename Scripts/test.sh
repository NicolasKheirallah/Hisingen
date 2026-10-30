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

if [ "$selected_tools" = "$command_line_tools" ]; then
    if [ -n "$swift_testing_flag" ]; then
        exec swift test $sandbox_flag --disable-xctest --enable-swift-testing \
            -Xswiftc -F \
            -Xswiftc "$command_line_tools/Library/Developer/Frameworks" "$@"
    else
        exec swift test $sandbox_flag \
            -Xswiftc -F \
            -Xswiftc "$command_line_tools/Library/Developer/Frameworks" "$@"
    fi
fi

if [ -n "$swift_testing_flag" ]; then
    exec swift test $sandbox_flag --disable-xctest --enable-swift-testing "$@"
else
    exec swift test $sandbox_flag "$@"
fi
