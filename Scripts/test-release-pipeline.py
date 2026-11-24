#!/usr/bin/env python3
"""Behavioral release regressions using disposable Git repositories and API fakes."""
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
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


class CiProofTests(unittest.TestCase):
    def runs(self, **overrides):
        names = {name: "success" for name in release.CI_PROOF_CHECKS}
        names.update(overrides)
        return [{"name": name, "conclusion": result, "completed_at": "2026-11-22T10:00:00Z", "app": release.GITHUB_ACTIONS_APP_ID} for name, result in names.items()]

    def test_every_required_check_green_is_proof(self):
        self.assertTrue(release.ci_proof_from(self.runs()))

    def test_a_missing_failed_or_skipped_check_is_not_proof(self):
        for name in release.CI_PROOF_CHECKS:
            for result in ("failure", "cancelled", "skipped", None):
                with self.subTest(name=name, result=result):
                    self.assertFalse(release.ci_proof_from(self.runs(**{name: result})))
            self.assertFalse(release.ci_proof_from([run for run in self.runs() if run["name"] != name]))

    def test_checks_from_other_apps_do_not_count(self):
        self.assertFalse(release.ci_proof_from([{**run, "app": 1} for run in self.runs()]))

    def test_the_newest_attempt_decides(self):
        failed_then_fixed = self.runs() + [{"name": "package", "conclusion": "failure", "completed_at": "2026-11-22T09:00:00Z", "app": release.GITHUB_ACTIONS_APP_ID}]
        self.assertTrue(release.ci_proof_from(failed_then_fixed))
        fixed_then_broken = self.runs() + [{"name": "package", "conclusion": "failure", "completed_at": "2026-11-22T11:00:00Z", "app": release.GITHUB_ACTIONS_APP_ID}]
        self.assertFalse(release.ci_proof_from(fixed_then_broken))

    def test_only_a_full_commit_sha_is_accepted(self):
        for value in ("", "main", "abc123", "g" * 40, "a" * 41):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.ci_proof(value)


class PublicationTests(unittest.TestCase):
    def test_release_publishes_only_installer_archive_and_checksums(self):
        self.assertEqual(release.PUBLIC_ASSETS, ("Hisingen.dmg", "Hisingen.app.zip", "SHA256SUMS"))

    def test_draft_drops_stale_assets_and_uploads_only_public_files(self):
        with repository():
            names = ("a.zip", "SUMS")
            for name in (*names, "extra.json"):
                Path(name).write_bytes(name.encode())
            release.create_manifest("release-manifest.json", "v1.1.0", [*names, "extra.json"])
            calls = []
            original_run = release.run

            def api(*args, **kwargs):
                calls.append(args)
                if args[:3] == ("gh", "release", "view"):
                    return result('{"isDraft":true,"assets":[{"name":"a.zip"},{"name":"Hisingen.zip"},{"name":"release-manifest.json"}]}')
                if args[:3] == ("gh", "release", "download"):
                    out = Path(args[args.index("--dir") + 1])
                    for name in names:
                        (out / name).write_bytes(Path(name).read_bytes())
                    return result()
                if args[:2] == ("gh", "release"):
                    return result()
                return original_run(*args, **kwargs)

            with patch.object(release, "PUBLIC_ASSETS", names), patch.object(release, "run", side_effect=api), patch.object(release, "monotonic"):
                release.publish("v1.1.0")
            deleted = {c[4] for c in calls if c[:3] == ("gh", "release", "delete-asset")}
            self.assertEqual(deleted, {"Hisingen.zip", "release-manifest.json"})
            upload = next(c for c in calls if c[:3] == ("gh", "release", "upload"))
            self.assertEqual(set(upload[4:]) - {"--clobber"}, set(names))

    def test_draft_with_an_unexpected_downloaded_asset_is_not_published(self):
        with repository():
            Path("artifact.zip").write_bytes(b"verified")
            release.create_manifest("release-manifest.json", "v1.1.0", ["artifact.zip"])
            calls = []
            original_run = release.run

            def api(*args, **kwargs):
                calls.append(args)
                if args[:3] == ("gh", "release", "view"):
                    return result('{"isDraft":true,"assets":[]}')
                if args[:3] == ("gh", "release", "download"):
                    out = Path(args[args.index("--dir") + 1])
                    (out / "artifact.zip").write_bytes(b"verified")
                    (out / "Hisingen.zip").write_bytes(b"stray")
                    return result()
                if args[:2] == ("gh", "release"):
                    return result()
                return original_run(*args, **kwargs)

            with patch.object(release, "PUBLIC_ASSETS", ("artifact.zip",)), patch.object(release, "run", side_effect=api), patch.object(release, "monotonic"):
                with self.assertRaisesRegex(ValueError, "unexpected assets"):
                    release.publish("v1.1.0")
            self.assertFalse(any(c[:3] == ("gh", "release", "edit") for c in calls))

    def test_manifest_without_a_public_asset_cannot_publish(self):
        with repository():
            Path("artifact.zip").write_bytes(b"verified")
            release.create_manifest("release-manifest.json", "v1.1.0", ["artifact.zip"])
            with patch.object(release, "monotonic"), self.assertRaisesRegex(ValueError, "missing public assets"):
                release.publish("v1.1.0")

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
                    (out / "artifact.zip").write_bytes(Path("artifact.zip").read_bytes())
                    return result()
                return original_run(*args, **kwargs)

            with patch.object(release, "PUBLIC_ASSETS", ("artifact.zip",)), patch.object(release, "run", side_effect=api), patch.object(release, "monotonic"):
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

            with patch.object(release, "PUBLIC_ASSETS", ("artifact.zip",)), patch.object(release, "run", side_effect=api), patch.object(release, "monotonic"):
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

    def prepared_release(self, folder):
        """A repository whose release branch is prepared and pushed, with the checkout back on main."""
        remote = folder / "remote.git"
        subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
        subprocess.run(["git", "remote", "add", "origin", str(remote)], check=True)
        subprocess.run(["git", "config", "core.excludesFile", "/dev/null"], check=True)
        Path(".git/info/exclude").write_text("remote.git/\n")
        main = subprocess.run(["git", "branch", "--show-current"], capture_output=True, text=True, check=True).stdout.strip()
        original_run = release.run

        def fake(*args, **kwargs):
            if args[0] == "gh":
                return result("[]" if args[1:3] == ("pr", "list") else "")
            return original_run(*args, **kwargs)

        with patch.object(release, "run", side_effect=fake):
            release.prepare("patch")
        subprocess.run(["git", "checkout", "-q", main], check=True)
        return main, fake, original_run

    def advance_main(self, name, text):
        Path(name).write_text(text)
        subprocess.run(["git", "add", name], check=True)
        subprocess.run(["git", "commit", "-qm", f"change {name}"], check=True)
        subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"], check=True)

    def test_a_release_branch_that_main_has_moved_past_is_brought_up_to_date(self):
        with repository() as folder:
            main, fake, original_run = self.prepared_release(folder)
            self.advance_main("Sources/App.swift", "struct App { var later = true }\n")
            with patch.object(release, "run", side_effect=fake):
                release.prepare("patch")
            remote = folder / "remote.git"
            contained = subprocess.run(["git", "--git-dir", str(remote), "merge-base", "--is-ancestor", original_run("git", "rev-parse", "origin/main").stdout.strip(), "refs/heads/release/v1.1.1"])
            self.assertEqual(contained.returncode, 0, "the release branch still lacks the newest main commit")
            plist = subprocess.run(["git", "--git-dir", str(remote), "show", "refs/heads/release/v1.1.1:Resources/Info.plist"], capture_output=True, check=True).stdout
            self.assertEqual(plistlib.loads(plist)["CFBundleShortVersionString"], "1.1.1")

    def test_a_current_release_branch_is_left_alone(self):
        with repository() as folder:
            main, fake, original_run = self.prepared_release(folder)
            before = original_run("git", "ls-remote", "origin", "refs/heads/release/v1.1.1").stdout
            with patch.object(release, "run", side_effect=fake):
                release.prepare("patch")
            self.assertEqual(original_run("git", "ls-remote", "origin", "refs/heads/release/v1.1.1").stdout, before)

    def test_a_release_branch_that_conflicts_with_main_is_reported_and_not_pushed(self):
        with repository() as folder:
            main, fake, original_run = self.prepared_release(folder)
            before = original_run("git", "ls-remote", "origin", "refs/heads/release/v1.1.1").stdout
            self.advance_main("CHANGELOG.md", "# Changelog\n\n## [1.1.1] - 2026-11-01\n\n- Written on main\n")
            with patch.object(release, "run", side_effect=fake):
                with self.assertRaises(ValueError):
                    release.prepare("patch")
            self.assertEqual(original_run("git", "ls-remote", "origin", "refs/heads/release/v1.1.1").stdout, before)
            self.assertEqual(original_run("git", "status", "--porcelain").stdout, "", "the failed merge was not aborted")

    def test_an_updated_release_consumes_new_fragments_once(self):
        with repository() as folder:
            Path("changelog.d").mkdir()
            first = "- **First fix.** Prepared with the release.\n"
            later = "- **Second fix.** Merged after preparation.\n"
            self.advance_main("changelog.d/first.fixed.md", first)
            main, fake, original_run = self.prepared_release(folder)
            self.advance_main("changelog.d/second.fixed.md", later)
            with patch.object(release, "run", side_effect=fake):
                release.prepare("patch")
            original_run("git", "checkout", "-q", main)
            self.advance_main("Sources/App.swift", "struct App { var later = true }\n")
            with patch.object(release, "run", side_effect=fake):
                release.prepare("patch")

            remote = folder / "remote.git"
            branch = "refs/heads/release/v1.1.1"
            notes = original_run("git", "--git-dir", str(remote), "show", f"{branch}:CHANGELOG.md").stdout
            section = notes.split("## [1.1.1]", 1)[1].split("## [1.1.0]", 1)[0]
            self.assertEqual(section.count(first), 1)
            self.assertEqual(section.count(later), 1)
            files = original_run("git", "--git-dir", str(remote), "ls-tree", "-r", branch, "--", "changelog.d").stdout
            self.assertEqual(files, "")
            self.assertEqual(original_run("git", "status", "--porcelain").stdout, "")

    def test_an_invalid_new_fragment_leaves_the_release_branch_intact(self):
        with repository() as folder:
            _, fake, original_run = self.prepared_release(folder)
            before = original_run("git", "ls-remote", "origin", "refs/heads/release/v1.1.1").stdout
            Path("changelog.d").mkdir()
            self.advance_main("changelog.d/broken.fixed.md", "missing the bullet\n")
            with patch.object(release, "run", side_effect=fake):
                with self.assertRaisesRegex(ValueError, "broken.fixed.md"):
                    release.prepare("patch")
            self.assertEqual(original_run("git", "ls-remote", "origin", "refs/heads/release/v1.1.1").stdout, before)
            self.assertEqual(original_run("git", "status", "--porcelain").stdout, "")

    def test_preparation_turns_changelog_fragments_into_the_new_sections_and_removes_them(self):
        with repository() as folder:
            remote = folder / "remote.git"
            subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
            subprocess.run(["git", "remote", "add", "origin", str(remote)], check=True)
            Path("changelog.d").mkdir()
            Path("changelog.d/README.md").write_text("Fragments live here.\n")
            Path("changelog.d/a-fix.fixed.md").write_text("- **A thing was fixed.** It no longer breaks.\n")
            Path("changelog.d/new-thing.added.md").write_text("- **A thing was added.** It does something.\n")
            subprocess.run(["git", "add", "."], check=True)
            subprocess.run(["git", "commit", "-qm", "add fragments"], check=True)
            subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"], check=True)
            original_run = release.run

            def fake(*args, **kwargs):
                if args[0] == "gh":
                    return result("[]" if args[1:3] == ("pr", "list") else "")
                return original_run(*args, **kwargs)

            subprocess.run(["git", "config", "core.excludesFile", "/dev/null"], check=True)
            Path(".git/info/exclude").write_text("remote.git/\n")
            with patch.object(release, "run", side_effect=fake):
                release.prepare("patch")
            text = original_run("git", "show", "HEAD:CHANGELOG.md").stdout
            self.assertLess(text.index("## [1.1.1]"), text.index("## [1.1.0]"))
            self.assertLess(text.index("### Added"), text.index("### Fixed"))
            self.assertIn("- **A thing was added.** It does something.", text)
            self.assertNotIn("add fragments", text, "fragments replace the commit-subject fallback")
            tracked = original_run("git", "ls-files", "changelog.d").stdout.split()
            self.assertEqual(tracked, ["changelog.d/README.md"])

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

    def test_skip_release_commit_does_not_tag_or_prepare(self):
        replies = [result("abc\n"), result("abc\trefs/heads/main\n"), result(), result("maintenance [skip release]\n")]
        with (
            patch.dict(os.environ, {"CI_HEAD_SHA": "abc"}),
            patch.object(release, "run", side_effect=replies) as commands,
            patch.object(release, "prepare") as prepare,
        ):
            release.auto()
        prepare.assert_not_called()
        self.assertEqual(commands.call_count, len(replies))


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


class WorkflowGatingTests(unittest.TestCase):
    """A skipped job must not silently skip everything downstream of it.

    A job without its own `if` runs only when every job behind it, directly or not, succeeded.
    `test` is skipped whenever CI already proved the commit, so the 3.0.2 release built for 46
    minutes and then skipped notarize, publish and the distribution channels. Any job with a
    conditional ancestor has to state its own condition, with `!cancelled()` or `always()`.
    """

    @staticmethod
    def parse_jobs(text):
        jobs, current, in_jobs, listing = {}, None, False, False
        for line in text.splitlines():
            if line.startswith("jobs:"):
                in_jobs = True
                continue
            if not in_jobs:
                continue
            if re.match(r"^\S", line) and not line.startswith("#"):
                break
            name = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
            if name:
                current = name.group(1)
                jobs[current] = {"needs": [], "if": None}
                continue
            if current is None:
                continue
            needs = re.match(r"^    needs:\s*(.*)$", line)
            if needs:
                jobs[current]["needs"] += [n.strip() for n in needs.group(1).strip("[]").split(",") if n.strip()]
                listing = not needs.group(1).strip()
                continue
            item = re.match(r"^      - ([A-Za-z0-9_-]+)\s*$", line)
            if listing and item:
                jobs[current]["needs"].append(item.group(1))
                continue
            if re.match(r"^    \S", line):
                listing = False
            condition = re.match(r"^    if:\s*(.+)$", line)
            if condition:
                jobs[current]["if"] = condition.group(1)
        return jobs

    @classmethod
    def ungated_jobs(cls, text):
        jobs = cls.parse_jobs(text)

        def ancestors(name, seen=None):
            seen = set() if seen is None else seen
            for parent in jobs[name]["needs"]:
                if parent in jobs and parent not in seen:
                    seen.add(parent)
                    ancestors(parent, seen)
            return seen

        problems = []
        for name, job in jobs.items():
            if not any(jobs[parent]["if"] for parent in ancestors(name)):
                continue
            condition = job["if"] or ""
            if "!cancelled()" not in condition and "always()" not in condition:
                problems.append(name)
        return problems

    def test_release_jobs_behind_a_conditional_job_state_their_own_condition(self):
        text = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("notarize", self.parse_jobs(text), "release.yml jobs were not parsed")
        self.assertEqual(self.ungated_jobs(text), [])

    def test_the_check_catches_the_shape_that_skipped_the_3_0_2_release(self):
        workflow = (
            "jobs:\n"
            "  validate:\n    runs-on: ubuntu\n"
            "  test:\n    needs: validate\n    if: needs.validate.outputs.proven != 'true'\n"
            "  build:\n    needs: [validate, test]\n    if: ${{ !cancelled() }}\n"
            "  notarize:\n    needs: [validate, build]\n"
            "  publish:\n    needs: notarize\n    if: ${{ !cancelled() && needs.notarize.result == 'success' }}\n"
        )
        self.assertEqual(self.ungated_jobs(workflow), ["notarize"])


if __name__ == "__main__":
    program = unittest.main(exit=False)
    if not program.result.wasSuccessful():
        raise SystemExit(1)
    print("release-regressions-passed")
