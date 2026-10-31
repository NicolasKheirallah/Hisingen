#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import subprocess
import os
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("source_hygiene", ROOT / "Scripts/check-source-hygiene.py")
hygiene = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hygiene)


class SourceValidationTests(unittest.TestCase):
    def test_detects_names_and_credential_patterns_without_printing_secrets(self):
        for name, content in [(".env", b"example"), (".env.production", b"example"), ("keys/private.key", b"example"), ("file.swift", b"AKIA" + b"A" * 16), ("file.swift", b"-----BEGIN " + b"PRIVATE KEY-----")]:
            with self.subTest(name=name):
                with self.assertRaises(ValueError) as error:
                    hygiene.inspect_file(name, content)
                self.assertNotIn(content.decode(), str(error.exception))
        hygiene.inspect_file(".env.example", b"VOLVO_CLIENT_ID=")
        hygiene.inspect_file("Sources/example.swift", b"enum Example {}")

    def test_missing_artifacts_fail_before_platform_tools(self):
        result = subprocess.run(["sh", "Scripts/validate-release.sh", "--artifacts", "/nonexistent-ci-test.app", "/nonexistent-ci-test.dmg"], cwd=ROOT, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing app", result.stderr)

    def test_unknown_mode_fails(self):
        result = subprocess.run(["sh", "Scripts/validate-release.sh", "--unknown"], cwd=ROOT, capture_output=True)
        self.assertEqual(result.returncode, 2)


class ProtectionPolicyTests(unittest.TestCase):
    def test_rollout_removes_obsolete_context_and_keeps_app_binding(self):
        spec = importlib.util.spec_from_file_location("protection", ROOT / "Scripts/configure-ci-protection.py")
        protection = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(protection)
        current = {"rules": [{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "build-and-test (macos-14)"}]}}]}
        for aggregate in (False, True):
            desired = protection.main_rule(current, aggregate)
            required = next(rule for rule in desired["rules"] if rule["type"] == "required_status_checks")["parameters"]
            self.assertTrue(required["strict_required_status_checks_policy"])
            self.assertEqual({row["context"] for row in required["required_status_checks"]}, {"ci-required"} if aggregate else set(protection.LEGACY_CHECKS))
            self.assertTrue(all(row["integration_id"] == 15368 for row in required["required_status_checks"]))
            self.assertEqual(desired["enforcement"], "active")

    def test_fixture_ignores_local_files_and_supplied_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Scripts").mkdir()
            (root / "Sources/Hisingen/Services/API").mkdir(parents=True)
            (root / "Scripts/inject-secrets.sh").write_bytes((ROOT / "Scripts/inject-secrets.sh").read_bytes())
            (root / ".env.secrets").write_text('exit 99\n')
            environment = {**os.environ, "HISINGEN_BUILD_CONFIGURATION": "fixture", "VOLVO_CLIENT_ID": "fixture-id", "VOLVO_CLIENT_SECRET": "fixture-secret", "VOLVO_VCC_API_KEY": "fixture-api-key", "POLESTAR_CLIENT_ID": "fixture-id", "POLESTAR_CLIENT_SECRET": "fixture-secret"}
            result = subprocess.run(["sh", "Scripts/inject-secrets.sh"], cwd=root, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("isConfigured: Bool = false", (root / "Sources/Hisingen/Services/API/GeneratedVolvoSecrets.swift").read_text())
            self.assertIn("hasDataPortalCredentials: Bool = false", (root / "Sources/Hisingen/Services/API/GeneratedPolestarSecrets.swift").read_text())



class ImageDetachTests(unittest.TestCase):
    def execute_detach(self, force_failure=False, transient_failures=2):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "hdiutil"
            executable.write_text("#!/usr/bin/env python3\nimport os,pathlib,sys\np=pathlib.Path(os.environ['DETACH_CALLS'])\nlines=p.read_text().splitlines() if p.exists() else []\nlines.append(' '.join(sys.argv[1:]))\np.write_text('\\n'.join(lines)+'\\n')\nif '-force' in sys.argv: sys.exit(int(os.environ['FORCE_FAILURE']))\nsys.exit(1 if len(lines)<=int(os.environ['TRANSIENT_FAILURES']) else 0)\n")
            executable.chmod(0o755)
            calls = root / "calls"
            environment = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"], "DETACH_CALLS": str(calls), "HISINGEN_DETACH_DELAY": "0", "HISINGEN_DETACH_ATTEMPTS": "3", "FORCE_FAILURE": str(int(force_failure)), "TRANSIENT_FAILURES": str(transient_failures)}
            result = subprocess.run(["sh", str(ROOT / "Scripts/detach-image.sh"), "/disposable-readonly-test-mount"], env=environment, capture_output=True, text=True)
            return result.returncode, calls.read_text().splitlines()

    def test_transient_busy_mount_is_retried(self):
        code, calls = self.execute_detach()
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 3)
        self.assertFalse(any("-force" in call for call in calls))

    def test_force_fallback_is_bounded(self):
        code, calls = self.execute_detach(transient_failures=100)
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 4)
        self.assertIn("-force", calls[-1])

    def test_permanent_detach_failure_cannot_pass(self):
        code, calls = self.execute_detach(force_failure=True, transient_failures=100)
        self.assertNotEqual(code, 0)
        self.assertEqual(len(calls), 4)



if __name__ == "__main__":
    unittest.main()
