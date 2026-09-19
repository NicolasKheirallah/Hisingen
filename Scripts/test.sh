#!/bin/sh
set -eu

command_line_tools=/Library/Developer/CommandLineTools
selected_tools=${DEVELOPER_DIR:-}
if [ -z "$selected_tools" ]; then
    selected_tools=$(/usr/bin/xcode-select -p 2>/dev/null || true)
fi

# SwiftPM's manifest sandbox has to nest inside whatever sandbox the caller runs in. Where it
# cannot, manifest compilation dies with `sandbox-exec: sandbox_apply: Operation not permitted`
# before a single test runs. `--disable-sandbox` drops only the manifest/plugin sandbox for this
# local run, which is what the commands documented in GATES.md already pass explicitly.
sandbox_flag=
if swift test --help 2>&1 | grep -q -- '--disable-sandbox'; then
    sandbox_flag=--disable-sandbox
fi

if [ "$selected_tools" = "$command_line_tools" ]; then
    if swift test --help 2>&1 | grep -q -- '--enable-swift-testing'; then
        exec swift test $sandbox_flag --disable-xctest --enable-swift-testing \
            -Xswiftc -F \
            -Xswiftc "$command_line_tools/Library/Developer/Frameworks" "$@"
    else
        exec swift test $sandbox_flag \
            -Xswiftc -F \
            -Xswiftc "$command_line_tools/Library/Developer/Frameworks" "$@"
    fi
fi

if swift test --help 2>&1 | grep -q -- '--enable-swift-testing'; then
    exec swift test $sandbox_flag --disable-xctest --enable-swift-testing "$@"
else
    exec swift test $sandbox_flag "$@"
fi
