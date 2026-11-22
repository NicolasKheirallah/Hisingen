#!/usr/bin/env python3
"""Print the Hisingen module's compile command from a SwiftPM verbose build log.

The release configuration builds the module whole, in one `swift-frontend -c -filelist` call, so
that is the command to extend. Debug builds compile per file; the `-primary-file` form is accepted
as a fallback so the script keeps working when someone runs it against a debug build.
"""

import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: appintents-capture-flags.py BUILD_LOG", file=sys.stderr)
        return 2
    log = pathlib.Path(sys.argv[1])
    try:
        lines = log.read_text(errors="replace").splitlines()
    except OSError as error:
        print(f"cannot read {log}: {error}", file=sys.stderr)
        return 1

    def is_module_compile(line: str) -> bool:
        return "swift-frontend" in line and "-module-name Hisingen" in line

    # Whole-module first: it carries every source in one invocation.
    for line in lines:
        if is_module_compile(line) and "-filelist" in line and "Sources/Hisingen" not in line:
            print(line.strip())
            return 0
    for line in lines:
        if is_module_compile(line) and "-primary-file" in line and "Sources/Hisingen/" in line:
            print(line.strip())
            return 0
    print("no Hisingen module compile command found in the build log", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
