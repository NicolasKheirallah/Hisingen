#!/usr/bin/env python3
"""Regression checks for localization safety, Git path parsing, packaging order and App Intents flag capture."""
import contextlib
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


localization = load_module("localization", "check-localization.py")
sync = load_module("sync", "check-sync.py")
notices = load_module("notices", "check-third-party-notices.py")


class ThirdPartyNoticeFixTests(unittest.TestCase):
    PINS = [
        {"location": "https://github.com/grpc/grpc-swift-nio-transport.git", "state": {"version": "2.12.0"}},
        {"location": "https://github.com/sparkle-project/Sparkle.git", "state": {"version": "2.10.2"}},
        {"location": "https://github.com/apple/swift-log.git", "state": {"version": "1.17.0"}},
    ]
    TEXT = """| Package | Pinned version |
|---|---|
| [grpc/grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport) | 2.10.0 |
| [apple/swift-log](https://github.com/apple/swift-log) | 1.17.0 |

[Sparkle's LICENSE at 2.10.1](https://github.com/sparkle-project/Sparkle/blob/2.10.1/LICENSE).
"""

    def test_version_cells_and_license_links_follow_package_resolved(self):
        fixed, changes = notices.fix_versions(self.TEXT, self.PINS)
        self.assertIn("(https://github.com/grpc/grpc-swift-nio-transport) | 2.12.0 |", fixed)
        self.assertIn("Sparkle/blob/2.10.2/LICENSE", fixed)
        self.assertIn("swift-log) | 1.17.0 |", fixed)
        self.assertEqual(sorted(changes), ["grpc/grpc-swift-nio-transport: 2.10.0 -> 2.12.0", "sparkle-project/Sparkle: 2.10.1 -> 2.10.2"])

    def test_a_package_the_notices_never_name_is_left_for_a_human(self):
        pins = [{"location": "https://github.com/example/new-package.git", "state": {"version": "1.0.0"}}]
        fixed, changes = notices.fix_versions(self.TEXT, pins)
        self.assertEqual((fixed, changes), (self.TEXT, []))

    def test_fixing_twice_changes_nothing(self):
        once, _ = notices.fix_versions(self.TEXT, self.PINS)
        twice, changes = notices.fix_versions(once, self.PINS)
        self.assertEqual((twice, changes), (once, []))


class LocalizationSafetyTests(unittest.TestCase):
    def test_reordered_arguments_require_positions(self):
        base = {"slope": "Cold raises consumption by %@, across %d trips."}
        self.assertTrue(localization.validate_values(base, [("slope", "%d회 기준 %@", 1)]))
        self.assertFalse(localization.validate_values(base, [("slope", "%2$d회 기준 %1$@", 1)]))

    def test_missing_wrong_and_conflicting_arguments_fail(self):
        base = {"count": "Hidden trips (%d)"}
        for value in (" ", "a", "%@", "%1$d %1$@"):
            with self.subTest(value=value):
                self.assertTrue(localization.validate_values(base, [("count", value, 1)]))
        self.assertEqual(localization.format_signature("100%%, %02d"), {1: "d"})
        self.assertNotEqual(localization.format_signature("%d"), localization.format_signature("%ld"))
        self.assertEqual(localization.format_signature("battery % on lock screen"), {})

    def test_literal_percent_does_not_mask_a_following_argument(self):
        self.assertEqual(localization.format_signature("%% %@"), {1: "@"})
        self.assertEqual(localization.format_signature("%1$@ %1$@"), {1: "@"})

    def test_blank_translations_fail_even_without_arguments(self):
        self.assertTrue(localization.validate_values({"Restore": "Restore"}, [("Restore", " ", 2)]))
        self.assertFalse(localization.validate_values({"": ""}, [("", "", 2)]))

    def test_new_untranslated_key_fails_even_if_total_is_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for language, entries in {
                "en": {"Old": "Old text", "New": "New text"},
                "sv": {"Old": "Gammal text", "New": "New text"},
            }.items():
                folder = root / f"{language}.lproj"
                folder.mkdir()
                (folder / "Localizable.strings").write_text("\n".join(
                    f'{json.dumps(key)} = {json.dumps(value)};' for key, value in entries.items()
                ))
            baseline = root / "counts.json"
            baseline.write_text(json.dumps({"sv": 1}))
            keys = root / "keys.json"
            keys.write_text(json.dumps({"sv": ["Old"]}))
            output = io.StringIO()
            with patch.object(localization, "RESOURCES_DIR", root), \
                    patch.object(localization, "BASELINE_PATH", baseline), \
                    patch.object(localization, "KEY_BASELINE_PATH", keys), \
                    patch("sys.argv", ["check-localization.py"]), contextlib.redirect_stdout(output):
                self.assertEqual(localization.main(), 1)
            self.assertIn("newly untranslated keys", output.getvalue())


class GitPathTests(unittest.TestCase):
    def test_nul_delimited_paths_preserve_whitespace_and_non_utf8(self):
        result = subprocess.CompletedProcess([], 0, stdout=b"Sources/one.swift\0Sources/line\nbreak.swift\0Sources/a b.swift\0Sources/\xff.swift\0")
        with patch.object(sync.subprocess, "run", return_value=result):
            paths = sync.untracked_files()
        self.assertEqual(len(paths), 4)
        self.assertIn("Sources/line\nbreak.swift", paths)
        self.assertTrue(all("\0" not in path for path in paths))
        self.assertIn(b"Sources/\xff.swift", [path.encode(errors="surrogateescape") for path in paths])


class PackagingOrderTests(unittest.TestCase):
    def test_parallel_default_build_waits_for_app_before_packaging(self):
        # Override only side effects. Dependencies and target selection come from the real Makefile.
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            makefile = (ROOT / "Makefile").read_text()
            makefile = makefile.replace("$(MAKE) package-dmg", "$(MAKE) -f Harness.mk package-dmg")
            (root / "Makefile").write_text(makefile)
            (root / "Harness.mk").write_text(
                "include Makefile\n"
                "app:\n\t@mkdir -p staged.app\n\t@touch app-ready\n"
                "package-dmg:\n\t@test -f app-ready\n\t@touch packaged\n"
            )
            result = subprocess.run(
                ["make", "-j4", "-f", "Harness.mk", "all", "IDENTITY=-", "AUTODETECTED_IDENTITY=", "SKIP_BUILD=1"],
                cwd=root, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((root / "packaged").is_file())


class AppIntentsFlagCaptureTests(unittest.TestCase):
    """The compile-command capture must survive a concurrent build compiling the module first."""

    COMPILE_LINE = "swift-frontend -c -module-name Fake -filelist /tmp/fake.filelist -o /tmp/fake.o"

    def run_capture(self, silent_builds):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "Scripts").mkdir()
            for name in ("generate-appintents-metadata.sh", "appintents-capture-flags.py",
                         "appintents-compile-consts.py"):
                (root / "Scripts" / name).write_text((ROOT / "Scripts" / name).read_text())
            sources = root / "Sources" / "Fake"
            sources.mkdir(parents=True)
            (sources / "Fake.swift").write_text("// stub\n")
            developer = root / "Xcode.app" / "Contents" / "Developer"
            developer.mkdir(parents=True)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            counter = root / "swift-calls"
            (root / "scratch").mkdir()  # SwiftPM creates this on a real build
            stubs = {
                "xcrun": "echo /sdk\n",
                "defaults": "echo 1\n",
                # Prints the module compile command only once `silent_builds` builds have passed,
                # the way SwiftPM stays quiet when another build already compiled the module.
                "swift": (
                    f'echo x >> "{counter}"\n'
                    f'if [ "$(wc -l < "{counter}")" -gt {silent_builds} ]; then\n'
                    f'    echo "{self.COMPILE_LINE}"\nfi\n'
                ),
            }
            for name, body in stubs.items():
                path = bin_dir / name
                path.write_text("#!/bin/sh\n" + body)
                path.chmod(0o755)
            # On macOS /usr/bin/python3 is an xcrun shim that rejects the fake developer directory.
            (bin_dir / "python3").symlink_to(sys.executable)
            env = {
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "DEVELOPER_DIR": str(developer),
                "TMPDIR": str(root),
            }
            result = subprocess.run(
                ["sh", "Scripts/generate-appintents-metadata.sh", "--output", str(root / "out"),
                 "--module", "Fake", "--source-directory", "Sources/Fake",
                 "--scratch-path", str(root / "scratch")],
                cwd=root, env=env, capture_output=True, text=True,
            )
            builds = len(counter.read_text().splitlines()) if counter.exists() else 0
            cache = root / "scratch" / "hisingen-appintents-flags-Fake.txt"
            cached = cache.read_text() if cache.exists() else ""
            return result, builds, cached

    def test_a_build_that_prints_no_command_is_retried_once(self):
        result, builds, cached = self.run_capture(silent_builds=1)
        self.assertEqual(builds, 2, result.stderr)
        self.assertIn(self.COMPILE_LINE, cached)
        self.assertNotIn("could not read", result.stderr)

    def test_persistent_silence_fails_with_a_hint_and_caches_nothing(self):
        result, builds, cached = self.run_capture(silent_builds=99)
        self.assertEqual(builds, 2, result.stderr)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(cached, "")
        self.assertIn("could not read the Fake module compile command", result.stderr)
        self.assertIn("another build in this checkout", result.stderr)


if __name__ == "__main__":
    unittest.main()
