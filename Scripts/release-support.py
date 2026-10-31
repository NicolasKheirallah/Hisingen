#!/usr/bin/env python3
"""Release identity, versioning, checkpoints and publication state."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")


def run(*args, check=True, input=None):
    result = subprocess.run(args, text=True, input=input, capture_output=True, timeout=180)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} failed: {result.stderr.strip()}")
    return result


def semver(value):
    value = value.removeprefix("v")
    if not VERSION.fullmatch(value):
        raise ValueError("Expected a stable MAJOR.MINOR.PATCH version without leading zeroes")
    return tuple(map(int, value.split(".")))


def version_string(value):
    return ".".join(map(str, value))


def next_version(latest, current, bump="patch"):
    current_parts = semver(current)
    latest_parts = semver(latest) if latest else (0, 0, 0)
    if current_parts < latest_parts:
        raise ValueError("Info.plist version is behind the latest stable tag")
    if bump not in ("patch", "minor", "major"):
        requested = semver(bump)
    elif current_parts > latest_parts:
        requested = current_parts
    elif not latest:
        requested = current_parts
    else:
        major, minor, patch = latest_parts
        requested = {"patch": (major, minor, patch + 1), "minor": (major, minor + 1, 0), "major": (major + 1, 0, 0)}[bump]
    if requested <= latest_parts:
        raise ValueError("New version must be greater than the latest stable release")
    return version_string(requested)


def latest_tag():
    tags = run("git", "tag", "--merged", "origin/main", "--list", "v*").stdout.splitlines()
    valid = [tag for tag in tags if VERSION.fullmatch(tag.removeprefix("v"))]
    return max(valid, key=semver) if valid else None


def plist_at(ref=None):
    data = run("git", "show", f"{ref}:Resources/Info.plist").stdout.encode() if ref else Path("Resources/Info.plist").read_bytes()
    return plistlib.loads(data)


def ensure_build_increases(plist, previous):
    build = str(plist["CFBundleVersion"])
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("CFBundleVersion must be a positive integer")
    if previous and int(build) <= int(previous["CFBundleVersion"]):
        raise ValueError("CFBundleVersion must increase beyond the previous release")


def validate(tag):
    if not tag.startswith("v"):
        raise ValueError("Release tag must start with v")
    semver(tag)
    head = run("git", "rev-parse", "HEAD").stdout.strip()
    tagged = run("git", "rev-parse", f"refs/tags/{tag}^{{commit}}").stdout.strip()
    if head != tagged:
        raise ValueError("Release checkout does not equal the tagged commit")
    inputs = ("Sources", "Resources", "Package.swift", "Package.resolved", "Scripts", ".github", "CHANGELOG.md", "Makefile", "LICENSE", "THIRD_PARTY_NOTICES.md", "site/oauth-callback.html")
    if run("git", "diff", "--quiet", "HEAD", "--", *inputs, check=False).returncode:
        raise ValueError("Tracked release build inputs differ from the tagged commit")
    if run("git", "ls-files", "--others", "--exclude-standard", "--", *inputs).stdout:
        raise ValueError("Untracked release build inputs are not part of the tagged commit")
    run("git", "merge-base", "--is-ancestor", head, "origin/main")
    plist = plist_at()
    if plist["CFBundleShortVersionString"] != tag[1:]:
        raise ValueError("Tag and Info.plist versions differ")
    if not re.search(rf"^## \[{re.escape(tag[1:])}\](?:\s|$)", Path("CHANGELOG.md").read_text(), re.M):
        raise ValueError("CHANGELOG.md does not contain this release")
    earlier = [t for t in run("git", "tag", "--merged", "HEAD", "--list", "v*").stdout.splitlines() if VERSION.fullmatch(t[1:]) and semver(t) < semver(tag)]
    previous = max(earlier, key=semver) if earlier else None
    ensure_build_increases(plist, plist_at(previous) if previous else None)
    return head


def prepare(bump):
    if run("git", "status", "--porcelain=v1").stdout:
        raise ValueError("Release preparation requires a clean checkout")
    if run("git", "rev-parse", "HEAD").stdout != run("git", "rev-parse", "origin/main").stdout:
        raise ValueError("Release preparation must start at current origin/main")
    current = plist_at()
    latest = latest_tag()
    version = next_version(latest, current["CFBundleShortVersionString"], bump)
    branch = f"release/v{version}"
    existing = run("git", "ls-remote", "--heads", "origin", f"refs/heads/{branch}").stdout.strip()
    if not existing:
        current["CFBundleShortVersionString"] = version
        current["CFBundleVersion"] = str(int(current["CFBundleVersion"]) + 1)
        text = Path("CHANGELOG.md").read_text()
        heading = f"## [{version}] - {datetime.now(timezone.utc).date()}"
        if not re.search(rf"^## \[{re.escape(version)}\](?:\s|$)", text, re.M):
            if "## [Unreleased]" in text:
                text = text.replace("## [Unreleased]", heading, 1)
            else:
                commits = run("git", "log", "--format=%s", f"{latest}..HEAD" if latest else "HEAD").stdout.splitlines()
                notes = "\n".join(f"- {line}" for line in commits if not line.startswith("chore(release):"))
                entry = f"{heading}\n\n### Changed\n\n{notes}\n\n"
                match = re.search(r"^## \[", text, re.M)
                pos = match.start() if match else len(text)
                text = text[:pos] + entry + text[pos:]
        run("git", "checkout", "-b", branch)
        Path("Resources/Info.plist").write_bytes(plistlib.dumps(current, sort_keys=False))
        Path("CHANGELOG.md").write_text(text)
        run("git", "config", "user.name", "github-actions[bot]")
        run("git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")
        run("git", "add", "Resources/Info.plist", "CHANGELOG.md")
        run("git", "commit", "-m", f"chore(release): prepare v{version}")
        run("git", "push", "--set-upstream", "origin", f"HEAD:refs/heads/{branch}")
    prs = json.loads(run("gh", "pr", "list", "--head", branch, "--base", "main", "--state", "open", "--json", "url").stdout)
    if not prs:
        run("gh", "pr", "create", "--base", "main", "--head", branch, "--title", f"chore(release): prepare v{version}", "--body", f"Prepare v{version}. After this pull request passes CI and merges, Auto Release tags the tested main commit and dispatches production release.")
    # GITHUB_TOKEN-created branches and PRs need explicit checks.
    run("gh", "workflow", "run", "ci.yml", "--ref", branch)
    run("gh", "workflow", "run", "security.yml", "--ref", branch)
    print(f"Release pull request ready: {branch}")


def auto():
    expected = os.environ["CI_HEAD_SHA"]
    head = run("git", "rev-parse", "HEAD").stdout.strip()
    current_main = run("git", "ls-remote", "origin", "refs/heads/main").stdout.split()[0]
    if head != expected or head != current_main:
        print("Release skipped: a newer main commit exists")
        return
    if run("git", "status", "--porcelain=v1").stdout:
        raise ValueError("Auto release requires a clean checkout")
    if "[skip release]" in run("git", "log", "-1", "--format=%B").stdout:
        print("Release skipped by commit")
        return
    latest = latest_tag()
    current = plist_at()["CFBundleShortVersionString"]
    if latest and semver(current) < semver(latest):
        raise ValueError("Info.plist version is behind the latest stable release")
    tag = f"v{current}"
    if not latest or semver(current) > semver(latest):
        existing = run("git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}", check=False)
        if existing.returncode == 0 and existing.stdout.strip() != head:
            raise ValueError("Release tag already points to another commit")
        if existing.returncode:
            run("git", "tag", "-a", tag, "-m", f"Release {tag}", head)
            validate(tag)
            run("git", "push", "origin", f"refs/tags/{tag}")
        validate(tag)
        run("gh", "workflow", "run", "release.yml", "--ref", tag, "-f", f"tag={tag}")
        print(f"Release dispatched for tested commit {head}: {tag}")
        return
    existing = run("git", "rev-parse", f"refs/tags/{tag}^{{commit}}").stdout.strip()
    if existing == head:
        release = run("gh", "release", "view", tag, "--json", "isDraft", check=False)
        if release.returncode or json.loads(release.stdout)["isDraft"]:
            run("gh", "workflow", "run", "release.yml", "--ref", tag, "-f", f"tag={tag}")
            print(f"Release dispatch resumed: {tag}")
        else:
            print("Release already published")
        return
    prepare("patch")


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def create_manifest(path, tag, files):
    sha = validate(tag)
    if len({Path(f).name for f in files}) != len(files):
        raise ValueError("Artifact basenames must be unique")
    toolchain = {"developer_dir": os.environ.get("DEVELOPER_DIR", ""), "architecture": platform.machine()}
    if toolchain["developer_dir"]:
        toolchain.update(xcode=run("xcodebuild", "-version").stdout.strip(), swift=run("swift", "--version").stdout.strip(), sdk=run("xcrun", "--sdk", "macosx", "--show-sdk-version").stdout.strip())
    data = {"schema": 1, "tag": tag, "source_sha": sha, "version": tag[1:], "build": str(plist_at()["CFBundleVersion"]), "files": {str(f): digest(f) for f in files}, "toolchain": toolchain}
    Path(path).write_text(json.dumps(data, indent=2) + "\n")


def verify_manifest(path, tag):
    data = json.loads(Path(path).read_text())
    if data["schema"] != 1 or data["tag"] != tag or data["source_sha"] != validate(tag):
        raise ValueError("Checkpoint identity does not match the release source")
    if data["build"] != str(plist_at()["CFBundleVersion"]) or data["version"] != tag[1:]:
        raise ValueError("Checkpoint version/build does not match source")
    if not data["files"]:
        raise ValueError("Empty checkpoint manifest")
    for name, expected in data["files"].items():
        file = Path(name)
        if file.is_absolute() or ".." in file.parts:
            raise ValueError("Checkpoint path escapes artifact directory")
        if file.is_symlink() or digest(file) != expected:
            raise ValueError(f"Checkpoint digest mismatch: {name}")
    return data


def published_versions():
    tags = run("gh", "api", "--paginate", "repos/{owner}/{repo}/releases?per_page=100", "--jq", ".[] | select(.draft == false and .prerelease == false) | .tag_name").stdout.splitlines()
    return [tag for tag in tags if VERSION.fullmatch(tag.removeprefix("v"))]


def monotonic(tag):
    semver(tag)
    published = published_versions()
    if published and semver(tag) < max(map(semver, published)):
        raise ValueError("A newer version is already published; refusing distribution rollback")


def publish(tag):
    data = verify_manifest("release-manifest.json", tag)
    monotonic(tag)
    found = run("gh", "release", "view", tag, "--json", "isDraft", check=False)
    if found.returncode:
        if "not found" not in found.stderr.lower() and "404" not in found.stderr:
            raise RuntimeError(found.stderr)
        run("gh", "release", "create", tag, "--verify-tag", "--draft", "--title", tag, "--generate-notes")
        is_draft = True
    else:
        is_draft = json.loads(found.stdout)["isDraft"]
    files = list(data["files"]) + ["release-manifest.json"]
    if is_draft:
        run("gh", "release", "upload", tag, *files, "--clobber")
    with tempfile.TemporaryDirectory(prefix="hisingen-published-") as temp:
        run("gh", "release", "download", tag, "--dir", temp)
        for file in files:
            if digest(Path(temp) / Path(file).name) != digest(file):
                raise ValueError(f"Published asset differs from checkpoint: {file}")
    if is_draft:
        monotonic(tag)
        run("gh", "release", "edit", tag, "--draft=false", "--latest")
    print(f"Verified complete release: {tag}")


def notarize(artifact):
    artifact = Path(artifact)
    state_dir = Path(os.environ.get("NOTARY_STATE_DIR", "releases/notary-state"))
    state_dir.mkdir(parents=True, exist_ok=True)
    if artifact.is_dir():
        archive = Path(os.environ.get("NOTARY_SUBMISSION_ARCHIVE", str(state_dir / f"{artifact.name}.zip")))
        if not os.environ.get("NOTARY_SUBMISSION_ARCHIVE"):
            run("ditto", "-c", "-k", "--keepParent", str(artifact), str(archive))
    else:
        archive = artifact
    archive_sha = digest(archive)
    state_file = state_dir / f"{artifact.name}.json"
    credential_names = ("NOTARY_APPLE_ID", "NOTARY_TEAM_ID", "NOTARY_APP_PASSWORD")
    auth = ["--apple-id", os.environ["NOTARY_APPLE_ID"], "--team-id", os.environ["NOTARY_TEAM_ID"], "--password", os.environ["NOTARY_APP_PASSWORD"]] if all(os.environ.get(name) for name in credential_names) else ["--keychain-profile", os.environ.get("NOTARYTOOL_PROFILE", "hisingen-notary")]

    def request(operation, *values):
        try:
            result = subprocess.run(["xcrun", "notarytool", operation, *values, *auth, "--output-format", "json"], capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess([], 124, "", "network timeout"), {}
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError:
            payload = {}
        return result, payload

    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    if artifact.is_file() and state.get("accepted_sha256") == archive_sha:
        run("sh", "Scripts/stapler-validate.sh", str(artifact))
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", str(artifact))
        print(f"Previously notarized checkpoint verified: {artifact}")
        return
    if state.get("sha256") != archive_sha:
        state = {"sha256": archive_sha}
    if not state.get("id"):
        for attempt in range(3):
            result, payload = request("submit", str(archive))
            if payload.get("id"):
                state["id"] = payload["id"]
                state_file.write_text(json.dumps(state, indent=2) + "\n")
                break
            transient = any(word in result.stderr.lower() for word in ("network", "connection", "timed out", "temporarily", "http 5"))
            if not transient or attempt == 2:
                raise RuntimeError("Notarization submission failed before returning a request ID")
            time.sleep(10 * (attempt + 1))
    request_id = state["id"]
    print(f"Notary request: {request_id}", flush=True)
    deadline = time.monotonic() + 1200
    while time.monotonic() < deadline:
        result, payload = request("info", request_id)
        status = payload.get("status")
        if status:
            (state_dir / f"{artifact.name}-status.json").write_text(json.dumps(payload, indent=2) + "\n")
        if status == "Accepted":
            break
        if status in ("Invalid", "Rejected"):
            log_result, log = request("log", request_id)
            if log_result.returncode == 0:
                (state_dir / f"{artifact.name}-rejection.json").write_text(json.dumps(log, indent=2) + "\n")
            raise ValueError(f"Apple rejected notarization request {request_id}; see notary diagnostics")
        if result.returncode and not any(word in result.stderr.lower() for word in ("network", "connection", "timed out", "temporarily", "http 5")):
            raise RuntimeError(f"Notary request lookup failed for {request_id}")
        time.sleep(15)
    else:
        raise RuntimeError(f"Notarization wait exceeded 20 minutes; resume request {request_id}")
    run("sh", "Scripts/stapler-staple.sh", str(artifact))
    if artifact.is_dir():
        run("spctl", "--assess", "--type", "execute", "--verbose=2", str(artifact))
    else:
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", str(artifact))
        state["accepted_sha256"] = digest(artifact)
        state_file.write_text(json.dumps(state, indent=2) + "\n")
    print(f"Notarized and assessed: {artifact}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate", "prepare", "auto", "manifest", "verify-manifest", "monotonic", "publish", "notarize"))
    parser.add_argument("values", nargs="*")
    args = parser.parse_args()
    os.chdir(ROOT)
    if args.command == "validate":
        print(validate(*args.values))
    elif args.command == "prepare":
        prepare(args.values[0] if args.values else "patch")
    elif args.command == "auto":
        auto()
    elif args.command == "manifest":
        create_manifest(args.values[0], args.values[1], args.values[2:])
    elif args.command == "verify-manifest":
        verify_manifest(*args.values)
    elif args.command == "monotonic":
        monotonic(*args.values)
    elif args.command == "publish":
        publish(*args.values)
    elif args.command == "notarize":
        notarize(*args.values)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"Release refused: {error}", file=sys.stderr)
        sys.exit(1)
