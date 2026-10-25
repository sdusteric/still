#!/usr/bin/env bash
# All gates (design section 16). Exits 0 only when every gate passes.
#   swift build -c release -> swift test -> swiftlint --strict -> snapctl and snapbench do not
#   link ScreenCaptureKit -> snapctl and snapbench do not link Sparkle -> scripts/bundle.sh
#   --release -> codesign --verify --deep --strict -> plutil -lint, bundle id, LSUIElement and the
#   microphone usage string ->
#   Sparkle in the bundle (framework, feed, key, @rpath link) -> designated requirement -> no em
#   or en dashes
#
# Env: SNAP_SCRATCH  SwiftPM scratch path (default <repo>/.build). Agents building in parallel
#                    pass their own, e.g. SNAP_SCRATCH=$TMPDIR/snap-check.
# Logs: build/check/<gate>.log. Tests run with a fresh SNAP_HOME from mktemp, removed on exit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${SNAP_SCRATCH:-$ROOT/.build}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
LOGDIR="$ROOT/build/check"
mkdir -p "$LOGDIR"

TMP_BASE="${TMPDIR:-/tmp}"
TMP_HOME="$(mktemp -d "${TMP_BASE%/}/snap-check-home.XXXXXX")"
cleanup() { [ -n "${TMP_HOME:-}" ] && [ -d "$TMP_HOME" ] && rm -rf "$TMP_HOME"; }
trap cleanup EXIT
export SNAP_HOME="$TMP_HOME"
# Sparkle never starts under the gates (app-updates CONTRACT.md).
export SNAP_NO_UPDATES=1

BUNDLE_ID="dev.sdusteric.snap"
# Design D79.
MIC_USAGE="Snap records your microphone only during a screen recording you start with the microphone turned on."
APP="$ROOT/build/bundle/Snap.app"
# app-updates CONTRACT.md
FEED_URL="https://sdusteric.github.io/app-updates/snap/appcast.xml"
ED_KEY="PMaW+8sZRzOkfIwy1KBGk0CHTVoN49FE9o8gUlNGdZc="

gate() { # gate <name> <command...>: runs the command, output to build/check/<name>.log
  local name="$1"; shift
  local log="$LOGDIR/$name.log"
  local t0; t0=$(date +%s)
  printf '%-15s ' "$name"
  if "$@" >"$log" 2>&1; then
    echo "ok ($(( $(date +%s) - t0 )) s)"
  else
    echo "FAIL ($(( $(date +%s) - t0 )) s), log: $log"
    tail -40 "$log"
    exit 1
  fi
}

build_release() {
  caffeinate -i swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH"
}

run_tests() {
  local status=0
  caffeinate -i swift test --package-path "$ROOT" --scratch-path "$SCRATCH" || status=$?
  [ "$status" = 0 ] || return "$status"
  # Swift Testing marks a failure with a cross; XCTest prints "Test Case ... failed".
  if grep -qE '✘|Test Case .* failed' "$LOGDIR/test.log"; then
    echo "a test reported a failure"
    return 1
  fi
}

run_lint() {
  (cd "$ROOT" && swiftlint lint --strict --quiet)
}

snapctl_no_sck() {
  local dir bin name linked
  dir="$(swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)"
  for name in snapctl snapbench; do
    bin="$dir/$name"
    [ -x "$bin" ] || { echo "missing $bin"; return 1; }
    linked="$(otool -L "$bin")"
    echo "$linked"
    if grep -q ScreenCaptureKit <<<"$linked"; then echo "$name links ScreenCaptureKit"; return 1; fi
    echo "$name does not link ScreenCaptureKit"
  done
}

cli_no_sparkle() {
  local dir bin name linked
  dir="$(swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)"
  for name in snapctl snapbench; do
    bin="$dir/$name"
    [ -x "$bin" ] || { echo "missing $bin"; return 1; }
    linked="$(otool -L "$bin")"
    if grep -qi sparkle <<<"$linked"; then echo "$linked"; echo "$name links Sparkle"; return 1; fi
    echo "$name does not link Sparkle"
  done
}

bundle_app() {
  SNAP_SCRATCH="$SCRATCH" caffeinate -i "$ROOT/scripts/bundle.sh" --release
}

codesign_check() {
  codesign --verify --deep --strict --verbose=2 "$APP"
}

plist_check() {
  local plist="$APP/Contents/Info.plist" id ui mic
  plutil -lint "$plist" || return 1
  id="$(plutil -extract CFBundleIdentifier raw -o - "$plist")"
  [ "$id" = "$BUNDLE_ID" ] || { echo "bundle id is $id"; return 1; }
  ui="$(plutil -extract LSUIElement raw -o - "$plist")"
  [ "$ui" = true ] || { echo "LSUIElement is $ui"; return 1; }
  mic="$(plutil -extract NSMicrophoneUsageDescription raw -o - "$plist" 2>/dev/null || true)"
  [ "$mic" = "$MIC_USAGE" ] || { echo "NSMicrophoneUsageDescription is '$mic', expected '$MIC_USAGE'"; return 1; }
  echo "CFBundleIdentifier $id, LSUIElement $ui, NSMicrophoneUsageDescription matches"
}

sparkle_check() {
  local plist="$APP/Contents/Info.plist" feed key linked
  [ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || { echo "Sparkle.framework missing from the bundle"; return 1; }
  feed="$(plutil -extract SUFeedURL raw -o - "$plist" 2>/dev/null || true)"
  [ "$feed" = "$FEED_URL" ] || { echo "SUFeedURL is '$feed', expected $FEED_URL"; return 1; }
  key="$(plutil -extract SUPublicEDKey raw -o - "$plist" 2>/dev/null || true)"
  [ "$key" = "$ED_KEY" ] || { echo "SUPublicEDKey is '$key', expected $ED_KEY"; return 1; }
  linked="$(otool -L "$APP/Contents/MacOS/Snap")"
  grep -q '@rpath/Sparkle.framework' <<<"$linked" || { echo "$linked"; echo "Snap does not link @rpath/Sparkle.framework"; return 1; }
  otool -l "$APP/Contents/MacOS/Snap" | grep -q 'path @executable_path/../Frameworks ' \
    || { echo "Snap lacks rpath @executable_path/../Frameworks"; return 1; }
  echo "Sparkle.framework bundled, SUFeedURL $feed, SUPublicEDKey matches, Snap links @rpath/Sparkle.framework"
}

requirement_check() {
  local requirement
  requirement="$(codesign -d -r- "$APP" 2>&1)"
  echo "$requirement"
  grep -q "identifier \"$BUNDLE_ID\"" <<<"$requirement" || { echo "designated requirement lacks $BUNDLE_ID"; return 1; }
  grep -q 'Apple Development' <<<"$requirement" || { echo "designated requirement lacks Apple Development"; return 1; }
}

dash_check() {
  # Swift files are covered by swiftlint; this covers prose, scripts and resources.
  local paths=() path hits
  for path in docs scripts resources CLAUDE.md README.md Package.swift .swiftlint.yml .gitignore; do
    [ -e "$ROOT/$path" ] && paths+=("$ROOT/$path")
  done
  hits="$(LC_ALL=C grep -rnIE $'\xe2\x80\x93|\xe2\x80\x94' "${paths[@]}" || true)"
  if [ -n "$hits" ]; then echo "$hits"; echo "em or en dash found"; return 1; fi
  echo "no em or en dashes in ${#paths[@]} paths"
}

T0=$(date +%s)
gate build build_release
gate test run_tests
gate lint run_lint
gate snapctl-no-sck snapctl_no_sck
gate cli-no-sparkle cli_no_sparkle
gate bundle bundle_app
gate codesign codesign_check
gate plist plist_check
gate sparkle sparkle_check
gate requirement requirement_check
gate dashes dash_check
echo "all gates passed ($(( $(date +%s) - T0 )) s)"
