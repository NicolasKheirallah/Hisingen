#!/usr/bin/env python3
"""Compile the Hisingen module for constant-value extraction only.

Reuses SwiftPM's own module compile command, strips the per-file inputs and outputs, and replaces
them with the constant-value flags. The object output is /dev/null: the values are the product, and
the build already has its own objects.
"""

import argparse
import pathlib
import subprocess
import sys

# Constant extraction needs the protocols whose conformances carry discoverable metadata. These are
# the App Intents ones the processor reads; adding more only costs compile time.
PROTOCOLS = '["AppIntent","AppShortcutsProvider","SetFocusFilterIntent","AppEntity","AppEnum","EntityQuery","EntityStringQuery"]'

# Per-file inputs and outputs that do not belong in a whole-module run, and the index flags that
# would demand one index output per source file.
DROP_WITH_VALUE = {
    "-primary-file", "-filelist", "-supplementary-output-file-map",
    "-emit-dependencies-path", "-emit-reference-dependencies-path",
    "-serialize-diagnostics-path", "-o",
    "-output-filelist", "-supplementary-output-file-map",
    "-index-store-path", "-index-unit-output-path",
}
DROP_FLAG = {"-frontend", "-c", "-index-system-modules", "-index-ignore-system-modules"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", required=True)
    parser.add_argument("--protocols", required=True)
    parser.add_argument("--const-values", required=True)
    parser.add_argument("--object-output", required=True)
    parser.add_argument("--source-list", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--source-directory", default="Sources/Hisingen",
                        help="module source directory, relative to the repository root")
    args = parser.parse_args()

    import shlex

    argv = shlex.split(args.command)
    if not argv:
        print("empty compile command", file=sys.stderr)
        return 1

    flags = []
    index = 1
    while index < len(argv):
        arg = argv[index]
        if arg in DROP_WITH_VALUE:
            index += 2
            continue
        if arg in DROP_FLAG:
            index += 1
            continue
        # Small targets spell their sources out on the command line. The replay supplies its own
        # -filelist, so leaving them in would compile every file twice.
        if arg.endswith(".swift") and not arg.startswith("-"):
            index += 1
            continue
        # Optimization level is irrelevant to compile-time constants, and -Onone roughly halves
        # the compile. The real build keeps its own -O objects; this run only reads metadata.
        flags.append("-Onone" if arg == "-O" else arg)
        index += 1

    root = pathlib.Path(args.root)
    sources = sorted(str(p) for p in (root / args.source_directory).rglob("*.swift"))
    if not sources:
        print(f"no sources found under {args.source_directory}", file=sys.stderr)
        return 1

    protocols = pathlib.Path(args.protocols)
    protocols.write_text(PROTOCOLS + "\n")

    # SwiftPM compiles the release module in batch mode: one invocation, N sources, N objects.
    # Staying in that shape is what keeps this compile faithful to the real build; the constant
    # flags are the only addition, and the objects land in the throwaway work directory.
    source_list = pathlib.Path(args.source_list)
    source_list.write_text("\n".join(sources) + "\n")
    objects = pathlib.Path(args.object_output)
    objects.mkdir(parents=True, exist_ok=True)
    output_list = objects / "outputs.txt"
    output_list.write_text(
        "\n".join(str(objects / f"{index:04d}.o") for index in range(len(sources))) + "\n"
    )

    command = argv[0:1] + flags + [
        "-c",
        "-const-gather-protocols-file", str(protocols),
        "-emit-const-values-path", args.const_values,
        "-filelist", str(source_list),
        "-output-filelist", str(output_list),
    ]

    result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    if result.returncode != 0:
        print("const-value compile failed", file=sys.stderr)
        print("\n".join(result.stdout.splitlines()[-20:]), file=sys.stderr)
        return 1

    const_values = pathlib.Path(args.const_values)
    if not const_values.exists():
        print("the compiler wrote no const values", file=sys.stderr)
        return 1

    pathlib.Path(args.source_list).write_text("\n".join(sources) + "\n")
    pathlib.Path(str(const_values) + ".list").write_text(str(const_values) + "\n")
    print(f"appintents: const values for {len(sources)} sources")
    return 0


if __name__ == "__main__":
    sys.exit(main())
