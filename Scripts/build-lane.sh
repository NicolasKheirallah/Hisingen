#!/bin/sh
# One compiler-driven build or test at a time across the worktrees of this repository.
#
#   sh Scripts/build-lane.sh run [--wait SECONDS] [--session NAME] -- COMMAND [ARGS...]
#   sh Scripts/build-lane.sh status
#
# `run` claims the lane, runs the command, and releases the lane when the command ends, however it
# ends. The claim records the wrapper's process ID and the command's, so a claim whose processes
# are gone (a crashed session, a closed terminal) is reclaimed by the next caller instead of
# blocking everyone until someone notices. A claim written by anything else, which carries no
# process ID, is never reclaimed automatically: `status` prints it for its owner to clear.
#
# Exit status: the command's, or 75 when the lane stayed busy for the whole --wait.
set -eu

lane_dir=${HISINGEN_BUILD_LANE_DIR:-}
if [ -z "$lane_dir" ]; then
  lane_dir="$(git rev-parse --path-format=absolute --git-common-dir)/hisingen-build-lane"
fi
poll=${HISINGEN_BUILD_LANE_POLL:-5}
# A claim directory with no owner file is a claim that is being written. After this long it is
# a claim whose writer died between creating the directory and writing the file.
unwritten_grace=60

usage() {
  echo "Usage: build-lane.sh run [--wait SECONDS] [--session NAME] -- COMMAND [ARGS...]" >&2
  echo "       build-lane.sh status" >&2
  exit 64
}

now() { date +%s; }

field() { # field NAME FILE
  sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1
}

alive() { # alive PID
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

describe() { # describe OWNER_FILE
  if [ -f "$1" ]; then
    sed 's/^/  /' "$1" >&2
  else
    echo "  (the claim has no owner file yet)" >&2
  fi
}

# Prints "stale" when the claim's processes are gone, "foreign" when it carries no process ID,
# "live" otherwise.
claim_state() {
  owner="$lane_dir/owner"
  if [ ! -f "$owner" ]; then
    created=$(stat -c %Y "$lane_dir" 2>/dev/null || stat -f %m "$lane_dir" 2>/dev/null || echo 0)
    if [ $(( $(now) - created )) -gt "$unwritten_grace" ]; then echo stale; else echo live; fi
    return
  fi
  holder=$(field pid "$owner")
  if [ -z "$holder" ]; then echo foreign; return; fi
  if alive "$holder" || alive "$(field child "$owner")"; then echo live; else echo stale; fi
}

# Removes a stale claim. The directory is renamed away first, so only one caller wins, and the
# token is checked again on the renamed copy: if another caller reclaimed the lane between the
# check and the rename, the new claim is put back untouched.
reap() {
  seen=$(field token "$lane_dir/owner")
  graveyard="$lane_dir.reaped.$$"
  mv "$lane_dir" "$graveyard" 2>/dev/null || return 0
  if [ "$(field token "$graveyard/owner")" = "$seen" ]; then
    rm -rf "$graveyard"
  elif ! mv "$graveyard" "$lane_dir" 2>/dev/null; then
    rm -rf "$graveyard"
  fi
}

write_owner() { # write_owner TOKEN SESSION CHILD COMMAND
  {
    echo "pid=$$"
    echo "child=$3"
    echo "token=$1"
    echo "session=$2"
    echo "worktree=$PWD"
    echo "started=$(now)"
    echo "command=$4"
  } > "$lane_dir/owner.$$"
  mv "$lane_dir/owner.$$" "$lane_dir/owner"
}

acquire() { # acquire WAIT_SECONDS TOKEN SESSION COMMAND
  deadline=$(( $(now) + $1 ))
  while :; do
    if mkdir "$lane_dir" 2>/dev/null; then
      write_owner "$2" "$3" "" "$4"
      return 0
    fi
    state=$(claim_state)
    if [ "$state" = stale ]; then
      echo "build lane: reclaiming a claim whose processes are gone" >&2
      reap
      continue
    fi
    if [ "$(now)" -ge "$deadline" ]; then
      echo "build lane: busy ($state claim)" >&2
      describe "$lane_dir/owner"
      return 75
    fi
    sleep "$poll"
  done
}

cmd_status() {
  if [ ! -d "$lane_dir" ]; then echo "build lane: free"; return 0; fi
  echo "build lane: $(claim_state) claim"
  describe "$lane_dir/owner"
  sed 's/^  //' /dev/null
}

cmd_run() {
  wait_seconds=0
  session=${HISINGEN_BUILD_LANE_SESSION:-$(basename "$PWD")}
  while [ $# -gt 0 ]; do
    case "$1" in
      --wait) wait_seconds=${2:?--wait needs a number of seconds}; shift 2 ;;
      --session) session=${2:?--session needs a name}; shift 2 ;;
      --) shift; break ;;
      *) usage ;;
    esac
  done
  [ $# -gt 0 ] || usage
  case "$wait_seconds" in ''|*[!0-9]*) usage ;; esac

  token="$$.$(now)"
  acquire "$wait_seconds" "$token" "$session" "$*" || exit $?

  child=""
  # shellcheck disable=SC2329  # runs from the EXIT trap
  release() {
    if [ "$(field token "$lane_dir/owner")" = "$token" ]; then rm -rf "$lane_dir"; fi
  }
  # shellcheck disable=SC2329  # runs from the signal traps
  forward() {
    if [ -n "$child" ]; then kill -"$1" "$child" 2>/dev/null || true; fi
  }
  trap release EXIT
  trap 'forward INT' INT
  trap 'forward TERM' TERM
  trap 'forward HUP' HUP

  # Background jobs lose stdin in a non-interactive shell unless it is redirected explicitly.
  "$@" <&0 &
  child=$!
  write_owner "$token" "$session" "$child" "$*"
  status=0
  wait "$child" || status=$?
  # A forwarded signal interrupts the first wait; the command may still be shutting down.
  while alive "$child"; do wait "$child" 2>/dev/null || true; done
  exit "$status"
}

[ $# -gt 0 ] || usage
command=$1
shift
case "$command" in
  run) cmd_run "$@" ;;
  status) cmd_status ;;
  *) usage ;;
esac
