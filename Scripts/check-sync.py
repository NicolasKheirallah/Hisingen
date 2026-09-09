#!/usr/bin/env python3
"""Fail when a source-tree file exists locally but is not committed to git.

CI builds the committed tree only, so an untracked file that the build, the
docs, or a test depends on makes a sync fail with confusing errors — or worse,
silently skips it. The docs/ directory is gitignored wholesale (a forgotten
`git add -f` there is invisible in `git status` on a busy tree); the docs-link
checker catches the linked-file case, this one catches build inputs.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WATCHED = ("Sources", "Tests", "Scripts", "Resources", ".github")


def untracked_files() -> list[str]:
    res = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard", "-z", "--", *WATCHED],
        cwd=ROOT,
        capture_output=True,
        check=True,
    )
    return sorted(line for line in res.stdout.decode().splitlines() if line)


def main() -> int:
    pending = untracked_files()
    if not pending:
        print("No untracked files under Sources/Tests/Scripts/Resources/.github — a sync cannot lose a build input.")
        return 0
    print("Untracked files exist under watched paths; a sync to GitHub will NOT include them:", file=sys.stderr)
    for path in pending:
        print(f"  {path}", file=sys.stderr)
    print("Commit them (git add) or remove them before pushing.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
