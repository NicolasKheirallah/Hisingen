#!/usr/bin/env python3
"""Changelog fragments: one small file per change, assembled into CHANGELOG.md at release time.

Every change used to edit the same section of CHANGELOG.md, so any two open pull requests
conflicted and the release preparation had to guess entries from commit subjects. A change now
adds `changelog.d/<slug>.<type>.md` holding one bullet. Release preparation moves the fragments
into the new version's section, in filename order, and removes them.

    python3 Scripts/changelog.py check
    python3 Scripts/changelog.py assemble VERSION
"""
import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
FRAGMENTS = ROOT / "changelog.d"
CHANGELOG = ROOT / "CHANGELOG.md"

# Order in which subsections appear inside a release. A subsection that is not listed here,
# such as Screenshots, stays where it is and keeps the entries added after it.
TYPES = ("Added", "Changed", "Fixed", "Removed", "Security")
NAME = re.compile(r"[a-z0-9][a-z0-9-]*\.(" + "|".join(t.lower() for t in TYPES) + r")\.md\Z")
LEAD = re.compile(r"- \*\*[^*\n]+\.\*\* \S")


def fragment_paths(directory=FRAGMENTS):
    """Fragment files in the order they are assembled. README.md documents the folder."""
    if not directory.is_dir():
        return []
    return sorted(path for path in directory.iterdir() if path.is_file() and path.name != "README.md" and not path.name.startswith("."))


def problems(path):
    """Reasons a fragment cannot be assembled, empty when it is fine."""
    found = []
    if not NAME.fullmatch(path.name):
        found.append("name must be <slug>.<added|changed|fixed|removed|security>.md with a lowercase slug")
    text = path.read_text(encoding="utf-8")
    lines = text.rstrip("\n").split("\n")
    if not text.endswith("\n") or text.endswith("\n\n"):
        found.append("must end with exactly one newline")
    if not LEAD.match(lines[0]):
        found.append("first line must be '- **Short sentence.** Then the explanation.'")
    for number, line in enumerate(lines[1:], start=2):
        if not line:
            found.append(f"line {number}: one entry is one paragraph, with no blank lines")
        elif not line.startswith("  ") or line.startswith("   "):
            found.append(f"line {number}: continuation lines are indented by exactly two spaces")
    if any(line.startswith(("#", "- ", "* ")) for line in lines[1:]):
        found.append("one fragment holds one bullet and no headings")
    if "\t" in text:
        found.append("no tabs")
    return found


def section_bounds(text, version):
    match = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n", text, re.M)
    if not match:
        raise ValueError(f"CHANGELOG.md has no section for {version}")
    following = re.search(r"^## \[", text[match.end():], re.M)
    end = match.end() + following.start() if following else len(text)
    return match.end(), end


def insert_entries(text, version, entries):
    """Adds {type: [bullet, ...]} to the version's section, creating subsections in order."""
    start, end = section_bounds(text, version)
    body = text[start:end]
    for kind in TYPES:
        bullets = entries.get(kind)
        if not bullets:
            continue
        block = "\n\n".join(bullets) + "\n\n"
        heading = re.search(rf"^### {kind}\n", body, re.M)
        if heading:
            after = re.search(r"^### ", body[heading.end():], re.M)
            tail = heading.end() + after.start() if after else len(body)
            body = body[:tail].rstrip("\n") + "\n\n" + block + body[tail:]
            continue
        later = TYPES[TYPES.index(kind) + 1:]
        position = len(body)
        for candidate in re.finditer(r"^### (\S[^\n]*)\n", body, re.M):
            name = candidate.group(1)
            if name in later or name not in TYPES:
                position = candidate.start()
                break
        before = body[:position].rstrip("\n")
        body = (before + "\n\n" if before.strip() else "\n") + f"### {kind}\n\n" + block + body[position:]
    return text[:start] + body + text[end:]


def assemble(version, changelog=CHANGELOG, directory=FRAGMENTS):
    """Moves every fragment into CHANGELOG.md and deletes the files. Returns how many moved."""
    paths = fragment_paths(directory)
    broken = {path.name: problems(path) for path in paths if problems(path)}
    if broken:
        raise ValueError("; ".join(f"{name}: {', '.join(reasons)}" for name, reasons in broken.items()))
    entries = {}
    for path in paths:
        kind = path.name.rsplit(".", 2)[1].capitalize()
        entries.setdefault(kind, []).append(path.read_text(encoding="utf-8").rstrip("\n"))
    if not paths:
        return 0
    changelog.write_text(insert_entries(changelog.read_text(encoding="utf-8"), version, entries), encoding="utf-8")
    for path in paths:
        path.unlink()
    return len(paths)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    target = commands.add_parser("assemble")
    target.add_argument("version")
    args = parser.parse_args()
    try:
        if args.command == "check":
            failed = False
            for path in fragment_paths():
                for reason in problems(path):
                    print(f"{path.relative_to(ROOT)}: {reason}", file=sys.stderr)
                    failed = True
            if failed:
                return 1
            print(f"changelog-fragments-ok: {len(fragment_paths())}")
        else:
            print(f"changelog-fragments-assembled: {assemble(args.version)}")
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
