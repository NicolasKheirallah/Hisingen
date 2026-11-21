#!/bin/sh
set -eu
# Reports why the test target will not compile, grouped by file, so a shared checkout can see
# in one step which file to wait for or fix. SwiftPM compiles the whole target as one unit, so
# a single half-written test file blocks every suite; this turns that wait into a readable list
# instead of a wall of compiler output.
#
#   sh Scripts/test-compile-check.sh          # all offenders
#   sh Scripts/test-compile-check.sh AuthFoo  # only lines for files containing "AuthFoo"

filter=${1:-}

output=$(mktemp "${TMPDIR:-/tmp}/hisingen-compile-check.XXXXXX")
trap 'rm -f "$output"' EXIT HUP INT TERM

if swift build --build-tests >"$output" 2>&1; then
    echo "Test target compiles: every suite can run."
    exit 0
fi

# Compiler diagnostics look like `<path>:<line>:<col>: error: <message>` and are often followed
# by a source snippet; the summary line is the only part worth grouping.
python3 - "$output" "$filter" <<'PY'
import collections
import re
import sys

path, needle = sys.argv[1], sys.argv[2]
diagnostic = re.compile(r'^(?P<file>[^:]+\.swift):(?P<line>\d+):(?P<col>\d+): error: (?P<message>.+)$')
by_file = collections.OrderedDict()
unattributed = []
for raw in open(path, encoding='utf-8', errors='replace'):
    line = raw.rstrip('\n')
    match = diagnostic.match(line.strip())
    if match:
        if needle and needle not in match.group('file'):
            continue
        by_file.setdefault(match.group('file'), []).append(
            (int(match.group('line')), match.group('message')))
    elif line.startswith('error:') and not needle:
        unattributed.append(line.strip())

if not by_file and not unattributed:
    print('No compiler diagnostics matched.')
    sys.exit(1)

total = sum(len(v) for v in by_file.values())
print(f'Test target does not compile: {total} error(s) in {len(by_file)} file(s).')
for file, items in by_file.items():
    print(f'\n{file}  ({len(items)} error(s))')
    for line, message in items[:6]:
        print(f'  {line}: {message}')
    if len(items) > 6:
        print(f'  ... and {len(items) - 6} more in this file')
for line in unattributed:
    print(f'\n{line}')
print('\nA file owned by another session can be left alone; wait for it, or coordinate.')
sys.exit(1)
PY
