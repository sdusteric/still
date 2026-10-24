#!/usr/bin/env bash
# Shared helpers for scripts/accept.sh. Source it, do not run it.
#
# * ACCEPT_RUN_DIR (default build/accept/<timestamp>) holds the logs, the results file and every
#   fresh SNAP_HOME that a group uses. Nothing here touches the real Snap folder
#   (~/Library/Application Support/Snap), ~/Downloads or the real pasteboard.
# * record/pass/fail/skip print one line per criterion and append it to results.tsv.
# * track_pid registers a process this run started; the EXIT trap stops each one by PID.
# * remove_run_path deletes only exact absolute paths below build/accept/.
#
# Written for bash 3.2 (macOS /bin/bash): no associative arrays, no `set -u`.

if [ -n "${ACCEPT_LIB_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
ACCEPT_LIB_LOADED=1

ACCEPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$ACCEPT_LIB_DIR/.." && pwd -P)"
cd "$REPO" || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ -z "${ACCEPT_RUN_DIR:-}" ]; then
  ACCEPT_RUN_DIR="$REPO/build/accept/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$ACCEPT_RUN_DIR"
ACCEPT_RUN_DIR="$(cd "$ACCEPT_RUN_DIR" && pwd -P)"
export ACCEPT_RUN_DIR
RUN="$ACCEPT_RUN_DIR"
RESULTS="$RUN/results.tsv"
touch "$RESULTS"

# ---------------------------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------------------------

record() { # id status note
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RESULTS"
  printf '%-6s %-5s %s\n' "$1" "$2" "$3"
}
pass() { record "$1" PASS "${2:-}"; }
fail() { record "$1" FAIL "${2:-}"; }
skip() { record "$1" SKIP "${2:-}"; }

note() { printf '  %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------------------------
# Commands with logs
# ---------------------------------------------------------------------------------------------

LAST_LOG=""

# run_logged <name> <command...>: output goes to $RUN/<name>.log. Shows the tail on failure.
run_logged() {
  local name=$1
  shift
  LAST_LOG="$RUN/$name.log"
  note "$name: $*"
  "$@" >"$LAST_LOG" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then
    note "$name failed (exit $rc), last lines of $LAST_LOG:"
    tail -n 12 "$LAST_LOG" | sed 's/^/    /' >&2
  fi
  return $rc
}

# ---------------------------------------------------------------------------------------------
# Processes this run started
# ---------------------------------------------------------------------------------------------

TRACKED_PIDS=""

track_pid() { TRACKED_PIDS="$TRACKED_PIDS $1"; }

untrack_pid() {
  local keep="" p
  for p in $TRACKED_PIDS; do
    [ "$p" = "$1" ] || keep="$keep $p"
  done
  TRACKED_PIDS="$keep"
}

pid_alive() { kill -0 "$1" 2>/dev/null; }

# stop_pid <pid>: SIGTERM, up to 5 s of grace, then SIGKILL. Only ever a PID we started.
stop_pid() {
  local pid=$1 i
  pid_alive "$pid" || return 0
  kill -TERM "$pid" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pid_alive "$pid" || return 0
    sleep 0.5
  done
  kill -KILL "$pid" 2>/dev/null
  return 0
}

accept_cleanup() {
  local p
  for p in $TRACKED_PIDS; do
    stop_pid "$p"
  done
  TRACKED_PIDS=""
  if [ -n "${ACCEPT_EXTRA_CLEANUP:-}" ]; then
    $ACCEPT_EXTRA_CLEANUP
  fi
}
trap accept_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------------------------
# Deleting
# ---------------------------------------------------------------------------------------------

# remove_run_path <absolute path>: recursive delete of one exact directory below build/accept/.
remove_run_path() {
  local p=$1
  case "$p" in
    "$REPO"/build/accept/?*) ;;
    *)
      note "refusing to delete $p"
      return 1
      ;;
  esac
  case "$p" in
    *..* | *"*"* | *"?"*)
      note "refusing to delete $p"
      return 1
      ;;
  esac
  [ -d "$p" ] || return 0
  rm -rf -- "$p"
}

# ---------------------------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------------------------

# A fresh SNAP_HOME below the run folder for one group of commands; prints its path.
fresh_home() {
  local dir
  dir="$(mktemp -d "$RUN/home.XXXXXX")"
  echo "$dir"
}

# Forget every SNAP_* variable from the caller's shell so no setting leaks into a check. Each
# command then gets its own SNAP_HOME from fresh_home.
clear_snap_env() {
  local v
  for v in $(env | sed -n 's/^\(SNAP_[A-Za-z0-9_]*\)=.*/\1/p'); do
    case "$v" in
      SNAP_SCRATCH) ;; # a build location, not a behaviour switch
      *) unset "$v" ;;
    esac
  done
}

# The frontmost app as "asn name" on one line.
front() {
  local asn name
  asn="$(lsappinfo front 2>/dev/null || true)"
  name="$(lsappinfo info -only name "$asn" 2>/dev/null | head -1 || true)"
  echo "$asn $name"
}
