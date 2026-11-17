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

settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
required = os.environ.get("XCODE_VERSION")
if not required and os.environ.get("GITHUB_ACTIONS", "").lower() == "true":
    required = settings["xcode"]

requested = os.environ.get("DEVELOPER_DIR", "")
candidates = [requested] if requested else []
if not requested or required:
    candidates += glob.glob("/Applications/Xcode*.app/Contents/Developer")
if not requested:
    selected = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True)
    if selected.returncode == 0:
        candidates.append(selected.stdout.strip())

matches = []
for candidate in dict.fromkeys(filter(None, candidates)):
    executable = pathlib.Path(candidate) / "usr/bin/xcodebuild"
    if not candidate or not executable.is_file():
        continue
    result = subprocess.run([str(executable), "-version"], capture_output=True, text=True, env={**os.environ, "DEVELOPER_DIR": candidate})
    first = result.stdout.splitlines()[:1]
    if result.returncode != 0 or not first or not first[0].startswith("Xcode "):
        continue
    version = first[0].removeprefix("Xcode ")
    if required:
        if version == required:
            matches.append((version, candidate))
    else:
        parts = tuple(int(part) for part in version.split(".") if part.isdigit())
        matches.append((parts, candidate))

if matches:
    if required:
        print(matches[0][1])
    else:
        print(max(matches)[1])
    sys.exit(0)

if required:
    sys.exit(f"Full Xcode {required} is required. Install that version, or explicitly set XCODE_VERSION for a local compatibility run.")
if requested:
    sys.exit(f"DEVELOPER_DIR does not point to a full Xcode installation: {requested}")
sys.exit("A full Xcode installation is required. Install Xcode or set DEVELOPER_DIR to its Developer directory.")
PY
)
if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'DEVELOPER_DIR=%s\n' "$selected" >> "$GITHUB_ENV"
fi
printf 'Selected Xcode developer directory: %s\n' "$selected"
