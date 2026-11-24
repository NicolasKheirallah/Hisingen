#!/usr/bin/env python3
"""Run a command under the build lane shared by this repository's worktrees."""

import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid


def usage():
    print("Usage: build-lane.sh run [--wait SECONDS] [--session NAME] -- COMMAND [ARGS...]", file=sys.stderr)
    print("       build-lane.sh status", file=sys.stderr)
    return 64


def read_owner(lane):
    try:
        return (lane / "owner").read_text()
    except FileNotFoundError:
        return None


def owner_field(owner, key):
    prefix = f"{key}="
    return next((line.removeprefix(prefix) for line in (owner or "").splitlines() if line.startswith(prefix)), "")


def alive(pid):
    if not pid.isdecimal() or int(pid) <= 0:
        return False
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def claim_state(lane, owner):
    if owner is None:
        try:
            age = time.time() - lane.stat().st_mtime
        except FileNotFoundError:
            return "free"
        # An older client may be creating the owner file.
        return "stale" if age > 60 else "live"
    pid = owner_field(owner, "pid")
    if not pid:
        return "foreign"
    return "live" if alive(pid) or alive(owner_field(owner, "child")) else "stale"


def describe(owner):
    if owner:
        for line in owner.splitlines():
            print(f"  {line}", file=sys.stderr)
    else:
        print("  (the claim has no owner file yet)", file=sys.stderr)


def write_owner(lane, token, session, command, child=""):
    temporary = lane / f"owner.{os.getpid()}"
    temporary.write_text(
        f"pid={os.getpid()}\nchild={child}\ntoken={token}\nsession={session}\n"
        f"worktree={Path.cwd()}\nstarted={int(time.time())}\ncommand={' '.join(command)}\n"
    )
    temporary.replace(lane / "owner")


def run_claimed(lane, guard, session, command):
    token = uuid.uuid4().hex
    child = None
    pending_signal = None

    def forward(signum, _frame):
        nonlocal pending_signal
        pending_signal = signum
        if child is not None:
            child.send_signal(signum)

    try:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, forward)
        write_owner(lane, token, session, command)
        # If the wrapper dies during startup, the build still holds the lock.
        try:
            child = subprocess.Popen(command, pass_fds=(guard.fileno(),))
        except (FileNotFoundError, PermissionError) as error:
            print(f"build lane: {error}", file=sys.stderr)
            return 127 if isinstance(error, FileNotFoundError) else 126
        try:
            if pending_signal is not None:
                child.send_signal(pending_signal)
            write_owner(lane, token, session, command, child.pid)
        finally:
            status = child.wait()
        return 128 - status if status < 0 else status
    finally:
        if owner_field(read_owner(lane), "token") == token:
            shutil.rmtree(lane)


def lock_path(lane):
    return lane.with_name(f"{lane.name}.lock")


def status(lane):
    try:
        guard = lock_path(lane).open("r")
    except FileNotFoundError:
        owner = read_owner(lane)
        state = claim_state(lane, owner)
    else:
        with guard:
            try:
                fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                state, owner = "live", read_owner(lane)
            else:
                owner = read_owner(lane)
                state = claim_state(lane, owner)
    if state == "free":
        print("build lane: free")
    else:
        print(f"build lane: {state} claim")
        describe(owner)
    return 0


def run(lane, wait_seconds, session, command):
    deadline = time.monotonic() + wait_seconds
    interval = float(os.environ.get("HISINGEN_BUILD_LANE_POLL", "5"))
    # The lock file stays at one inode even when the owner directory is reclaimed.
    with lock_path(lane).open("a") as guard:
        while True:
            try:
                fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                state, owner = "live", read_owner(lane)
            else:
                owner = read_owner(lane)
                state = claim_state(lane, owner)
                if state == "stale":
                    print("build lane: reclaiming a claim whose processes are gone", file=sys.stderr)
                    shutil.rmtree(lane)
                if state in ("free", "stale"):
                    try:
                        lane.mkdir()
                    except FileExistsError:
                        # A manual caller can still claim the directory without this lock.
                        state, owner = "live", read_owner(lane)
                    else:
                        return run_claimed(lane, guard, session, command)
                fcntl.flock(guard, fcntl.LOCK_UN)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print(f"build lane: busy ({state} claim)", file=sys.stderr)
                describe(owner)
                return 75
            time.sleep(min(interval, remaining))


def main(args):
    mode, *options = args if args else [""]
    if mode not in ("run", "status"):
        return usage()
    lane_dir = os.environ.get("HISINGEN_BUILD_LANE_DIR")
    if not lane_dir:
        common = subprocess.check_output(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], text=True
        ).strip()
        lane_dir = str(Path(common) / "hisingen-build-lane")
    lane = Path(lane_dir)
    if mode == "status":
        return status(lane)
    wait_seconds = 0
    session = os.environ.get("HISINGEN_BUILD_LANE_SESSION", Path.cwd().name)
    while options and options[0] in ("--wait", "--session"):
        if len(options) < 2 or not options[1]:
            return usage()
        option, value, *options = options
        if option == "--wait":
            if not value.isascii() or not value.isdecimal():
                return usage()
            wait_seconds = int(value)
        else:
            session = value
    if len(options) < 2 or options[0] != "--":
        return usage()
    return run(lane, wait_seconds, session, options[1:])


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError) as error:
        print(f"build lane: {error}", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
