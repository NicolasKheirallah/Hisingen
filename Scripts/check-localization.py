#!/usr/bin/env python3
"""Enforce exact Localizable.strings key parity and reject duplicate keys.

Run with --sync to add missing keys using the reviewed English base value and remove
obsolete entries. This makes fallback visible in translation review while ensuring a
locale can never silently miss a newly introduced Settings label.
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


def sync_locale(path, base_lines, base_order, base_keys):
    lines = path.read_text(encoding="utf-8").splitlines()
    kept = []
    present = set()
    for line in lines:
        match = KEY_RE.match(line.strip())
        if match:
            key = match.group(1)
            if key not in base_keys:
                continue
            present.add(key)
        kept.append(line)
    missing = [key for key in base_order if key not in present]
    if missing:
        kept.extend(["", "// English fallback values pending translation"])
        kept.extend(base_lines[key] for key in missing)
    path.write_text("\n".join(kept).rstrip() + "\n", encoding="utf-8")


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

    base_entries = extract_keys(base_file)
    base_order = [key for key, _ in base_entries]
    base_keys = set(base_order)

    if "--sync" in sys.argv:
        raw_base_lines = base_file.read_text(encoding="utf-8").splitlines()
        base_lines = {
            match.group(1): line
            for line in raw_base_lines
            if (match := KEY_RE.match(line.strip()))
        }
        for path in locale_files:
            if path != base_file:
                sync_locale(path, base_lines, base_order, base_keys)

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

    print()
    print(f"== Coverage relative to base locale ({BASE_LOCALE}, {len(base_keys)} keys) ==")
    for path in locale_files:
        locale = path.parent.name[: -len(".lproj")]
        if locale == BASE_LOCALE:
            continue
        keys = {key for key, _ in extract_keys(path)}
        missing = base_keys - keys
        extra = keys - base_keys
        if missing or extra:
            status = 1
            print(f"FAIL {locale:6s} {len(keys):4d} / {len(base_keys):4d} keys  ({len(missing)} missing, {len(extra)} obsolete)")
        else:
            print(f"OK   {locale:6s} {len(keys):4d} / {len(base_keys):4d} keys")

    if status == 0:
        print()
        print("Localization key parity and uniqueness checks passed.")
    return status


if __name__ == "__main__":
    sys.exit(main())
