#!/usr/bin/env python3
"""Validate CI result contracts and the two production Pages entry points."""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
RELEASE_PREFIX = "https://github.com/NicolasKheirallah/Hisingen/releases/download/"


def normalize_queue_extension(text):
    lines = text.splitlines(keepends=True)
    queue_lines = [index for index, line in enumerate(lines) if re.match(r"^\s*queue\s*:", line)]
    if not queue_lines:
        return text, False
    if len(queue_lines) != 1:
        raise ValueError("Duplicate or multiple queue declarations are outside the workflow contract")
    index = queue_lines[0]
    if lines[index].strip() != "queue: max" or not lines[index].startswith("  queue:"):
        raise ValueError("Only canonical top-level concurrency queue: max is supported")
    roots = [number for number, line in enumerate(lines[:index + 1]) if re.match(r"^[^ #\s][^:]*:", line)]
    if not roots or lines[roots[-1]].strip() != "concurrency:":
        raise ValueError("queue must belong to the workflow's top-level concurrency stanza")
    end = next((number for number in range(index + 1, len(lines)) if re.match(r"^[^ #\s][^:]*:", lines[number])), len(lines))
    block = lines[roots[-1] + 1:end]
    cancellation = [line.strip() for line in block if line.lstrip().startswith("cancel-in-progress:")]
    if cancellation != ["cancel-in-progress: false"]:
        raise ValueError("Queued production workflows must use literal cancel-in-progress: false")
    if not any(re.match(r"^  group: .+", line) for line in block):
        raise ValueError("Queued workflows require a top-level concurrency group")
    lines[index] = "\n" if lines[index].endswith("\n") else ""
    return "".join(lines), True


def lint_workflows(root):
    root = pathlib.Path(root).resolve()
    # GitHub added queue after actionlint 1.7.12; validate its narrow contract before normalization.
    with tempfile.TemporaryDirectory(prefix="hisingen-actionlint-") as directory:
        project = pathlib.Path(directory)
        workflows = project / ".github/workflows"
        workflows.mkdir(parents=True)
        (project / ".git").mkdir()
        originals = sorted((root / ".github/workflows").glob("*.y*ml"))
        if not originals:
            raise ValueError("No GitHub workflows found")
        queue_used = False
        for source in originals:
            normalized, used = normalize_queue_extension(source.read_text())
            queue_used = queue_used or used
            (workflows / source.name).write_text(normalized)
        for name in ("actionlint.yaml", "actionlint.yml"):
            source = root / ".github" / name
            if source.is_file():
                shutil.copyfile(source, project / ".github" / name)
        result = subprocess.run(["actionlint", *[str(workflows / source.name) for source in originals]], cwd=root, capture_output=True, text=True)
        for output, stream in ((result.stdout, sys.stdout), (result.stderr, sys.stderr)):
            stream.write(output.replace(str(project), str(root)))
        if result.returncode:
            raise ValueError(f"Workflow lint failed with exit status {result.returncode}")
        if queue_used:
            print("GitHub queue:max validated; actionlint1.7.12 compatibility adapter")
        print("workflow-lint-passed")


def require_ci_success(results):
    if set(results) != {"portable-checks", "build-and-test"}:
        raise ValueError("The required CI result set changed or is incomplete")
    unsuccessful = {name: item.get("result") for name, item in results.items() if item.get("result") != "success"}
    if unsuccessful:
        raise ValueError(f"Required jobs did not succeed: {unsuccessful}")


def soak_duration(raw):
    if not re.fullmatch(r"[0-9]+", raw) or not 60 <= int(raw) <= 1800:
        raise ValueError("soak_seconds must be an integer between 60 and 1800; run longer soaks locally")
    return int(raw)


def appcast_version(data, expected_version=None):
    root = ET.fromstring(data)
    if root.tag != "rss":
        raise ValueError("Appcast must be an RSS document")
    items = root.findall("./channel/item")
    if not items:
        raise ValueError("Appcast contains no release items")
    item = items[0]
    version = item.findtext(f"{SPARKLE}shortVersionString")
    build = item.findtext(f"{SPARKLE}version")
    if not version or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not build or not build.isdecimal():
        raise ValueError("Appcast version/build is invalid")
    if expected_version and version != expected_version.removeprefix("v"):
        raise ValueError(f"Served version {version} differs from expected {expected_version}")
    enclosure = item.find("enclosure")
    notes = item.find(f"{SPARKLE}releaseNotesLink")
    prefix = f"{RELEASE_PREFIX}v{version}/"
    if enclosure is None or enclosure.get("url") != prefix + "Hisingen.app.zip":
        raise ValueError("Appcast archive is not the expected HTTPS release asset")
    if not enclosure.get("length", "").isdecimal() or int(enclosure.get("length")) <= 0:
        raise ValueError("Appcast archive length is invalid")
    if notes is None or notes.text != prefix + "Hisingen.app.md":
        raise ValueError("Appcast notes are not the expected HTTPS release asset")
    for element in (enclosure, notes):
        try:
            signature = base64.b64decode(element.get(f"{SPARKLE}edSignature", ""), validate=True)
        except ValueError as error:
            raise ValueError("Malformed asset signature") from error
        if len(signature) != 64:
            raise ValueError("Malformed asset signature")
    return version, [(enclosure.get("url"), int(enclosure.get("length"))), (notes.text, None)]


def validate_site(directory, expected_version=None):
    directory = pathlib.Path(directory)
    callback = (directory / "oauth-callback.html").read_bytes()
    for required in (b'hisingen://oauth/volvo/callback', b'window.location.search', b'window.location.replace(target)'):
        if required not in callback:
            raise ValueError("OAuth callback no longer forwards the authorization result")
    feed = (directory / "updates/appcast.xml").read_bytes()
    return appcast_version(feed, expected_version)


def request_bytes(url):
    if urllib.parse.urlsplit(url).scheme != "https":
        raise ValueError("Production checks require HTTPS")
    request = urllib.request.Request(url, headers={"User-Agent": "Hisingen-CI", "Cache-Control": "no-cache"})
    with urllib.request.urlopen(request, timeout=20) as response:
        if urllib.parse.urlsplit(response.url).scheme != "https":
            raise ValueError("Production endpoint redirected to non-HTTPS URL")
        return response.read()


def verify_deployed(base_url, directory, expected_version=None):
    if urllib.parse.urlsplit(base_url).scheme != "https":
        raise ValueError("Pages deployment URL must use HTTPS")
    version, assets = validate_site(directory, expected_version)
    last_error = None
    for attempt in range(8):
        try:
            for relative in ("oauth-callback.html", "updates/appcast.xml"):
                actual = request_bytes(base_url.rstrip("/") + "/" + relative)
                expected = (pathlib.Path(directory) / relative).read_bytes()
                if hashlib.sha256(actual).digest() != hashlib.sha256(expected).digest():
                    raise ValueError(f"Deployed {relative} differs from the deployment artifact")
            for url, length in assets:
                request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "Hisingen-CI"})
                with urllib.request.urlopen(request, timeout=20) as response:
                    if response.status != 200:
                        raise ValueError(f"Release asset unavailable: {url}")
                    if length and int(response.headers.get("Content-Length", "0")) != length:
                        raise ValueError("Published archive length differs from appcast")
            print(f"pages-production-verified: {version}")
            return
        except (ValueError, OSError, urllib.error.URLError) as error:
            last_error = error
            if attempt < 7:
                time.sleep(min(5 * (attempt + 1), 20))
    raise ValueError(f"Production deployment did not converge: {last_error}")


def collect_diagnostics(directory):
    output = pathlib.Path(directory)
    output.mkdir(parents=True, exist_ok=True)
    marker = output / "started"
    started = marker.stat().st_mtime if marker.exists() else time.time() - 3600
    reports = pathlib.Path.home() / "Library/Logs/DiagnosticReports"
    if not reports.is_dir():
        return
    candidates = [path for path in reports.iterdir()
                  if path.is_file() and path.suffix in (".ips", ".crash")
                  and path.name.startswith(("Hisingen", "swift-frontend"))
                  and path.stat().st_mtime >= started and path.stat().st_size <= 2_000_000]
    for path in sorted(candidates, key=lambda item: item.stat().st_mtime, reverse=True)[:10]:
        destination = output / "crashes"
        destination.mkdir(exist_ok=True)
        shutil.copy2(path, destination / path.name)


def record_toolchain(directory):
    tools = {
        "xcode": ["xcodebuild", "-version"],
        "swift": ["swift", "--version"],
        "sdk": ["xcrun", "--sdk", "macosx", "--show-sdk-version"],
    }
    report = {name: subprocess.check_output(command, text=True).strip() for name, command in tools.items()}
    (pathlib.Path(directory) / "toolchain.json").write_text(json.dumps(report, indent=2) + "\n")


def record_coverage(source, directory):
    data = json.loads(pathlib.Path(source).read_text())
    files = [file for record in data.get("data", []) for file in record.get("files", [])
             if "/Sources/Hisingen/" in file.get("filename", "")]
    if not files:
        raise ValueError("Coverage export contains no Hisingen application sources")
    count = sum(file["summary"]["lines"]["count"] for file in files)
    covered = sum(file["summary"]["lines"]["covered"] for file in files)
    if count <= 0 or not 0 <= covered <= count:
        raise ValueError("Coverage export has invalid application line totals")
    output = pathlib.Path(directory)
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, output / "coverage.json")
    report = {"files": len(files), "lines": count, "covered_lines": covered, "percent": round(100 * covered / count, 2)}
    (output / "coverage-summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Application line coverage: {covered}/{count} ({report['percent']}%)")


def summary(directory):
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if not target:
        return
    revision = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    lines = ["### CI execution", f"Commit: `{revision}`", f"Runner: `{os.environ.get('RUNNER_OS', 'local')}` / `{os.environ.get('RUNNER_ARCH', 'unknown')}`", f"Developer directory: `{os.environ.get('DEVELOPER_DIR', 'unset')}`", "", "Test reports, compiler logs, and selected diagnostics are attached to this run."]
    root = pathlib.Path(directory)
    for name in ("toolchain.json", "coverage-summary.json"):
        path = root / name
        if path.is_file():
            data = json.loads(path.read_text())
            for key, value in data.items():
                lines.append(f"{key}: `{str(value).replace(chr(10), '; ')}`")
    reports = sorted(path for path in root.rglob("*.json") if path.name in ("selection.json", "summary.json")) if root.is_dir() else []
    for report in reports[:20]:
        try:
            data = json.loads(report.read_text())
        except (ValueError, OSError):
            continue
        counts = ", ".join(f"{key}: {data[key]}" for key in ("discovered", "selected", "executed", "skipped", "failed", "exit_code") if key in data)
        lines.append(f"`{report.name}`: {counts}")
    with open(target, "a", encoding="utf-8") as stream:
        stream.write("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("gate")
    lint = commands.add_parser("lint-workflows")
    lint.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parent.parent))
    diagnostics = commands.add_parser("diagnostics")
    diagnostics.add_argument("directory")
    toolchain = commands.add_parser("toolchain")
    toolchain.add_argument("directory")
    coverage = commands.add_parser("coverage")
    coverage.add_argument("source")
    coverage.add_argument("directory")
    soak = commands.add_parser("soak")
    soak.add_argument("seconds")
    site = commands.add_parser("site")
    site.add_argument("directory")
    site.add_argument("--expected-version")
    deployed = commands.add_parser("deployed")
    deployed.add_argument("base_url")
    deployed.add_argument("directory")
    deployed.add_argument("--expected-version")
    report = commands.add_parser("summary")
    report.add_argument("directory")
    args = parser.parse_args()
    if args.command == "lint-workflows":
        lint_workflows(args.root)
    elif args.command == "gate":
        require_ci_success(json.loads(os.environ.get("NEEDS_JSON", "{}")))
        print("ci-required-passed")
    elif args.command == "soak":
        print(f"soak-duration-validated: {soak_duration(args.seconds)}")
    elif args.command == "site":
        version, _ = validate_site(args.directory, args.expected_version)
        print(f"pages-source-validated: {version}")
    elif args.command == "deployed":
        verify_deployed(args.base_url, args.directory, args.expected_version)
    elif args.command == "toolchain":
        record_toolchain(args.directory)
    elif args.command == "coverage":
        record_coverage(args.source, args.directory)
    elif args.command == "diagnostics":
        collect_diagnostics(args.directory)
    elif args.command == "summary":
        summary(args.directory)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, ET.ParseError, OSError) as error:
        sys.exit(str(error))
