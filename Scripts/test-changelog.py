#!/usr/bin/env python3
"""Fragment validation and assembly for Scripts/changelog.py."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("changelog", ROOT / "Scripts/changelog.py")
changelog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changelog)

BASE = """# Changelog

## [2.0.0] - 2026-01-01

### Added

- **Older entry.** Stays put.

### Screenshots

- shot
"""


class FragmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name) / "changelog.d"
        self.dir.mkdir()
        self.log = Path(self.tmp.name) / "CHANGELOG.md"

    def fragment(self, name, text):
        (self.dir / name).write_text(text)

    def test_a_well_formed_fragment_has_no_problems(self):
        self.fragment("fine.fixed.md", "- **Something was fixed.** The longer explanation\n  wraps onto a second line.\n")
        self.assertEqual(changelog.problems(self.dir / "fine.fixed.md"), [])

    def test_bad_names_and_shapes_are_reported(self):
        cases = {
            "Bad Name.fixed.md": "- **Ok.** Fine.\n",
            "no-type.md": "- **Ok.** Fine.\n",
            "plain.fixed.md": "Just a sentence.\n",
            "heading.fixed.md": "- **Ok.** Fine.\n# Heading\n",
            "two.fixed.md": "- **Ok.** Fine.\n- **Second.** Entry.\n",
            "blank.fixed.md": "- **Ok.** Fine.\n\n  More.\n",
            "indent.fixed.md": "- **Ok.** Fine.\n    four spaces\n",
            "newline.fixed.md": "- **Ok.** Fine.",
            "nostop.fixed.md": "- **No full stop** Fine.\n",
        }
        for name, text in cases.items():
            with self.subTest(name=name):
                self.fragment(name, text)
                self.assertTrue(changelog.problems(self.dir / name))

    def test_the_readme_is_not_a_fragment(self):
        self.fragment("README.md", "docs\n")
        self.fragment("a.added.md", "- **Added.** Yes.\n")
        self.assertEqual([p.name for p in changelog.fragment_paths(self.dir)], ["a.added.md"])

    def test_assembly_adds_to_existing_and_new_subsections_in_order_and_removes_files(self):
        self.log.write_text(BASE + "\n## [1.0.0] - 2025-01-01\n\n### Fixed\n\n- **Ancient.** Untouched.\n")
        self.fragment("b-second.added.md", "- **Second added.** Two.\n")
        self.fragment("a-first.added.md", "- **First added.** One.\n")
        self.fragment("c-fix.fixed.md", "- **A fix.** Done.\n")
        moved = changelog.assemble("2.0.0", self.log, self.dir)
        text = self.log.read_text()
        self.assertEqual(moved, 3)
        added = text.index("- **First added.**")
        self.assertLess(text.index("- **Older entry.**"), added)
        self.assertLess(added, text.index("- **Second added.**"), "fragments assemble in filename order")
        self.assertLess(text.index("- **Second added.**"), text.index("### Fixed"))
        self.assertLess(text.index("- **A fix.**"), text.index("### Screenshots"), "new subsections come before Screenshots")
        self.assertLess(text.index("### Screenshots"), text.index("## [1.0.0]"))
        self.assertEqual(text.count("### Fixed"), 2, "the older release's Fixed section is not reused")
        self.assertEqual(list(self.dir.iterdir()), [])

    def test_assembly_with_no_fragments_changes_nothing(self):
        self.log.write_text(BASE)
        self.assertEqual(changelog.assemble("2.0.0", self.log, self.dir), 0)
        self.assertEqual(self.log.read_text(), BASE)

    def test_a_broken_fragment_stops_assembly_before_anything_is_written(self):
        self.log.write_text(BASE)
        self.fragment("ok.added.md", "- **Fine.** Yes.\n")
        self.fragment("bad.fixed.md", "no bullet\n")
        with self.assertRaises(ValueError):
            changelog.assemble("2.0.0", self.log, self.dir)
        self.assertEqual(self.log.read_text(), BASE)
        self.assertEqual(len(list(self.dir.iterdir())), 2)

    def test_a_missing_section_is_an_error(self):
        self.log.write_text(BASE)
        self.fragment("ok.added.md", "- **Fine.** Yes.\n")
        with self.assertRaises(ValueError):
            changelog.assemble("9.9.9", self.log, self.dir)


if __name__ == "__main__":
    unittest.main()
