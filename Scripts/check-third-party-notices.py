#!/usr/bin/env python3
"""Check THIRD_PARTY_NOTICES.md against what the repository actually depends on.

Three checks, all offline:

1. Every package pinned in Package.resolved is named in the notices, its pinned version appears
   there, and any versioned `.../blob/<version>/LICENSE` link for it points at the pinned version.
2. Every outside host the Swift sources reach (https:// literals and `components.host = "..."`)
   is named in the notices, unless it is on the allowlist of hosts that are not data services.
3. Every project the sources credit as something they cross-checked, ported or adapted from (a
   github.com URL, or a comment such as "cross-checked against owner/repo") is named in the notices.

It does not judge licenses or attribution wording. That stays a human review.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
RESOLVED = ROOT / "Package.resolved"
SOURCES = ROOT / "Sources"

# Hosts that appear in the sources but are not outside services Hisingen sends data to.
ALLOWED_HOSTS = {
    "www.w3.org",                  # XML namespace URIs
    "github.com",                  # links to the project and its author
    "nicolaskheirallah.github.io",  # Hisingen's own OAuth callback page
}

URL_RE = re.compile(r"https?://([A-Za-z0-9.-]+)")
HOST_ASSIGN_RE = re.compile(r'\.host\s*=\s*"([A-Za-z0-9.-]+)"')
GITHUB_URL_RE = re.compile(r"github\.com/([A-Za-z0-9-]+/[A-Za-z0-9_.-]+)")
# Phrases that introduce another project in a source comment. Free-form `a/b` tokens are far
# too common ("km/day", "low/high") to scan for, so only a named relationship counts.
CREDIT_CUE_RE = re.compile(
    r"(?:cross-checked\s+against|independently\s+built|ported\s+from|adapted\s+from|derived\s+from"
    r"|borrowed\s+from)\s+(?:the\s+)?`?([A-Za-z0-9-]{4,39}/[A-Za-z0-9_.-]{3,100}?)`?"
    r"(?=[\s,.;:)']|$)",
    re.IGNORECASE,
)
# Repositories that are the project itself rather than a third party.
OWN_REPOS = {"nicolaskheirallah/hisingen", "nicolaskheirallah"}


def check_packages(notices: str) -> list[str]:
    errors = []
    pins = json.loads(RESOLVED.read_text())["pins"]
    lowered = notices.lower()
    license_links = re.sub(r"```[^\n]*\n[\s\S]*?```", "", notices)
    for pin in pins:
        repo = pin["location"].removesuffix(".git").split("github.com/")[-1]
        version = pin["state"].get("version")
        if repo.lower() not in lowered:
            errors.append(f"Package.resolved pins {repo}, which THIRD_PARTY_NOTICES.md does not name")
        if version and version not in notices:
            errors.append(f"{repo} is pinned at {version}, which THIRD_PARTY_NOTICES.md does not mention")
        if version:
            for linked in re.findall(rf"{re.escape(repo)}/blob/([^/]+)/", license_links, re.IGNORECASE):
                if linked != version:
                    errors.append(f"{repo} license link uses {linked} but Package.resolved pins {version}")
    return errors


def comment_blocks(text: str) -> list[str]:
    """Join each run of consecutive `//` comment lines into one string, so a project name that
    wraps onto the next line is still seen after its introducing phrase."""
    blocks, current = [], []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            current.append(stripped.lstrip("/").strip())
        elif current:
            blocks.append(" ".join(current))
            current = []
    if current:
        blocks.append(" ".join(current))
    return blocks


def referenced_projects() -> dict[str, str]:
    """Map each `owner/repo` the sources name (a github.com URL, or a comment that says it
    cross-checked, ported or adapted something from it) to one file that does."""
    found: dict[str, str] = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        text = path.read_text(errors="ignore")
        where = str(path.relative_to(ROOT))
        for repo in GITHUB_URL_RE.findall(text):
            found.setdefault(repo.removesuffix(".git").lower(), where)
        for block in comment_blocks(text):
            for repo in CREDIT_CUE_RE.findall(block):
                found.setdefault(repo.lower(), where)
    return found


def check_projects(notices: str) -> list[str]:
    errors = []
    lowered = notices.lower()
    for repo, where in sorted(referenced_projects().items()):
        owner = repo.split("/")[0]
        if repo in OWN_REPOS or owner in OWN_REPOS:
            continue
        if repo not in lowered:
            errors.append(f"{where} names {repo}, which THIRD_PARTY_NOTICES.md does not credit")
    return errors


def source_hosts() -> dict[str, str]:
    """Map each outside host to one file that uses it."""
    found: dict[str, str] = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        for line in path.read_text(errors="ignore").splitlines():
            if line.lstrip().startswith("//"):
                continue
            for host in URL_RE.findall(line) + HOST_ASSIGN_RE.findall(line):
                found.setdefault(host.rstrip(".").lower(), str(path.relative_to(ROOT)))
    return found


def check_hosts(notices: str) -> list[str]:
    errors = []
    lowered = notices.lower()
    for host, where in sorted(source_hosts().items()):
        if host in ALLOWED_HOSTS:
            continue
        bare = host.removeprefix("www.")
        if host not in lowered and bare not in lowered:
            errors.append(f"{where} reaches {host}, which THIRD_PARTY_NOTICES.md does not name")
    return errors


def main() -> int:
    notices = NOTICES.read_text()
    errors = check_packages(notices) + check_hosts(notices) + check_projects(notices)
    if errors:
        print("THIRD_PARTY_NOTICES.md is out of date:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("THIRD_PARTY_NOTICES.md matches Package.resolved, the hosts and the projects named in Sources/.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
