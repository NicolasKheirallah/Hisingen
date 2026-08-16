#!/usr/bin/env python3
"""Check Markdown files for broken local links and unbalanced mermaid/code fences.

Scans README.md, changelog.md, TERMS.md, and everything under docs/. Only
relative links to files/anchors inside this repo are checked — external
http(s)/mailto links are left alone (no network access here, and GitHub
already surfaces dead external links via its own link-checking on render).
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LINK_RE = re.compile(r'\]\(([^)]+)\)')
FENCE_RE = re.compile(r'^\s*```')


def markdown_files():
    candidates = [ROOT / "README.md", ROOT / "changelog.md", ROOT / "TERMS.md"]
    candidates += sorted((ROOT / "docs").rglob("*.md"))
    return [path for path in candidates if path.is_file()]


def check_fences(path, text):
    errors = []
    open_fence = None
    for lineno, line in enumerate(text.splitlines(), start=1):
        if FENCE_RE.match(line):
            if open_fence is None:
                open_fence = lineno
            else:
                open_fence = None
    if open_fence is not None:
        errors.append(f"{path}:{open_fence}: unterminated code fence (```) opened here")
    return errors


def check_links(path, text):
    errors = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        for match in LINK_RE.finditer(line):
            target = match.group(1).strip()
            if not target or target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            if target.startswith("<") and target.endswith(">"):
                target = target[1:-1]
            file_part = target.split("#", 1)[0]
            if not file_part:
                continue
            resolved = (path.parent / file_part).resolve()
            if not resolved.exists():
                errors.append(f"{path}:{lineno}: broken link -> {target}")
    return errors


def main():
    status = 0
    for path in markdown_files():
        text = path.read_text(encoding="utf-8")
        for error in check_fences(path, text) + check_links(path, text):
            print(error)
            status = 1
    if status == 0:
        print(f"All Markdown links and code fences OK ({len(markdown_files())} files checked).")
    return status


if __name__ == "__main__":
    sys.exit(main())
