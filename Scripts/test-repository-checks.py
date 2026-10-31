#!/usr/bin/env python3
"""Regression checks for localization safety, Git path parsing and packaging order."""
import contextlib
import importlib.util
import io
import json
import pathlib
import subprocess
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


if __name__ == "__main__":
    unittest.main()
