#!/usr/bin/env python3
"""Regression tests for required-job outcomes, Pages checks, and input budgets."""
import importlib.util
import io
import json
import pathlib
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("ci_summary", ROOT / "Scripts/ci-summary.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class QueueCompatibilityTests(unittest.TestCase):
    VALID = "concurrency:\n  group: production\n  cancel-in-progress: false\n  queue: max\njobs:\n  one: {}\n"

    def test_only_documented_queue_extension_is_normalized(self):
        normalized, used = ci.normalize_queue_extension(self.VALID)
        self.assertTrue(used)
        self.assertEqual(normalized.count("\n"), self.VALID.count("\n"))
        self.assertNotIn("queue:", normalized)
        self.assertIn("cancel-in-progress: false", normalized)
        self.assertEqual(ci.normalize_queue_extension("jobs: {}\n"), ("jobs: {}\n", False))

    def test_other_schema_errors_still_fail_actionlint(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            workflows = root / ".github/workflows"
            workflows.mkdir(parents=True)
            (workflows / "invalid.yml").write_text(
                "name: Negative control\non: push\nconcurrency:\n  group: control\n  cancel-in-progress: false\n  queue: max\n"
                "jobs:\n  check:\n    runs-on: ubuntu-24.04\n    bogus-step-key: true\n    steps:\n      - run: echo hello\n")
            with patch.object(ci.sys, "stdout", io.StringIO()), patch.object(ci.sys, "stderr", io.StringIO()), self.assertRaises(ValueError):
                ci.lint_workflows(root)

    def test_queue_errors_and_nesting_are_not_hidden(self):
        for invalid in (
            self.VALID.replace("false", "true"),
            self.VALID.replace("queue: max", "queue: maximum"),
            self.VALID.replace("queue: max", "queue: max\n  queue: max"),
            self.VALID.replace("  queue: max", "    queue: max"),
            "jobs:\n  queue: max\n",
            self.VALID.replace("concurrency:", "env:"),
            self.VALID.replace("  cancel-in-progress: false\n", ""),
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                ci.normalize_queue_extension(invalid)


class ResultGateTests(unittest.TestCase):
    def test_only_complete_success_is_accepted(self):
        ci.require_ci_success({"portable-checks": {"result": "success"}, "build-and-test": {"result": "success"}})
        for result in ("failure", "cancelled", "skipped", None):
            with self.subTest(result=result), self.assertRaises(ValueError):
                ci.require_ci_success({"portable-checks": {"result": "success"}, "build-and-test": {"result": result}})

    def test_missing_and_unexpected_jobs_fail_closed(self):
        for data in ({}, {"portable-checks": {"result": "success"}}, {"unexpected": {"result": "success"}}):
            with self.subTest(data=data), self.assertRaises(ValueError):
                ci.require_ci_success(data)


class SoakBudgetTests(unittest.TestCase):
    def test_supported_durations(self):
        for seconds in ("60", "600", "1800"):
            self.assertEqual(ci.soak_duration(seconds), int(seconds))

    def test_invalid_and_over_budget_durations(self):
        for seconds in ("", "0", "59", "-1", "1.5", "nan", "inf", "1801", "14400", "600; true"):
            with self.subTest(seconds=seconds), self.assertRaises(ValueError):
                ci.soak_duration(seconds)


class PagesContractTests(unittest.TestCase):
    def setUp(self):
        self.feed = (ROOT / "site/updates/appcast.xml").read_bytes()
        self.version, _ = ci.appcast_version(self.feed)

    def test_real_feed_and_callback(self):
        self.assertEqual(ci.validate_site(ROOT / "site")[0], self.version)
        self.assertEqual(ci.appcast_version(self.feed, "v" + self.version)[0], self.version)

    def test_stale_version_rejected(self):
        with self.assertRaises(ValueError):
            ci.appcast_version(self.feed, "9999.0.0")

    def test_invalid_feed_and_untrusted_asset_urls_rejected(self):
        for invalid in (b"<rss/>", self.feed.replace(b"https://github.com/", b"http://github.com/"), self.feed.replace(b"Hisingen.app.zip", b"other.zip"), self.feed.replace(b"sparkle:edSignature", b"unsigned")):
            with self.subTest(invalid=invalid[:40]), self.assertRaises((ValueError, ci.ET.ParseError)):
                ci.appcast_version(invalid)

    def test_missing_callback_forwarding_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "updates").mkdir()
            (root / "updates/appcast.xml").write_bytes(self.feed)
            (root / "oauth-callback.html").write_text("<html>callback omitted</html>")
            with self.assertRaises(ValueError):
                ci.validate_site(root)


class ReportTests(unittest.TestCase):
    def test_application_coverage_excludes_dependency_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "input.json"
            source.write_text(json.dumps({"data": [{"files": [
                {"filename": "/repo/Sources/Hisingen/A.swift", "summary": {"lines": {"count": 10, "covered": 7}}},
                {"filename": "/repo/.build/checkouts/nio/Sources/NIO/A.swift", "summary": {"lines": {"count": 1000, "covered": 999}}},
            ]}]}))
            ci.record_coverage(source, root)
            summary = json.loads((root / "coverage-summary.json").read_text())
            self.assertEqual(summary, {"files": 1, "lines": 10, "covered_lines": 7, "percent": 70.0})
            source.write_text('{"data": []}')
            with self.assertRaises(ValueError):
                ci.record_coverage(source, root)

    def test_summary_contains_counts_and_actual_toolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "summary.json").write_text(json.dumps({"executed": 12, "skipped": 2, "failed": 0, "exit_code": 0}))
            (root / "selection.json").write_text(json.dumps({"discovered": 20, "selected": 14}))
            (root / "toolchain.json").write_text(json.dumps({"swift": "Swift test fixture", "sdk": "26.2"}))
            target = root / "summary.md"
            with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(target)}), patch.object(ci.subprocess, "run", return_value=SimpleNamespace(stdout="abc123")):
                ci.summary(root)
            text = target.read_text()
            for required in ("executed: 12", "skipped: 2", "failed: 0", "selected: 14", "Swift test fixture", "26.2"):
                self.assertIn(required, text)


class DeploymentTests(unittest.TestCase):
    def test_exact_artifact_is_required_before_deployment_succeeds(self):
        directory = ROOT / "site"
        _, assets = ci.validate_site(directory)
        def body(url):
            relative = "updates/appcast.xml" if url.endswith("appcast.xml") else "oauth-callback.html"
            return (directory / relative).read_bytes()
        response = SimpleNamespace(status=200, headers={"Content-Length": str(assets[0][1])})
        class Context:
            def __enter__(self):
                return response
            def __exit__(self, *args):
                return None
        with patch.object(ci, "request_bytes", side_effect=body), patch.object(ci.urllib.request, "urlopen", return_value=Context()):
            ci.verify_deployed("https://example.test/Hisingen/", directory)
        with patch.object(ci, "request_bytes", return_value=b"stale artifact"), patch.object(ci.time, "sleep"), self.assertRaises(ValueError):
            ci.verify_deployed("https://example.test/Hisingen/", directory)

    def test_plain_http_deployment_is_refused(self):
        with self.assertRaises(ValueError):
            ci.verify_deployed("http://example.test/", ROOT / "site")


class CommittedSnapshotTests(unittest.TestCase):
    def test_original_history_is_preserved_and_dirty_changes_are_excluded(self):
        with tempfile.TemporaryDirectory(prefix="snapshot contract ") as directory:
            root = pathlib.Path(directory)
            repository = root / "repository"
            repository.mkdir()
            scripts = repository / "Scripts"
            scripts.mkdir()
            (scripts / "ci-local.sh").write_text((ROOT / "Scripts/ci-local.sh").read_text())
            (scripts / "ci-checks.sh").write_text(
                "#!/bin/sh\nset -eu\ngit show --format= --check HEAD\n"
                'test "$(git rev-parse HEAD)" = "$EXPECTED_SNAPSHOT_SHA"\n'
                'test "$(git rev-list --count HEAD)" = 2\n'
                'test "$(cat current.txt)" = committed\n'
                "printf '%s\\n' \"$1\" >> \"$SNAPSHOT_RESULT\"\n")
            (repository / "historical.txt").write_text("historical trailing spaces  \n")
            def git(*arguments):
                return subprocess.check_output(["git", "-C", str(repository), "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=CI fixture", "-c", "user.email=ci@example.invalid", *arguments], text=True).strip()
            git("init", "-q")
            git("add", ".")
            git("commit", "-qm", "Historical whitespace")
            (repository / "current.txt").write_text("committed\n")
            git("add", ".")
            git("commit", "-qm", "Clean current patch")
            revision = git("rev-parse", "HEAD")
            (repository / "current.txt").write_text("dirty change excluded\n")
            result_file = root / "observed-phases"
            environment = {**os.environ, "EXPECTED_SNAPSHOT_SHA": revision, "SNAPSHOT_RESULT": str(result_file), "TMPDIR": str(root)}
            process = subprocess.run(["sh", str(scripts / "ci-local.sh"), "--committed"], capture_output=True, text=True, env=environment)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            self.assertEqual(result_file.read_text().splitlines(), ["portable", "macos"])
            self.assertEqual(git("rev-parse", "HEAD"), revision)
            self.assertEqual((repository / "current.txt").read_text(), "dirty change excluded\n")
            (repository / "current.txt").write_text("new trailing whitespace  \n")
            git("add", "current.txt")
            git("commit", "-qm", "Invalid current patch")
            environment["EXPECTED_SNAPSHOT_SHA"] = git("rev-parse", "HEAD")
            rejected = subprocess.run(["sh", str(scripts / "ci-local.sh"), "--committed"], capture_output=True, text=True, env=environment)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("trailing whitespace", rejected.stdout + rejected.stderr)


class ToolchainPinTests(unittest.TestCase):
    def test_explicit_version_selects_only_matching_full_xcode(self):
        with tempfile.TemporaryDirectory(prefix="xcode contract ") as directory:
            developer = pathlib.Path(directory) / "Developer"
            binary = developer / "usr/bin/xcodebuild"
            binary.parent.mkdir(parents=True)
            binary.write_text("#!/bin/sh\nprintf 'Xcode 999.42\\nBuild version fixture\\n'\n")
            binary.chmod(0o755)
            github_env = pathlib.Path(directory) / "github-env"
            environment = {**os.environ, "DEVELOPER_DIR": str(developer), "XCODE_VERSION": "999.42", "GITHUB_ENV": str(github_env)}
            result = subprocess.run(["sh", str(ROOT / "Scripts/select-xcode.sh")], capture_output=True, text=True, env=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(str(developer), result.stdout)
            self.assertEqual(github_env.read_text(), f"DEVELOPER_DIR={developer}\n")
            environment["XCODE_VERSION"] = "999.43"
            refused = subprocess.run(["sh", str(ROOT / "Scripts/select-xcode.sh")], capture_output=True, text=True, env=environment)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("Full Xcode 999.43 is required", refused.stderr)


class WorkflowWiringTests(unittest.TestCase):
    def test_ci_uses_shared_phases_and_pinned_versions(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        settings = json.loads((ROOT / ".github/ci-toolchain.json").read_text())
        for version in (settings["node"], settings["python"], settings["go"]):
            self.assertIn(version, workflow)
        self.assertIn("sh Scripts/ci-checks.sh portable", workflow)
        self.assertIn("sh Scripts/ci-checks.sh macos", workflow)
        self.assertIn("if: always()\n    needs: [portable-checks, build-and-test]", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertIn("macos-15", workflow)
        self.assertIn("macos-26-intel", workflow)

    def test_live_phases_do_not_run_in_parallel_and_validate_duration(self):
        workflow = (ROOT / ".github/workflows/live-integration.yml").read_text()
        self.assertIn("python3 Scripts/ci-summary.py soak", workflow)
        self.assertNotIn("LivePolestarReadOnlyIntegrationTests|LivePolestarStreamSoakTests", workflow)
        self.assertIn("--filter LivePolestarReadOnlyIntegrationTests --no-parallel", workflow)
        self.assertIn("--filter LivePolestarStreamSoakTests --no-parallel", workflow)

    def test_reusable_pages_waits_for_production_verification(self):
        workflow = (ROOT / ".github/workflows/pages.yml").read_text()
        self.assertIn("workflow_call:", workflow)
        self.assertIn("release_artifact:", workflow)
        self.assertIn("python3 Scripts/ci-summary.py deployed", workflow)
        self.assertIn("'pages-production'", workflow)
        self.assertIn("gh release download", workflow)


if __name__ == "__main__":
    result = unittest.main(exit=False)
    if result.result.wasSuccessful():
        print("ci-contract-regressions-passed")
    else:
        raise SystemExit(1)
