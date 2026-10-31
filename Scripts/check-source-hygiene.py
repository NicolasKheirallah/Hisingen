#!/usr/bin/env python3
"""Check tracked source inputs and the selected commit range; never print credential values."""
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
GENERATED = {"Sources/Hisingen/Services/API/GeneratedVolvoSecrets.swift", "Sources/Hisingen/Services/API/GeneratedPolestarSecrets.swift"}
SECRET_NAME = re.compile(r"(^|/)(\.env(?:\..+)?|.*\.(pem|p12|key))$")
SECRET_CONTENT = re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}")


def run(*args, **kwargs):
    return subprocess.run(["git", *args], cwd=ROOT, check=True, **kwargs)


def inspect_file(name, data):
    if name in GENERATED or (SECRET_NAME.search(name) and Path(name).name != ".env.example"):
        raise ValueError(f"Tracked secret-like/generated file: {name!r}")
    if SECRET_CONTENT.search(data):
        raise ValueError(f"Credential pattern in tracked file: {name!r}")


def main():
    files = run("ls-files", "-z", capture_output=True).stdout.split(b"\0")
    for raw in filter(None, files):
        name = os.fsdecode(raw)
        path = ROOT / name
        inspect_file(name, path.read_bytes() if path.is_file() else b"")
    base = os.environ.get("CI_BASE_SHA", "")
    if base:
        if not re.fullmatch(r"[0-9a-fA-F]{40}", base):
            raise ValueError("CI_BASE_SHA must be a full commit SHA")
        run("diff", "--check", base, "HEAD")
    else:
        # show checks the committed patch, whereas diff alone sees only local edits.
        run("show", "--format=", "--check", "HEAD")
    run("diff", "--check")
    run("diff", "--cached", "--check")
    print("source-hygiene-passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
