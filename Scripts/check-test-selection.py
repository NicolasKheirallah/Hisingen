#!/usr/bin/env python3
"""Validate Swift test discovery and retain bounded, machine-readable run evidence."""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent


def discovered_tests(text):
    return sorted(set(line.strip() for line in text.splitlines()
                      if re.match(r"^[A-Za-z_]\w*(?:\.\w+)+/\w+", line.strip())))


def select_tests(tests, filters=(), skips=()):
    include = [re.compile(pattern) for pattern in filters]
    exclude = [re.compile(pattern) for pattern in skips]
    return [test for test in tests
            if (not include or any(pattern.search(test) for pattern in include))
            and not any(pattern.search(test) for pattern in exclude)]


VALUE_FLAGS = {"--filter", "--skip", "--num-workers", "--xunit-output", "--specifier", "-s"}
BOOLEAN_FLAGS = {"--parallel", "--no-parallel"}
# Flags that choose how `swift test` runs tests and that `swift build` does not accept.
TEST_ONLY_FLAGS = {"--disable-xctest", "--enable-xctest", "--enable-swift-testing", "--disable-swift-testing"}


def without_run_selectors(command):
    """Drop the flags that choose which tests run or how, keeping everything that changes the build."""
    kept = []
    index = 0
    while index < len(command):
        value = command[index]
        if value in VALUE_FLAGS:
            index += 2
            continue
        if value in BOOLEAN_FLAGS or any(value.startswith(flag + "=") for flag in VALUE_FLAGS):
            index += 1
            continue
        kept.append(value)
        index += 1
    return kept


def build_command(command):
    """`swift test <args>` becomes the `swift build --build-tests` that produces the same products.

    SwiftPM compiles identically for both when they share the build flags, including coverage
    instrumentation. `swift test list` is the odd one out: it ignores --enable-code-coverage, so
    letting it build first leaves uninstrumented products and forces `swift test` to compile the
    whole package a second time."""
    command = without_run_selectors(command)
    if command[:2] != ["swift", "test"]:
        raise ValueError("Expected a `swift test` command")
    rest = [value for value in command[2:] if value not in TEST_ONLY_FLAGS and value != "--skip-build"]
    return ["swift", "build", "--build-tests", *rest]


def integration_suites(root=ROOT):
    names = set()
    for path in (root / "Tests/HisingenTests/Integration").glob("*.swift"):
        text = path.read_text()
        if "@Test" in text:
            names.update(re.findall(r"\b(?:struct|class)\s+(\w+)", text))
    return names


def validate_selection(tests, filters=(), skips=(), suites=None):
    selected = select_tests(tests, filters, skips)
    if not selected:
        raise ValueError("No tests selected; check the filter/skip patterns and discovery output")
    if "Live" in skips:
        suites = integration_suites() if suites is None else suites
        leaked = [test for test in selected
                  if any(f".{suite}/" in test for suite in suites)]
        if leaked:
            raise ValueError("Integration tests escaped the deterministic exclusion: " + ", ".join(leaked))
    return selected


def validate_results(path):
    tree = ET.parse(path)
    cases = list(tree.iter("testcase"))
    executed = [case for case in cases if case.find("skipped") is None]
    if not executed:
        raise ValueError("Swift reported no executed tests (all tests may be disabled)")
    return {"executed": len(executed), "skipped": len(cases) - len(executed),
            "failed": sum(case.find("failure") is not None or case.find("error") is not None for case in cases)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    building = sub.add_parser("build")
    building.add_argument("--output", type=pathlib.Path, required=True)
    building.add_argument("command", nargs=argparse.REMAINDER)
    discovery = sub.add_parser("discover")
    discovery.add_argument("--output", type=pathlib.Path, required=True)
    discovery.add_argument("command", nargs=argparse.REMAINDER)
    selection = sub.add_parser("selection")
    selection.add_argument("listing", type=pathlib.Path)
    selection.add_argument("--output", type=pathlib.Path, required=True)
    selection.add_argument("--filter", action="append", default=[])
    selection.add_argument("--skip", action="append", default=[])
    selection.add_argument("swift_arguments", nargs=argparse.REMAINDER)
    run = sub.add_parser("run")
    run.add_argument("--output", type=pathlib.Path, required=True)
    run.add_argument("--xunit", action="store_true")
    run.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        if args.mode == "build":
            command = args.command[1:] if args.command[:1] == ["--"] else args.command
            args.output.mkdir(parents=True, exist_ok=True)
            with (args.output / "build.log").open("w") as log:
                process = subprocess.Popen(build_command(command), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                for line in process.stdout:
                    print(line, end="", flush=True)
                    log.write(line)
                return process.wait()
        if args.mode == "discover":
            command = args.command[1:] if args.command[:1] == ["--"] else args.command
            discovery = without_run_selectors(command)
            args.output.mkdir(parents=True, exist_ok=True)
            with (args.output / "discovered-tests.txt").open("w") as listing:
                result = subprocess.run(discovery + ["list"], stdout=listing, stderr=subprocess.PIPE, text=True, check=False)
                (args.output / "discovery-build.log").write_text(result.stderr)
                sys.stderr.write(result.stderr)
                return result.returncode
        if args.mode == "selection":
            index = 0
            while index < len(args.swift_arguments):
                value = args.swift_arguments[index]
                target = args.filter if value in ("--filter", "--specifier", "-s") or value.startswith(("--filter=", "--specifier=")) else args.skip if value == "--skip" or value.startswith("--skip=") else None
                if target is not None:
                    if "=" in value:
                        target.append(value.split("=", 1)[1])
                    else:
                        index += 1
                        if index >= len(args.swift_arguments):
                            raise ValueError(f"Missing value for {value}")
                        target.append(args.swift_arguments[index])
                index += 1
            discovered = discovered_tests(args.listing.read_text())
            selected = validate_selection(discovered, args.filter, args.skip)
            args.output.mkdir(parents=True, exist_ok=True)
            (args.output / "selection.json").write_text(json.dumps(
                {"discovered": len(discovered), "selected": len(selected), "tests": selected}, indent=2) + "\n")
            print(f"Test selection verified: {len(selected)} tests")
            return 0
        args.output.mkdir(parents=True, exist_ok=True)
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        if not command:
            raise ValueError("Missing Swift test command")
        result_path = args.output / "results.xml"
        if args.xunit:
            if "--xunit-output" in command:
                result_path = pathlib.Path(command[command.index("--xunit-output") + 1])
            elif any(value.startswith("--xunit-output=") for value in command):
                result_path = pathlib.Path(next(value.split("=", 1)[1] for value in command
                                               if value.startswith("--xunit-output=")))
            else:
                command += ["--xunit-output", str(result_path)]
            result_path.unlink(missing_ok=True)
        with (args.output / "test.log").open("w") as log:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                for line in process.stdout:
                    print(line, end="", flush=True)
                    log.write(line)
                code = process.wait()
            except BaseException:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                raise
        summary = {"exit_code": code}
        if args.xunit and (code == 0 or result_path.exists()):
            try:
                summary.update(validate_results(result_path))
                if summary["failed"]:
                    code = code or 1
            except (ValueError, OSError, ET.ParseError) as error:
                summary["validation_error"] = str(error)
                print(f"Test result validation failed: {error}", file=sys.stderr)
                code = code or 1
        summary["exit_code"] = code
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        if code == 0:
            print("Swift test execution verified")
        return code
    except (ValueError, OSError, re.error, ET.ParseError) as error:
        print(f"Test validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
