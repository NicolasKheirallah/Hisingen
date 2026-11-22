#!/usr/bin/env python3
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("selection", pathlib.Path(__file__).with_name("check-test-selection.py"))
selection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selection)


class SelectionTests(unittest.TestCase):
    def test_empty_or_mistyped_filter_fails(self):
        with self.assertRaisesRegex(ValueError, "No tests selected"):
            selection.validate_selection(["HisingenTests.Unit/test()"], ["Typo"])
        with self.assertRaises(ValueError):
            selection.validate_selection([])

    def test_multiple_filters_are_unioned_and_skips_win(self):
        tests = ["HisingenTests.One/test()", "HisingenTests.Two/test()", "HisingenTests.LiveOne/test()"]
        self.assertEqual(selection.validate_selection(tests, ["One", "Two"], ["Live"], set()), tests[:2])

    def test_renamed_integration_suite_cannot_enter_deterministic_gate(self):
        with self.assertRaisesRegex(ValueError, "Integration tests escaped"):
            selection.validate_selection(["HisingenTests.Renamed/test()"], skips=["Live"], suites={"Renamed"})

    def test_discovery_ignores_compiler_noise(self):
        self.assertEqual(selection.discovered_tests("warning: hello\nHisingenTests.One/test()\n"),
                         ["HisingenTests.One/test()"])

    def test_cli_applies_forwarded_selectors(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            listing = root / "list.txt"
            listing.write_text("HisingenTests.One/test()\nHisingenTests.Two/test()\n")
            command = [sys.executable, str(pathlib.Path(selection.__file__)), "selection",
                       "--output", str(root), str(listing), "--", "--skip-build", "--filter", "Typo"]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("No tests selected", result.stderr)
            command[-1] = "One"
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("1 tests", result.stdout)

    def test_build_step_matches_the_run_and_drops_only_test_selectors(self):
        run = ["swift", "test", "--disable-sandbox", "--disable-xctest", "--enable-swift-testing", "--force-resolved-versions",
               "--enable-code-coverage", "-Xswiftc", "-warnings-as-errors", "--skip", "Live", "--no-parallel", "--filter", "Suite",
               "--num-workers=2", "--xunit-output", "out.xml"]
        self.assertEqual(selection.build_command(run), ["swift", "build", "--build-tests", "--disable-sandbox", "--force-resolved-versions",
                                                        "--enable-code-coverage", "-Xswiftc", "-warnings-as-errors"])

    def test_build_step_keeps_the_framework_search_path_pair(self):
        run = ["swift", "test", "-Xswiftc", "-F", "-Xswiftc", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks", "--skip", "Live"]
        self.assertEqual(selection.build_command(run)[3:], ["-Xswiftc", "-F", "-Xswiftc", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])

    def test_build_step_refuses_anything_but_swift_test(self):
        with self.assertRaises(ValueError):
            selection.build_command(["swift", "build"])

    def test_discovery_arguments_still_strip_selectors(self):
        self.assertEqual(selection.without_run_selectors(["swift", "test", "--skip-build", "--filter", "A", "--no-parallel", "--skip=Live"]),
                         ["swift", "test", "--skip-build"])

    def test_all_skipped_result_is_not_a_successful_execution(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "results.xml"
            path.write_text('<testsuites><testsuite><testcase name="disabled"><skipped/></testcase></testsuite></testsuites>')
            with self.assertRaisesRegex(ValueError, "no executed tests"):
                selection.validate_results(path)
            path.write_text('<testsuites><testsuite><testcase name="ok"/><testcase name="bad"><failure/></testcase></testsuite></testsuites>')
            self.assertEqual(selection.validate_results(path), {"executed": 2, "skipped": 0, "failed": 1})


if __name__ == "__main__":
    program = unittest.main(exit=False)
    if program.result.wasSuccessful():
        print("test-selection-regressions-passed")
    sys.exit(0 if program.result.wasSuccessful() else 1)
