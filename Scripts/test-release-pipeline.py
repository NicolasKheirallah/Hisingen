#!/usr/bin/env python3
"""Behavioral release regressions using disposable Git repositories and API fakes."""
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("release_support", ROOT / "Scripts/release-support.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def result(stdout="", returncode=0, stderr=""):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


@contextmanager
def repository(version="1.1.0", build="2"):
    with tempfile.TemporaryDirectory() as temp:
        previous = Path.cwd()
        os.chdir(temp)
        try:
            subprocess.run(["git", "init", "-q"], check=True)
            subprocess.run(["git", "config", "user.name", "Release tests"], check=True)
            subprocess.run(["git", "config", "user.email", "tests@example.invalid"], check=True)
            Path("Resources").mkdir()
            Path("Sources").mkdir()
            Path("Sources/App.swift").write_text("struct App {}\n")
            Path("site/updates").mkdir(parents=True)
            Path("site/oauth-callback.html").write_text("<script>location.href='hisingen://oauth/volvo/callback'</script>\n")
            Path("site/updates/appcast.xml").write_text("<rss />\n")
            Path("Resources/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": version, "CFBundleVersion": build}))
            Path("CHANGELOG.md").write_text(f"# Changelog\n\n## [{version}] - 2026-10-31\n\n- Tested\n")
            subprocess.run(["git", "add", "."], check=True)
            subprocess.run(["git", "commit", "-qm", "test release"], check=True)
            subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"], check=True)
            subprocess.run(["git", "tag", "v" + version], check=True)
            yield Path(temp)
        finally:
            os.chdir(previous)


class VersionTests(unittest.TestCase):
    def test_manual_bump_is_preserved(self):
        self.assertEqual(release.next_version("v1.2.3", "2.0.0"), "2.0.0")

    def test_patch_minor_major(self):
        for bump, expected in [("patch", "1.2.4"), ("minor", "1.3.0"), ("major", "2.0.0")]:
            self.assertEqual(release.next_version("v1.2.3", "1.2.3", bump), expected)

    def test_decreasing_current_or_requested_version_is_rejected(self):
        for args in [("v2.0.0", "1.0.0", "patch"), ("v2.0.0", "2.0.0", "1.9.9"), ("v2.0.0", "2.0.0", "2.0.0")]:
            with self.assertRaises(ValueError):
                release.next_version(*args)

    def test_invalid_stable_versions(self):
        for value in ["01.2.3", "1.2", "1.2.3-beta", "1.2.3\n", "1.2.3;echo bad", "-1.2.3"]:
            with self.assertRaises(ValueError):
                release.semver(value)

    def test_build_number_must_increase(self):
        for build in ["0", "2", "01", "1.2"]:
            with self.assertRaises(ValueError):
                release.ensure_build_increases({"CFBundleVersion": build}, {"CFBundleVersion": "2"})
        release.ensure_build_increases({"CFBundleVersion": "3"}, {"CFBundleVersion": "2"})


class IdentityTests(unittest.TestCase):
    def test_tag_and_head_must_be_identical(self):
        with repository():
            release.validate("v1.1.0")
            Path("new-file").write_text("new source")
            subprocess.run(["git", "add", "."], check=True)
            subprocess.run(["git", "commit", "-qm", "different source"], check=True)
            subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"], check=True)
            with self.assertRaisesRegex(ValueError, "does not equal"):
                release.validate("v1.1.0")

    def test_tag_cannot_name_an_unrelated_main_history(self):
        with repository():
            subprocess.run(["git", "update-ref", "-d", "refs/remotes/origin/main"], check=True)
            with self.assertRaises(RuntimeError):
                release.validate("v1.1.0")

    def test_bad_changelog_cannot_publish(self):
        with repository():
            Path("CHANGELOG.md").write_text("# Changelog\n## [1.1.00]\n")
            subprocess.run(["git", "add", "CHANGELOG.md"], check=True)
            subprocess.run(["git", "commit", "-qm", "invalid changelog"], check=True)
            subprocess.run(["git", "tag", "-f", "v1.1.0"], check=True, stdout=subprocess.PIPE)
            subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"], check=True)
            with self.assertRaisesRegex(ValueError, "CHANGELOG"):
                release.validate("v1.1.0")

    def test_tracked_source_mutation_after_checkout_is_rejected(self):
        with repository():
            Path("Sources/App.swift").write_text("struct DifferentApp {}\n")
            with self.assertRaisesRegex(ValueError, "Tracked release build inputs"):
                release.validate("v1.1.0")
            subprocess.run(["git", "add", "Sources/App.swift"], check=True)
            with self.assertRaisesRegex(ValueError, "Tracked release build inputs"):
                release.validate("v1.1.0")

    def test_untracked_source_is_rejected_but_ignored_generated_inputs_are_allowed(self):
        with repository():
            Path("Sources/Unexpected.swift").write_text("struct Unexpected {}\n")
            with self.assertRaisesRegex(ValueError, "Untracked release build inputs"):
                release.validate("v1.1.0")
            Path(".git/info/exclude").write_text("Sources/Unexpected.swift\n")
            release.validate("v1.1.0")

    def test_generated_site_feed_does_not_invalidate_build_identity(self):
        with repository():
            Path("site/updates/appcast.xml").write_text("<rss>Generated final feed</rss>\n")
            release.validate("v1.1.0")

    def test_callback_source_cannot_change_with_the_generated_feed(self):
        with repository():
            Path("site/oauth-callback.html").write_text("<script>Unexpected callback</script>\n")
            with self.assertRaisesRegex(ValueError, "Tracked release build inputs"):
                release.validate("v1.1.0")

    def test_checkpoint_binds_source_and_bytes(self):
        with repository():
            Path("signed-app.zip").write_bytes(b"signed artifact")
            release.create_manifest("checkpoint.json", "v1.1.0", ["signed-app.zip"])
            release.verify_manifest("checkpoint.json", "v1.1.0")
            Path("signed-app.zip").write_bytes(b"changed artifact")
            with self.assertRaisesRegex(ValueError, "digest mismatch"):
                release.verify_manifest("checkpoint.json", "v1.1.0")

    def test_checkpoint_cannot_escape_directory(self):
        with repository():
            Path("signed-app.zip").write_bytes(b"signed artifact")
            release.create_manifest("checkpoint.json", "v1.1.0", ["signed-app.zip"])
            data = json.loads(Path("checkpoint.json").read_text())
            data["files"] = {"../secret": "bad"}
            Path("checkpoint.json").write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, "escapes"):
                release.verify_manifest("checkpoint.json", "v1.1.0")


class PublicationTests(unittest.TestCase):
    def test_older_completion_cannot_overwrite_newer_release(self):
        with patch.object(release, "published_versions", return_value=["v2.0.1", "v2.1.0"]):
            with self.assertRaisesRegex(ValueError, "rollback"):
                release.monotonic("v2.0.2")
            release.monotonic("v2.1.0")
            release.monotonic("v2.1.1")

    def test_immutable_retry_verifies_existing_assets_without_upload(self):
        with repository():
            Path("artifact.zip").write_bytes(b"verified")
            release.create_manifest("release-manifest.json", "v1.1.0", ["artifact.zip"])
            calls = []
            original_run = release.run

            def api(*args, **kwargs):
                calls.append(args)
                if args[:3] == ("gh", "release", "view"):
                    return result('{"isDraft":false}')
                if args[:3] == ("gh", "release", "download"):
                    out = Path(args[args.index("--dir") + 1])
                    for name in ["artifact.zip", "release-manifest.json"]:
                        (out / name).write_bytes(Path(name).read_bytes())
                    return result()
                return original_run(*args, **kwargs)

            with patch.object(release, "run", side_effect=api), patch.object(release, "monotonic"):
                release.publish("v1.1.0")
            self.assertFalse(any("upload" in c or "edit" in c for c in calls))

    def test_draft_is_not_published_if_download_hash_differs(self):
        with repository():
            Path("artifact.zip").write_bytes(b"verified")
            release.create_manifest("release-manifest.json", "v1.1.0", ["artifact.zip"])
            calls = []
            original_run = release.run

            def api(*args, **kwargs):
                calls.append(args)
                if args[:3] == ("gh", "release", "view"):
                    return result('{"isDraft":true}')
                if args[:3] == ("gh", "release", "upload"):
                    return result()
                if args[:3] == ("gh", "release", "download"):
                    out = Path(args[args.index("--dir") + 1])
                    (out / "artifact.zip").write_bytes(b"corrupt upload")
                    return result()
                return original_run(*args, **kwargs)

            with patch.object(release, "run", side_effect=api), patch.object(release, "monotonic"):
                with self.assertRaisesRegex(ValueError, "differs"):
                    release.publish("v1.1.0")
            self.assertFalse(any("edit" in c for c in calls))


class AutoRecoveryTests(unittest.TestCase):
    def test_preparation_pushes_only_a_release_branch(self):
        with repository() as folder:
            remote = folder / "remote.git"
            subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
            subprocess.run(["git", "remote", "add", "origin", str(remote)], check=True)
            calls = []
            original_run = release.run

            def fake(*args, **kwargs):
                if args[0] == "gh":
                    calls.append(args)
                    return result("[]" if args[1:3] == ("pr", "list") else "")
                return original_run(*args, **kwargs)

            # The disposable remote is local test infrastructure, not a source input.
            subprocess.run(["git", "config", "core.excludesFile", "/dev/null"], check=True)
            Path(".git/info/exclude").write_text("remote.git/\n")
            with patch.object(release, "run", side_effect=fake):
                release.prepare("patch")
            self.assertIn("release/v1.1.1", original_run("git", "ls-remote", "origin").stdout)
            self.assertNotIn("refs/heads/main", original_run("git", "ls-remote", "origin").stdout)
            self.assertEqual(original_run("git", "tag").stdout.strip(), "v1.1.0")
            self.assertIn(("gh", "workflow", "run", "ci.yml", "--ref", "release/v1.1.1"), calls)

    def test_tagged_commit_with_failed_dispatch_resumes(self):
        calls = []

        def fake(*args, **kwargs):
            calls.append(args)
            if args[:2] == ("git", "rev-parse"): return result("abc\n")
            if args[:2] == ("git", "ls-remote"): return result("abc\trefs/heads/main\n")
            if args[:2] == ("git", "status"): return result()
            if args[:2] == ("git", "log"): return result("release merge")
            if args[:3] == ("gh", "release", "view"): return result(returncode=1, stderr="release not found")
            return result()

        with patch.dict(os.environ, {"CI_HEAD_SHA": "abc"}), patch.object(release, "run", side_effect=fake), patch.object(release, "latest_tag", return_value="v1.1.0"), patch.object(release, "plist_at", return_value={"CFBundleShortVersionString": "1.1.0"}):
            release.auto()
        self.assertIn(("gh", "workflow", "run", "release.yml", "--ref", "v1.1.0", "-f", "tag=v1.1.0"), calls)
        self.assertFalse(any("push" in c for c in calls))

    def test_stale_ci_does_not_tag_or_prepare(self):
        calls = []

        def fake(*args, **kwargs):
            calls.append(args)
            return result("old\n" if args[:2] == ("git", "rev-parse") else "new\trefs/heads/main\n")

        with patch.dict(os.environ, {"CI_HEAD_SHA": "old"}), patch.object(release, "run", side_effect=fake):
            release.auto()
        self.assertFalse(any("push" in c or "tag" in c or "workflow" in c for c in calls))


class NotaryRecoveryTests(unittest.TestCase):
    def test_stapled_checkpoint_is_assessed_without_resubmission(self):
        with tempfile.TemporaryDirectory() as temp:
            previous = Path.cwd()
            os.chdir(temp)
            try:
                Path("app.dmg").write_bytes(b"stapled bytes")
                Path("state").mkdir()
                Path("state/app.dmg.json").write_text(json.dumps({"sha256": "pre-staple-digest", "accepted_sha256": release.digest("app.dmg"), "id": "accepted-id"}))
                with patch.dict(os.environ, {"NOTARY_STATE_DIR": "state"}), patch.object(release.subprocess, "run") as apple, patch.object(release, "run", return_value=result()) as commands:
                    release.notarize("app.dmg")
                apple.assert_not_called()
                self.assertIn(("sh", "Scripts/stapler-validate.sh", "app.dmg"), [call.args for call in commands.call_args_list])
            finally:
                os.chdir(previous)

    def test_known_request_is_waited_without_resubmission(self):
        with tempfile.TemporaryDirectory() as temp:
            previous = Path.cwd()
            os.chdir(temp)
            try:
                Path("app.dmg").write_bytes(b"same signed bytes")
                Path("state").mkdir()
                Path("state/app.dmg.json").write_text(json.dumps({"sha256": release.digest("app.dmg"), "id": "known-id"}))
                calls = []

                def apple(args, **kwargs):
                    calls.append(args)
                    return result('{"status":"Accepted","id":"known-id"}')

                with patch.dict(os.environ, {"NOTARY_STATE_DIR": "state"}), patch.object(release.subprocess, "run", side_effect=apple), patch.object(release, "run", return_value=result()):
                    release.notarize("app.dmg")
                self.assertEqual(calls[0][2:4], ["info", "known-id"])
                self.assertFalse(any("submit" in c for c in calls))
            finally:
                os.chdir(previous)

    def test_rejection_is_not_retried(self):
        with tempfile.TemporaryDirectory() as temp:
            previous = Path.cwd()
            os.chdir(temp)
            try:
                Path("app.dmg").write_bytes(b"signed bytes")
                calls = []

                def apple(args, **kwargs):
                    calls.append(args)
                    return result(json.dumps({"id": "request", "status": "Invalid" if args[2] == "info" else "Submitted"}))

                with patch.dict(os.environ, {"NOTARY_STATE_DIR": "state"}), patch.object(release.subprocess, "run", side_effect=apple), patch.object(release.time, "sleep") as sleep:
                    with self.assertRaisesRegex(ValueError, "rejected"):
                        release.notarize("app.dmg")
                self.assertEqual(len([c for c in calls if "submit" in c]), 1)
                sleep.assert_not_called()
            finally:
                os.chdir(previous)


class EntrypointTests(unittest.TestCase):
    def test_local_release_only_delegates_to_shared_preparation(self):
        with tempfile.TemporaryDirectory() as temp:
            tool = Path(temp) / "gh"
            log = Path(temp) / "calls"
            tool.write_text('#!/bin/sh\nprintf "%s\\n" "$*" > "$RELEASE_TEST_LOG"\n')
            tool.chmod(0o755)
            env = dict(os.environ, PATH=temp + os.pathsep + os.environ["PATH"], RELEASE_TEST_LOG=str(log))
            subprocess.run(["sh", str(ROOT / "Scripts/release.sh"), "minor"], env=env, check=True)
            self.assertEqual(log.read_text().strip(), "workflow run tag-release.yml --ref main -f bump=minor")


if __name__ == "__main__":
    program = unittest.main(exit=False)
    if not program.result.wasSuccessful():
        raise SystemExit(1)
    print("release-regressions-passed")
