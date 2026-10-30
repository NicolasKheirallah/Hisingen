#!/usr/bin/env python3
"""Enforce exact Localizable.strings key parity, reject duplicate keys, and ratchet untranslated values.

Parity: every locale must carry exactly the base locale's keys.

Untranslated ratchet: a value identical to its English base value is counted as untranslated,
unless every word in it is exempt (format specifiers, units, acronyms, short codes, brand names,
or an exact allowlisted value). Per-locale counts are compared with
Scripts/l10n-untranslated-baseline.json. The check fails only when a locale's count rises above
its baseline, so the existing backlog is visible without blocking unrelated work.

Flags:
  --sync                   Insert English placeholders for missing keys and drop obsolete keys.
                           Placeholders ship untranslated until a translator replaces them.
  --report LOCALE          List the untranslated keys for one locale and exit.
  --update-baseline        Rewrite the untranslated baseline from the current tree. Use only
                           after review: lowering a count locks in a fix, raising one accepts
                           new English-only strings.
"""
import json
import pathlib
import re
import sys

RESOURCES_DIR = pathlib.Path("Sources/Hisingen/Resources")
BASE_LOCALE = "en"
BASELINE_PATH = pathlib.Path("Scripts/l10n-untranslated-baseline.json")

KEY_RE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')

# Printf-style specifiers, escaped unicode/newline sequences, and percent literals carry no words.
FORMAT_RE = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:@|d|f|s|x|ld|lu|%)|%%|\\u\{[0-9A-Fa-f]+\}|\\[nt]")
WORD_RE = re.compile(r"[^\W\d_]+")

# Units and abbreviations that read the same in every language.
UNIT_WORDS = {
    "kwh", "wh", "kw", "kwp", "km", "mi", "mph", "kg", "kr", "mpg", "ms", "min", "hr", "hrs",
    "h", "l", "v", "a", "w", "c", "f", "db", "m", "s", "d", "pm", "ac", "dc",
}
# Brand and product names that are never translated.
BRAND_WORDS = {"hisingen", "polestar", "volvo", "github", "apple", "macos", "ios", "sparkle"}
# Exact values that are intentionally identical to English.
ALLOWED_VALUES = {"Hisingen Glass"}


def is_exempt(value):
    if value in ALLOWED_VALUES:
        return True
    text = FORMAT_RE.sub(" ", value)
    for word in WORD_RE.findall(text):
        lower = word.lower()
        if len(word) <= 2 or (word.isupper() and len(word) <= 5):
            continue
        if lower in UNIT_WORDS or lower in BRAND_WORDS:
            continue
        return False
    return True


def extract_entries(path):
    """Return (key, value, lineno) for every key/value line in a strings file."""
    entries = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("/*"):
            continue
        match = KEY_RE.match(stripped)
        if match:
            entries.append((match.group(1), match.group(2), lineno))
    return entries


def extract_keys(path):
    return [(key, lineno) for key, _, lineno in extract_entries(path)]


def untranslated_keys(base_values, locale_values):
    """Keys whose locale value equals the English value and is not exempt, in base order."""
    return [
        key
        for key, value in base_values.items()
        if key in locale_values and locale_values[key] == value and not is_exempt(value)
    ]


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
    return len(missing)


def load_baseline():
    if not BASELINE_PATH.is_file():
        return None
    return json.loads(BASELINE_PATH.read_text(encoding="utf-8"))


def main():
    argv = sys.argv[1:]
    status = 0

    report_locale = None
    if "--report" in argv:
        index = argv.index("--report")
        if index + 1 >= len(argv):
            print("--report requires a locale, for example: --report de")
            return 1
        report_locale = argv[index + 1]

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

    if "--sync" in argv:
        print("!" * 72)
        print("WARNING: --sync inserts ENGLISH PLACEHOLDER values for every missing key.")
        print("Those strings ship untranslated in the affected locales until a translator")
        print("replaces them. Each insert raises that locale's untranslated count.")
        print("!" * 72)
        raw_base_lines = base_file.read_text(encoding="utf-8").splitlines()
        base_lines = {
            match.group(1): line
            for line in raw_base_lines
            if (match := KEY_RE.match(line.strip()))
        }
        for path in locale_files:
            if path != base_file:
                added = sync_locale(path, base_lines, base_order, base_keys)
                if added:
                    print(f"  {path.parent.name[:-6]}: inserted {added} English placeholder(s)")
        print()

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

    base_values = {key: value for key, value, _ in extract_entries(base_file)}
    locale_untranslated = {}
    for path in locale_files:
        locale = path.parent.name[: -len(".lproj")]
        if locale == BASE_LOCALE:
            continue
        values = {key: value for key, value, _ in extract_entries(path)}
        locale_untranslated[locale] = untranslated_keys(base_values, values)

    if report_locale is not None:
        if report_locale not in locale_untranslated:
            print(f"Unknown locale: {report_locale}. Known: {', '.join(sorted(locale_untranslated))}")
            return 1
        keys = locale_untranslated[report_locale]
        print()
        print(f"== Untranslated in {report_locale}: {len(keys)} value(s) identical to English ==")
        for key in keys:
            print(f"  {key}")
        return status

    counts = {locale: len(keys) for locale, keys in sorted(locale_untranslated.items())}

    if "--update-baseline" in argv:
        if status != 0:
            print("Not writing the untranslated baseline while parity or duplicate checks fail.")
            return status
        BASELINE_PATH.write_text(json.dumps(counts, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print()
        print(f"Wrote {BASELINE_PATH} with {len(counts)} locale count(s).")
        return 0

    print()
    print("== Untranslated values (identical to English, excluding exempt tokens) ==")
    baseline = load_baseline()
    if baseline is None:
        status = 1
        print(f"FAIL {BASELINE_PATH} is missing. Create it with --update-baseline.")
    else:
        for locale, count in counts.items():
            allowed = baseline.get(locale)
            if allowed is None:
                status = 1
                print(f"FAIL {locale:6s} {count:4d} untranslated, no baseline entry for this locale")
            elif count > allowed:
                status = 1
                print(f"FAIL {locale:6s} {count:4d} untranslated, baseline {allowed} (+{count - allowed} new English-only value(s))")
                print(f"     run: python3 Scripts/check-localization.py --report {locale}")
            elif count < allowed:
                print(f"OK   {locale:6s} {count:4d} untranslated, baseline {allowed} (improved; lock in with --update-baseline)")
            else:
                print(f"OK   {locale:6s} {count:4d} untranslated, baseline {allowed}")

    if status == 0:
        print()
        print("Localization key parity, uniqueness, and untranslated ratchet checks passed.")
    return status


if __name__ == "__main__":
    sys.exit(main())
