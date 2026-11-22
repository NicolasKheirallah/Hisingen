#!/usr/bin/env python3
"""Print a SwiftPM module's compile command from a verbose build log.

The release configuration builds a module whole, in one `swift-frontend -c -filelist` call, so
that is the command to extend. Debug builds compile per file; the `-primary-file` form is accepted
as a fallback so the script keeps working when someone runs it against a debug build.

Usage: appintents-capture-flags.py BUILD_LOG MODULE SOURCE_DIRECTORY
"""

import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: appintents-capture-flags.py BUILD_LOG MODULE SOURCE_DIRECTORY",
              file=sys.stderr)
        return 2
    log_path, module, source_directory = sys.argv[1:]
    log = pathlib.Path(log_path)
    try:
        lines = log.read_text(errors="replace").splitlines()
    except OSError as error:
        print(f"cannot read {log}: {error}", file=sys.stderr)
        return 1

    def is_module_compile(line: str) -> bool:
        return "swift-frontend" in line and f"-module-name {module}" in line

    # Whole-module first: it carries every source in one invocation and names them through a
    # file list, so the source directory itself does not appear on the command line.
    for line in lines:
        if is_module_compile(line) and "-filelist" in line and source_directory not in line:
            print(line.strip())
            return 0
    # Small targets compile whole with the sources spelled out on the command line instead of a
    # file list; that is still one invocation, so it is the same command to extend.
    for line in lines:
        if (is_module_compile(line) and " -c " in f" {line} "
                and f"{source_directory}/" in line and "-primary-file" not in line):
            print(line.strip())
            return 0
    for line in lines:
        if is_module_compile(line) and "-primary-file" in line and f"{source_directory}/" in line:
            print(line.strip())
            return 0
    print(f"no {module} module compile command found in the build log", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
