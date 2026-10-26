#!/usr/bin/env bash
# Background screenshots (design section 16): renders Snap's own surfaces from fakes and demo
# builders in a process that has no window and no NSApplication run loop.
#
# Usage: scripts/shots.sh [scenario ... | m2 | m2-polish]
#        default: overlay-area quick-access background-editor annotate menu settings
#        m2: pin history history-empty hud recording-countdown recording quick-access-video
#            annotate-tools background-mesh settings-recording menu-m2 (design 20.11)
#        m2-polish: recording-stalled quick-access-audio annotate-reopened menu-permission
#            (design 20.16)
#        each scenario in light and dark -> build/shots/<scenario>-<light|dark>.png (2x points)
#        other scenarios: overlay-before overlay-window settings-shortcuts settings-general settings-general-full onboarding
#                         onboarding-granted permission-hint
# Env:   SNAP_APP  bundle to run (default build/bundle/Snap.app, from scripts/bundle.sh)
#        OUT       where the PNGs go (default build/shots)
#
# Safety: each shot is a direct exec of the bundle binary (never `open`, never LaunchServices)
# with a fresh SNAP_HOME from mktemp. Shot mode must run from the bundle: the Info.plist's
# LSUIElement keeps it a UIElement, and the binary exits 78 when that key is missing. The
# frontmost app is read with `lsappinfo front` before and after every launch (exit 3 if it
# changed). While the process runs, scripts/winlist.swift
# (CGWindowList filtered by owner PID, on-screen only) is polled every 100 ms (exit 4 if the
# process ever owns an on-screen window). Only that PID is ever stopped, and the only thing
# deleted is the exact mktemp directory.
set -euo pipefail
# Shot mode never starts Sparkle; this keeps it off even if that ever changes.
export SNAP_NO_UPDATES=1

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="${SNAP_APP:-$REPO/build/bundle/Snap.app}"
BIN="$APP/Contents/MacOS/Snap"
OUT="${OUT:-$REPO/build/shots}"
LOG="$OUT/shots.log"
TOOLS="$REPO/build/shots/bin"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"
TIMEOUT_SECONDS=60
M2_SCENARIOS=(pin history history-empty hud recording-countdown recording quick-access-video annotate-tools
  background-mesh settings-recording menu-m2)
POLISH_SCENARIOS=(recording-stalled quick-access-audio annotate-reopened menu-permission)
SCENARIOS=()
for arg in "$@"; do
  case "$arg" in
    m2) SCENARIOS+=("${M2_SCENARIOS[@]}") ;;
    m2-polish) SCENARIOS+=("${POLISH_SCENARIOS[@]}") ;;
    *) SCENARIOS+=("$arg") ;;
  esac
done
[ ${#SCENARIOS[@]} -gt 0 ] || SCENARIOS=(overlay-area quick-access background-editor annotate menu settings)

[ -x "$BIN" ] || { echo "no binary at $BIN (run scripts/bundle.sh --release)" >&2; exit 1; }
# A shot-mode process is the only kind started here; refuse if this bundle is already running.
if pgrep -if -- "$BIN" >/dev/null 2>&1; then
  echo "$APP is already running; quit it first (this script never touches it)" >&2
  exit 1
fi

mkdir -p "$OUT" "$TOOLS"
if [ ! -x "$TOOLS/winlist" ] || [ "$REPO/scripts/winlist.swift" -nt "$TOOLS/winlist" ]; then
  swiftc -O "$REPO/scripts/winlist.swift" -o "$TOOLS/winlist"
fi
: >"$LOG"

# The frontmost app as "asn name" on one line.
front() {
  local asn name
  asn="$(lsappinfo front 2>/dev/null || true)"
  name="$(lsappinfo info -only name "$asn" 2>/dev/null | head -1 || true)"
  echo "$asn $name"
}

PID=""
HOME_DIR=""

pid_running() {
  local state
  state="$(ps -o stat= -p "$1" 2>/dev/null | cut -c1 || true)"
  [ -n "$state" ] && [ "$state" != Z ]
}

stop_app() {
  if [ -n "$PID" ]; then
    if pid_running "$PID"; then
      kill -TERM "$PID" 2>/dev/null || true
      for _ in $(seq 1 25); do
        pid_running "$PID" || break
        sleep 0.2
      done
      if pid_running "$PID"; then kill -KILL "$PID" 2>/dev/null || true; fi
    fi
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
}

remove_home() {
  case "$HOME_DIR" in
    "$TMP_ROOT"/snap-shots.?*) [ -d "$HOME_DIR" ] && rm -rf -- "$HOME_DIR" ;;
  esac
  HOME_DIR=""
}

cleanup() {
  stop_app
  remove_home
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

shoot() { # scenario appearance
  local scn="$1" mode="$2" before after rc=0 windows="" deadline out="$OUT/$1-$2.png"
  local args=(--shot "$scn" --appearance "$mode" --out "$out")
  HOME_DIR="$(mktemp -d "$TMP_ROOT/snap-shots.XXXXXX")"
  rm -f -- "$out"
  before="$(front)"

  SNAP_HOME="$HOME_DIR" "$BIN" "${args[@]}" >>"$LOG" 2>&1 &
  PID=$!
  local launched_pid="$PID"
  deadline=$(($(date +%s) + TIMEOUT_SECONDS))
  while pid_running "$PID"; do
    if ! "$TOOLS/winlist" "$PID" >"$HOME_DIR/windows.txt" 2>/dev/null; then
      windows="$(cat "$HOME_DIR/windows.txt")"
      break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "timeout after ${TIMEOUT_SECONDS} s for $scn/$mode" >&2
      break
    fi
    sleep 0.1
  done
  if [ -z "$windows" ] && ! pid_running "$PID"; then
    wait "$PID" || rc=$?
  else
    rc=1
  fi
  stop_app
  after="$(front)"
  echo "$scn $mode pid=$launched_pid rc=$rc before=[$before] after=[$after]" >>"$LOG"
  remove_home

  if [ -n "$windows" ]; then
    echo "an on-screen window appeared for $scn/$mode (pid $launched_pid): $windows" >&2
    exit 4
  fi
  if [ "$before" != "$after" ]; then
    echo "frontmost app changed during $scn/$mode: [$before] -> [$after] (pid $launched_pid)" >&2
    exit 3
  fi
  if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
    echo "shot failed for $scn/$mode (exit $rc), see $LOG" >&2
    exit 1
  fi
  echo "ok $scn-$mode $(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}')"
}

for s in "${SCENARIOS[@]}"; do
  for a in light dark; do
    shoot "$s" "$a"
  done
done
echo "log: $LOG"
