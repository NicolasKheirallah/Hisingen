#!/bin/sh
set -eu

command_line_tools=/Library/Developer/CommandLineTools
selected_tools=${DEVELOPER_DIR:-}
if [ -z "$selected_tools" ]; then
    selected_tools=$(/usr/bin/xcode-select -p)
fi

if [ "$selected_tools" = "$command_line_tools" ]; then
    exec swift test --disable-xctest --enable-swift-testing \
        -Xswiftc -F \
        -Xswiftc "$command_line_tools/Library/Developer/Frameworks" "$@"
fi

exec swift test --disable-xctest --enable-swift-testing "$@"
