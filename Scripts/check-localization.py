#!/usr/bin/env python3
"""Check Localizable.strings files for duplicate keys and report translation coverage.

Missing keys relative to the base locale are reported, not failed on: Hisingen's
L10n helper falls back to English for any key missing from the active locale
(Sources/Hisingen/Support/L10n.swift), so an incomplete translation is not a bug.
Duplicate keys within one file are: whichever line wins is unspecified.
"""
import pathlib
import re
import sys

RESOURCES_DIR = pathlib.Path("Sources/Hisingen/Resources")
BASE_LOCALE = "en"

KEY_RE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"(?:[^"\\]|\\.)*"\s*;\s*$')


def extract_keys(path):
    keys = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("/*"):
            continue
        match = KEY_RE.match(stripped)
        if match:
            keys.append((match.group(1), lineno))
    return keys


def main():
    status = 0
    base_file = RESOURCES_DIR / f"{BASE_LOCALE}.lproj" / "Localizable.strings"
    if not base_file.is_file():
        print(f"Base locale file not found: {base_file}")
        return 1

    locale_files = sorted(RESOURCES_DIR.glob("*.lproj/Localizable.strings"))
    if not locale_files:
        print(f"No Localizable.strings files found under {RESOURCES_DIR}")
        return 1

    print("== Checking for duplicate keys ==")
    for path in locale_files:
        keys = extract_keys(path)
        seen = {}
        dupes = set()
        for key, lineno in keys:
            if key in seen:
                dupes.add(key)
            seen[key] = lineno
        if dupes:
            status = 1
            print(f"FAIL {path}: duplicate keys: {sorted(dupes)}")

    base_keys = {key for key, _ in extract_keys(base_file)}
    print()
    print(f"== Coverage relative to base locale ({BASE_LOCALE}, {len(base_keys)} keys) ==")
    for path in locale_files:
        locale = path.parent.name[: -len(".lproj")]
        if locale == BASE_LOCALE:
            continue
        keys = {key for key, _ in extract_keys(path)}
        missing = len(base_keys - keys)
        print(f"{locale:6s} {len(keys):4d} / {len(base_keys):4d} keys  ({missing} missing, falls back to English)")

    if status == 0:
        print()
        print("No duplicate keys found.")
    return status


if __name__ == "__main__":
    sys.exit(main())
