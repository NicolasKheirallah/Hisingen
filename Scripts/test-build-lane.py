#!/usr/bin/env python3
"""Behavior of Scripts/build-lane.sh against a throwaway lane directory."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "Scripts/build-lane.sh"


class BuildLaneTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.lane = Path(self.tmp.name) / "lane"
        self.env = {**os.environ, "HISINGEN_BUILD_LANE_DIR": str(self.lane), "HISINGEN_BUILD_LANE_POLL": "1"}

    def lane_script(self, *args, **kwargs):
        return subprocess.run(["sh", str(SCRIPT), *args], env=self.env, capture_output=True, text=True, timeout=60, **kwargs)

    def spawn(self, *args):
        return subprocess.Popen(["sh", str(SCRIPT), *args], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def wait_for_owner(self):
        for _ in range(100):
            owner = self.lane / "owner"
            if owner.exists() and "child=" in owner.read_text() and "child=\n" not in owner.read_text():
                return owner.read_text()
            time.sleep(0.05)
        self.fail("the claim never recorded its command")

    def write_claim(self, text):
        self.lane.mkdir()
        (self.lane / "owner").write_text(text)

    def test_the_lane_is_held_while_the_command_runs_and_freed_after(self):
        marker = Path(self.tmp.name) / "inside"
        result = self.lane_script("run", "--", "sh", "-c", f'test -f "{self.lane}/owner" && touch "{marker}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(marker.exists(), "the command did not run inside a claimed lane")
        self.assertFalse(self.lane.exists(), "the lane stayed claimed after the command ended")

    def test_the_commands_exit_status_is_kept_and_the_lane_is_still_freed(self):
        result = self.lane_script("run", "--", "sh", "-c", "exit 7")
        self.assertEqual(result.returncode, 7)
        self.assertFalse(self.lane.exists())

    def test_a_second_caller_finds_the_lane_busy_and_names_the_holder(self):
        holder = self.spawn("run", "--session", "first", "--", "sleep", "30")
        self.addCleanup(holder.wait)
        self.addCleanup(holder.kill)
        self.wait_for_owner()
        second = self.lane_script("run", "--", "true")
        self.assertEqual(second.returncode, 75)
        self.assertIn("busy", second.stderr)
        self.assertIn("session=first", second.stderr)
        holder.terminate()
        holder.wait(timeout=30)
        self.assertFalse(self.lane.exists(), "terminating the holder did not free the lane")

    def test_a_waiting_caller_takes_the_lane_when_the_holder_finishes(self):
        holder = self.spawn("run", "--", "sleep", "2")
        self.addCleanup(holder.wait)
        self.addCleanup(holder.kill)
        self.wait_for_owner()
        waiter = self.lane_script("run", "--wait", "30", "--", "true")
        self.assertEqual(waiter.returncode, 0, waiter.stderr)
        holder.wait(timeout=30)

    def test_a_claim_whose_processes_are_gone_is_reclaimed(self):
        dead = subprocess.Popen(["true"])
        dead.wait()
        self.write_claim(f"pid={dead.pid}\nchild=\ntoken=old\nsession=crashed\nstarted=0\n")
        result = self.lane_script("run", "--", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reclaiming", result.stderr)
        self.assertFalse(self.lane.exists())

    def test_a_claim_with_a_live_child_is_not_reclaimed_even_if_the_wrapper_died(self):
        dead = subprocess.Popen(["true"])
        dead.wait()
        child = subprocess.Popen(["sleep", "30"])
        self.addCleanup(child.wait)
        self.addCleanup(child.kill)
        self.write_claim(f"pid={dead.pid}\nchild={child.pid}\ntoken=old\nsession=orphan\nstarted=0\n")
        result = self.lane_script("run", "--", "true")
        self.assertEqual(result.returncode, 75)
        self.assertTrue(self.lane.exists())

    def test_a_claim_without_a_process_id_is_never_reclaimed(self):
        self.write_claim("running: something else (pid 1) since long ago\n")
        result = self.lane_script("run", "--", "true")
        self.assertEqual(result.returncode, 75)
        self.assertIn("something else", result.stderr)
        self.assertTrue(self.lane.exists())
        status = self.lane_script("status")
        self.assertIn("foreign", status.stdout)

    def test_status_reports_free_live_and_stale(self):
        self.assertIn("free", self.lane_script("status").stdout)
        dead = subprocess.Popen(["true"])
        dead.wait()
        self.write_claim(f"pid={dead.pid}\nchild=\ntoken=old\nsession=crashed\nstarted=0\n")
        self.assertIn("stale", self.lane_script("status").stdout)

    def test_a_missing_command_or_bad_wait_is_a_usage_error(self):
        self.assertEqual(self.lane_script("run").returncode, 64)
        self.assertEqual(self.lane_script("run", "--wait", "soon", "--", "true").returncode, 64)
        self.assertFalse(self.lane.exists())


if __name__ == "__main__":
    unittest.main()
