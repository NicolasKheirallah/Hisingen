#!/usr/bin/env python3
"""Decide whether a change needs the native macOS lanes.

A change that touches only documentation, the static site or the Home Assistant component
cannot alter the app binary, so the 15 to 40 minute macOS jobs add nothing. Everything else,
and any case where the base commit is unknown or the diff is empty, runs them.
"""
import os
import subprocess
import sys

DOC_ONLY_DIRECTORIES = ("docs/", "site/", "home-assistant/", ".github/ISSUE_TEMPLATE/", "changelog.d/")
DOC_ONLY_FILES = {".github/pull_request_template.md", "LICENSE"}
NULL_SHA = "0" * 40


def is_doc_only(path):
    if ".." in path.split("/"):
        return False
    if path in DOC_ONLY_FILES or path.startswith(DOC_ONLY_DIRECTORIES):
        return True
    return "/" not in path and path.endswith(".md")


def needs_native(paths):
    """True when any changed path can affect the built app, or when nothing is known."""
    paths = [path for path in paths if path]
    return not paths or any(not is_doc_only(path) for path in paths)


def changed_paths(base, head="HEAD"):
    if not base or base == NULL_SHA:
        return None
    result = subprocess.run(["git", "diff", "--name-only", "--no-renames", base, head], capture_output=True, text=True)
    return result.stdout.splitlines() if result.returncode == 0 else None


def main():
    paths = changed_paths(os.environ.get("CI_BASE_SHA", ""))
    native = True if paths is None else needs_native(paths)
    reason = "base commit unknown" if paths is None else f"{len(paths)} changed paths"
    print(f"native={'true' if native else 'false'} ({reason})")
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as stream:
            stream.write(f"native={'true' if native else 'false'}\n")


if __name__ == "__main__":
    sys.exit(main())
