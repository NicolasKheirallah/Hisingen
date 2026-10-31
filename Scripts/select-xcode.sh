#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
selected=$(python3 - "$ROOT_DIR/.github/ci-toolchain.json" <<'PY'
import glob
import json
import os
import pathlib
import subprocess
import sys

required = os.environ.get("XCODE_VERSION") or json.loads(pathlib.Path(sys.argv[1]).read_text())["xcode"]
candidates = [os.environ.get("DEVELOPER_DIR", "")]
candidates += [f"/Applications/Xcode_{required}.app/Contents/Developer", f"/Applications/Xcode_{required}.0.app/Contents/Developer"]
candidates += sorted(glob.glob("/Applications/Xcode*.app/Contents/Developer"))
for candidate in dict.fromkeys(candidates):
    executable = pathlib.Path(candidate) / "usr/bin/xcodebuild"
    if not candidate or not executable.is_file():
        continue
    result = subprocess.run([str(executable), "-version"], capture_output=True, text=True, env={**os.environ, "DEVELOPER_DIR": candidate})
    first = result.stdout.splitlines()[:1]
    if result.returncode == 0 and first == [f"Xcode {required}"]:
        print(candidate)
        sys.exit(0)
sys.exit(f"Full Xcode {required} is required. Install that version, or explicitly set XCODE_VERSION for a local compatibility run.")
PY
)
if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'DEVELOPER_DIR=%s\n' "$selected" >> "$GITHUB_ENV"
fi
printf 'Selected Xcode developer directory: %s\n' "$selected"
