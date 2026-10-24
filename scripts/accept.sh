#!/usr/bin/env bash
# Snap milestone 1 acceptance runner.
#
#   scripts/accept.sh offline [AC02 AC05 ...]
#
# With criterion ids after the group, only those run (for iterating on one criterion); the full
# acceptance is the group alone.
# Prints PASS, FAIL or SKIP for each criterion id and exits 1 on any FAIL. Everything runs
# headless: no window, no focus change, no screen capture, no permission prompt, no sound, no
# network. Every snapctl and Snap process gets a fresh SNAP_HOME below the run folder.
#
#   AC01  All gates green: SNAP_SCRATCH=$TMPDIR/snap-check scripts/check.sh exits 0 (release build,
#         swift test with a fresh SNAP_HOME, swiftlint --strict including the ScreenCaptureKit
#         rule, otool -L shows snapctl and snapbench do not link ScreenCaptureKit, bundle.sh --release,
#         codesign --verify --strict, plutil -lint with CFBundleIdentifier dev.sdusteric.snap and
#         LSUIElement true, codesign -d -r- names identifier "dev.sdusteric.snap" and
#         "Apple Development", no em or en dashes).
#   AC02  Beautify matches the preset geometry: snapctl preset --default --json prints padding 21,
#         inset 21, cornerRadius 0.12, shadow 32, alignment 4, autoBalance true. gen-fixture plus
#         beautify --report give noise-2x 1256x856, block-2x 712x512 (auto-balance), 1312x912
#         (without), 910x512 (ratio 16:9). On block-2x with background solid:#F5F5F7, measured with
#         shot-stats: the pixel 1 px inside the card's top-left corner is not red; an 8 px band
#         below the card is at least 8/255 darker than the background at shadow 32 and within
#         2/255 at shadow 0; the red content's left/right and top/bottom margins match within 1 px.
#   AC03  swift test output has a passing suite, and no failure, for each of SelectionGeometryTests,
#         WindowHitTesterTests, CoordinateSpaceTests, FileNamerTests, QuickAccessStackTests,
#         HotkeyConflictTests, PermissionStateTests, AnnotationModelTests, BeautifyRendererTests
#         and CaptureCoordinatorTests. A missing suite is a FAIL.
#   AC04  scripts/shots.sh makes 12 PNGs in build/shots (overlay-area, quick-access,
#         background-editor, annotate, menu, settings, light and dark) at 2x their point sizes,
#         each with luminance stddev at least 4, each light/dark pair at least 40/255 apart in
#         mean luminance of its chrome region; shots.sh exits 0, so lsappinfo front never changed
#         and winlist never saw an on-screen window of the shot PID.
#   AC05  snapbench latency --fake --runs 50 --display 5120x2880@2 --capture-delay-ms 0 --json
#         (the real OverlayController and QuickAccessController without panels): p95 under
#         20 ms to overlay present, under 30 ms to frozen ready, under 30 ms from confirm to
#         card, and every run in the order present, frozen, confirm, card, then encode,
#         history, clipboard.
#
# Env: SNAP_SCRATCH  SwiftPM scratch path (default <repo>/.build), e.g. $TMPDIR/snap-check
#
# Every run uses build/accept/<timestamp>. The real Snap data folder, ~/Downloads and the real
# pasteboard are never touched. Every process this script starts is stopped by PID on exit.

# shellcheck source=scripts/accept-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/accept-lib.sh"

usage() {
  sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

GROUP=${1:-}
shift 2>/dev/null || true
ONLY="$*"
case "$GROUP" in
  offline) ;;
  *)
    usage
    exit 2
    ;;
esac

clear_snap_env

SCRATCH="${SNAP_SCRATCH:-$REPO/.build}"
export SNAP_SCRATCH="$SCRATCH"
APP="$REPO/build/bundle/Snap.app"
TOOLS="$REPO/build/shots/bin"
STATS="$TOOLS/shot-stats"

echo "Snap acceptance, group: $GROUP"
echo "Run folder: $RUN"
echo "Scratch: $SCRATCH"

# Keep the Mac from idle sleep while the run lasts.
/usr/bin/caffeinate -i -w $$ &
track_pid $!

shot_stats_tool() {
  mkdir -p "$TOOLS"
  if [ ! -x "$STATS" ] || [ "$REPO/scripts/shot-stats.swift" -nt "$STATS" ]; then
    swiftc -O "$REPO/scripts/shot-stats.swift" -o "$STATS" >"$RUN/shot-stats-build.log" 2>&1
  fi
  [ -x "$STATS" ]
}

# ---------------------------------------------------------------------------------------------
# AC01
# ---------------------------------------------------------------------------------------------

ac01() {
  if run_logged check env SNAP_SCRATCH="$SCRATCH" "$REPO/scripts/check.sh"; then
    pass AC01 "scripts/check.sh exits 0 ($(tail -1 "$LAST_LOG"))"
  else
    fail AC01 "scripts/check.sh failed, see $LAST_LOG"
  fi
}

# ---------------------------------------------------------------------------------------------
# snapctl
# ---------------------------------------------------------------------------------------------

BIN_DIR=""
snapctl_path() {
  if [ -z "$BIN_DIR" ]; then
    BIN_DIR="$(swift build -c release --package-path "$REPO" --scratch-path "$SCRATCH" --show-bin-path 2>/dev/null || true)"
  fi
  if [ ! -x "$BIN_DIR/snapctl" ]; then
    run_logged build-snapctl caffeinate -i swift build -c release --product snapctl \
      --package-path "$REPO" --scratch-path "$SCRATCH" >/dev/null 2>&1 || true
  fi
  echo "$BIN_DIR/snapctl"
}

bench_path() {
  local dir
  dir="$(swift build -c release --package-path "$REPO" --scratch-path "$SCRATCH" --show-bin-path 2>/dev/null || true)"
  if [ ! -x "$dir/snapbench" ]; then
    run_logged build-snapbench caffeinate -i swift build -c release --product snapbench \
      --package-path "$REPO" --scratch-path "$SCRATCH" >/dev/null 2>&1 || true
  fi
  echo "$dir/snapbench"
}

# run_ctl <name> <args...>: snapctl with a fresh SNAP_HOME. Standard output goes to
# $RUN/<name>.out, standard error to $RUN/<name>.err.
run_ctl() {
  local name=$1 home rc
  shift
  home="$(fresh_home)"
  SNAP_HOME="$home" "$CTL" "$@" >"$RUN/$name.out" 2>"$RUN/$name.err"
  rc=$?
  remove_run_path "$home"
  return $rc
}

# ---------------------------------------------------------------------------------------------
# AC02
# ---------------------------------------------------------------------------------------------

# Field n (1-based) of shot-stats for a region of a PNG.
stat_field() { # field png [x y w h]
  local field=$1
  shift
  "$STATS" "$@" 2>/dev/null | awk -v f="$field" '{print $f}'
}

# True when the pixel at x y is the fixture's red.
is_red() { # png x y
  "$STATS" "$1" "$2" "$3" 1 1 2>/dev/null | awk '{ exit !($7 > 200 && $8 < 80 && $9 < 80) }'
}

# The first red x on row y, scanning from 0 toward the red centre cx (binary search).
first_red_x() { # png y cx
  local png=$1 y=$2 lo=0 hi=$3 mid
  while [ $((hi - lo)) -gt 1 ]; do
    mid=$(((lo + hi) / 2))
    if is_red "$png" "$mid" "$y"; then hi=$mid; else lo=$mid; fi
  done
  echo "$hi"
}

last_red_x() { # png y cx width
  local png=$1 y=$2 lo=$3 hi=$(($4 - 1)) mid
  while [ $((hi - lo)) -gt 1 ]; do
    mid=$(((lo + hi) / 2))
    if is_red "$png" "$mid" "$y"; then lo=$mid; else hi=$mid; fi
  done
  echo "$lo"
}

first_red_y() { # png x cy
  local png=$1 x=$2 lo=0 hi=$3 mid
  while [ $((hi - lo)) -gt 1 ]; do
    mid=$(((lo + hi) / 2))
    if is_red "$png" "$x" "$mid"; then hi=$mid; else lo=$mid; fi
  done
  echo "$hi"
}

last_red_y() { # png x cy height
  local png=$1 x=$2 lo=$3 hi=$(($4 - 1)) mid
  while [ $((hi - lo)) -gt 1 ]; do
    mid=$(((lo + hi) / 2))
    if is_red "$png" "$x" "$mid"; then lo=$mid; else hi=$mid; fi
  done
  echo "$lo"
}

# A value from a JSON report: json_get <file> <python expression on d>.
json_get() {
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null
}

ac02() {
  local dir="$RUN/ac02" problems="" lines="" spec name input expected flags size png_size
  mkdir -p "$dir"

  # The first-run default preset.
  if run_ctl ac02-preset preset --default --json; then
    local preset
    preset="$(python3 -I -c '
import json, sys
p = json.load(open(sys.argv[1]))
want = {"padding": 21, "inset": 21, "cornerRadius": 0.12, "shadow": 32, "alignment": 4, "autoBalance": True}
bad = [k for k, v in want.items() if p.get(k) != v]
print("preset " + ", ".join("%s %s" % (k, json.dumps(p.get(k))) for k in want) + (" [wrong: " + ", ".join(bad) + "]" if bad else ""))
sys.exit(1 if bad else 0)
' "$RUN/ac02-preset.out" 2>&1)" || problems="$problems [$preset]"
    lines="$lines $preset;"
  else
    problems="$problems [snapctl preset failed, see $RUN/ac02-preset.err]"
  fi

  for name in noise-2x block-2x; do
    run_ctl "ac02-fixture-$name" gen-fixture "$name" --out "$dir/$name.png" \
      || problems="$problems [gen-fixture $name failed]"
  done

  # Output sizes: name|input|expected|flags
  for spec in "noise|noise-2x|1256x856|" "block|block-2x|712x512|" "block-noab|block-2x|1312x912|--no-autobalance" \
    "block-16x9|block-2x|910x512|--ratio 16:9"; do
    IFS='|' read -r name input expected flags <<<"$spec"
    # shellcheck disable=SC2086
    if run_ctl "ac02-$name" beautify "$dir/$input.png" --out "$dir/$name.png" $flags --report; then
      cp "$RUN/ac02-$name.out" "$dir/$name.json"
      size="$(json_get "$dir/$name.json" '"%dx%d" % (d["canvasSize"]["width"], d["canvasSize"]["height"])')"
      png_size="$(stat_field 1 "$dir/$name.png")x$(stat_field 2 "$dir/$name.png")"
      lines="$lines $input${flags:+ $flags} $png_size;"
      if [ "$size" != "$expected" ] || [ "$png_size" != "$expected" ]; then
        problems="$problems [$input${flags:+ $flags}: report $size, png $png_size, expected $expected]"
      fi
    else
      problems="$problems [beautify $input $flags failed, see $RUN/ac02-$name.err]"
    fi
  done

  # Pixel checks on block-2x over #F5F5F7 at shadow 32 and shadow 0.
  local zero_preset s32="$dir/solid-s32.png" s0="$dir/solid-s0.png"
  zero_preset="$(python3 -I -c 'import json, sys; p = json.load(open(sys.argv[1])); p["shadow"] = 0; print(json.dumps(p))' \
    "$RUN/ac02-preset.out" 2>/dev/null)"
  if run_ctl ac02-s32 beautify "$dir/block-2x.png" --out "$s32" --background 'solid:#F5F5F7' --report \
    && run_ctl ac02-s0 beautify "$dir/block-2x.png" --out "$s0" --background 'solid:#F5F5F7' --preset "$zero_preset" --report; then
    cp "$RUN/ac02-s32.out" "$dir/solid-s32.json"
    cp "$RUN/ac02-s0.out" "$dir/solid-s0.json"
    local cx cy cw ch bg corner band32 band0 dark32 diff0 w h midx midy left right top bottom
    cx="$(json_get "$dir/solid-s32.json" 'd["cardRect"]["x"]')"
    cy="$(json_get "$dir/solid-s32.json" 'd["cardRect"]["y"]')"
    cw="$(json_get "$dir/solid-s32.json" 'd["cardRect"]["width"]')"
    ch="$(json_get "$dir/solid-s32.json" 'd["cardRect"]["height"]')"
    # Rec. 709 luminance of #F5F5F7, as shot-stats computes it.
    bg="$(awk 'BEGIN { printf "%.2f", 0.2126 * 245 + 0.7152 * 245 + 0.0722 * 247 }')"

    corner="$("$STATS" "$s32" $((cx + 1)) $((cy + 1)) 1 1 | awk '{printf "rgb(%.0f, %.0f, %.0f)", $7, $8, $9}')"
    if is_red "$s32" $((cx + 1)) $((cy + 1)); then
      problems="$problems [corner pixel is red: $corner]"
    fi
    lines="$lines corner $corner;"

    band32="$(stat_field 3 "$s32" "$cx" $((cy + ch)) "$cw" 8)"
    band0="$(stat_field 3 "$s0" "$cx" $((cy + ch)) "$cw" 8)"
    dark32="$(awk -v b="$bg" -v v="$band32" 'BEGIN { printf "%.2f", b - v }')"
    diff0="$(awk -v b="$bg" -v v="$band0" 'BEGIN { d = b - v; if (d < 0) d = -d; printf "%.2f", d }')"
    lines="$lines band below card: shadow 32 is $dark32/255 darker, shadow 0 differs by $diff0/255;"
    awk -v d="$dark32" 'BEGIN { exit !(d >= 8) }' || problems="$problems [shadow 32 band only $dark32/255 darker]"
    awk -v d="$diff0" 'BEGIN { exit !(d <= 2) }' || problems="$problems [shadow 0 band differs by $diff0/255]"

    w="$(stat_field 1 "$s32")"
    h="$(stat_field 2 "$s32")"
    midx=$((w / 2))
    midy=$((h / 2))
    if is_red "$s32" "$midx" "$midy" && ! is_red "$s32" 0 "$midy" && ! is_red "$s32" $((w - 1)) "$midy"; then
      left="$(first_red_x "$s32" "$midy" "$midx")"
      right=$((w - 1 - $(last_red_x "$s32" "$midy" "$midx" "$w")))
      top="$(first_red_y "$s32" "$midx" "$midy")"
      bottom=$((h - 1 - $(last_red_y "$s32" "$midx" "$midy" "$h")))
      lines="$lines red margins left $left right $right top $top bottom $bottom"
      awk -v a="$left" -v b="$right" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 1) }' \
        || problems="$problems [left $left vs right $right]"
      awk -v a="$top" -v b="$bottom" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 1) }' \
        || problems="$problems [top $top vs bottom $bottom]"
    else
      problems="$problems [red content not found in the middle of $s32]"
    fi
  else
    problems="$problems [beautify over solid:#F5F5F7 failed, see $RUN/ac02-s32.err and $RUN/ac02-s0.err]"
  fi

  if [ -n "$problems" ]; then
    fail AC02 "beautify geometry:$problems;$lines"
  else
    pass AC02 "beautify geometry:$lines"
  fi
}

# ---------------------------------------------------------------------------------------------
# AC03
# ---------------------------------------------------------------------------------------------

REQUIRED_SUITES="SelectionGeometryTests WindowHitTesterTests CoordinateSpaceTests FileNamerTests QuickAccessStackTests HotkeyConflictTests PermissionStateTests AnnotationModelTests BeautifyRendererTests CaptureCoordinatorTests"

ac03() {
  local log="$REPO/build/check/test.log" suite problems="" n=0 summary
  # check.sh just ran swift test; use its log when it is from this run, else run the tests here.
  if [ ! -f "$log" ] || [ ! "$log" -nt "$RUN/ac01.start" ]; then
    local home
    home="$(fresh_home)"
    SNAP_HOME="$home" run_logged swift-test \
      caffeinate -i swift test --package-path "$REPO" --scratch-path "$SCRATCH" || true
    remove_run_path "$home"
    log="$RUN/swift-test.log"
  fi
  if grep -q '^✘' "$log"; then
    problems="$problems [a test or suite failed: $(grep '^✘' "$log" | head -3 | tr '\n' ' ')]"
  fi
  for suite in $REQUIRED_SUITES; do
    if grep -qE "^✘ Suite \"?$suite\"? failed" "$log"; then
      problems="$problems [$suite failed]"
    elif grep -qE "^✔ Suite \"?$suite\"? passed" "$log"; then
      n=$((n + 1))
    else
      problems="$problems [$suite missing]"
    fi
  done
  summary="$(grep -E '^[✔✘] Test run with' "$log" | tail -1 || true)"
  case "$summary" in
    "✔ Test run with"*) ;;
    *) problems="$problems [no passing test run summary]" ;;
  esac
  if [ -n "$problems" ]; then
    fail AC03 "suites:$problems"
  else
    pass AC03 "$n required suites passed; ${summary#✔ }"
  fi
}

# ---------------------------------------------------------------------------------------------
# AC04
# ---------------------------------------------------------------------------------------------

# scenario|pixel size at 2x|chrome region in pixels (x y w h, top-left origin)
# The regions: the overlay's selection cut-out, the Quick Access card column, the Background
# editor's sidebar, the annotate toolbar, the menu body and the settings form. If a layout
# moves, the light and dark regions stop differing and this criterion fails, not passes.
SHOT_SPECS="overlay-area|2560x1600|740 460 1240 760
quick-access|1200x1520|32 320 512 1168
background-editor|1840x1280|1240 0 600 1180
annotate|2200x1440|0 0 2200 104
menu|560x1000|0 16 560 840
settings|960x1380|0 0 960 1380"

ac04() {
  local before after rc=0 problems="" lines="" scn size region mode f width height deviation light dark diff count=0
  if [ ! -x "$APP/Contents/MacOS/Snap" ]; then
    run_logged bundle env SNAP_SCRATCH="$SCRATCH" "$REPO/scripts/bundle.sh" --release || true
  fi
  before="$(front)"
  run_logged shots "$REPO/scripts/shots.sh"
  rc=$?
  after="$(front)"
  if [ $rc -ne 0 ]; then
    case $rc in
      3) problems="$problems [frontmost app changed]" ;;
      4) problems="$problems [an on-screen window appeared]" ;;
      *) problems="$problems [shots.sh exit $rc, see $LAST_LOG]" ;;
    esac
  fi
  if [ "$before" != "$after" ]; then
    problems="$problems [lsappinfo front changed: $before -> $after]"
  fi
  while IFS='|' read -r scn size region; do
    for mode in light dark; do
      f="$REPO/build/shots/$scn-$mode.png"
      if [ ! -s "$f" ]; then
        problems="$problems [missing $scn-$mode.png]"
        continue
      fi
      width="$(stat_field 1 "$f")"
      height="$(stat_field 2 "$f")"
      deviation="$(stat_field 4 "$f")"
      if [ "${width}x${height}" != "$size" ]; then
        problems="$problems [$scn-$mode is ${width:-?}x${height:-?}, expected $size]"
      elif ! awk -v d="${deviation:-0}" 'BEGIN { exit !(d >= 4) }'; then
        problems="$problems [$scn-$mode is blank, stddev ${deviation:-0}]"
      else
        count=$((count + 1))
      fi
    done
    # shellcheck disable=SC2086
    light="$(stat_field 3 "$REPO/build/shots/$scn-light.png" $region)"
    # shellcheck disable=SC2086
    dark="$(stat_field 3 "$REPO/build/shots/$scn-dark.png" $region)"
    if [ -z "$light" ] || [ -z "$dark" ]; then
      problems="$problems [no chrome stats for $scn]"
      continue
    fi
    diff="$(awk -v a="$light" -v b="$dark" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.1f", d }')"
    lines="$lines $scn $diff;"
    if ! awk -v d="$diff" 'BEGIN { exit !(d >= 40) }'; then
      problems="$problems [$scn chrome light/dark differ by only $diff/255]"
    fi
  done <<<"$SHOT_SPECS"
  if [ -n "$problems" ]; then
    fail AC04 "screenshots:$problems"
  else
    pass AC04 "$count PNGs at 2x, not blank, frontmost unchanged, no window; light/dark chrome diff:$lines"
  fi
}

# ---------------------------------------------------------------------------------------------
# AC05
# ---------------------------------------------------------------------------------------------

ac05() {
  local out bench home rc
  bench="$(bench_path)"
  if [ ! -x "$bench" ]; then
    fail AC05 "no snapbench at $bench"
    return
  fi
  home="$(fresh_home)"
  SNAP_HOME="$home" "$bench" latency --fake --runs 50 --display 5120x2880@2 --capture-delay-ms 0 --json \
    >"$RUN/ac05-latency.out" 2>"$RUN/ac05-latency.err"
  rc=$?
  remove_run_path "$home"
  if [ $rc -ne 0 ]; then
    fail AC05 "snapbench latency failed, see $RUN/ac05-latency.err"
    return
  fi
  cp "$RUN/ac05-latency.out" "$RUN/latency.json"
  if out="$(python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1]))
limits = {"present": 20.0, "frozen": 30.0, "card": 30.0}
expected = ["present", "frozen", "confirm", "card", "encode", "history", "clipboard"]
problems, parts = [], []
for stage, limit in limits.items():
    p95 = ((r.get("stages") or {}).get(stage) or {}).get("p95Ms")
    parts.append("%s p95 %s ms (limit %g)" % (stage, "none" if p95 is None else "%.3f" % p95, limit))
    if p95 is None or not p95 < limit:
        problems.append(stage + " over limit")
runs = r.get("runDetails") or []
bad = [d.get("run") for d in runs if d.get("order") != expected]
parts.append("%d runs, %d out of order" % (len(runs), len(bad)))
if len(runs) != 50:
    problems.append("expected 50 runs")
if bad:
    problems.append("wrong event order in runs %s" % bad[:5])
print(", ".join(parts) + ("  [" + "; ".join(problems) + "]" if problems else ""))
sys.exit(1 if problems else 0)
' "$RUN/latency.json" 2>&1)"; then
    pass AC05 "$out"
  else
    fail AC05 "$out"
  fi
}

# ---------------------------------------------------------------------------------------------
# offline
# ---------------------------------------------------------------------------------------------

# wanted <id>: true when the criterion runs in this invocation.
wanted() {
  [ -z "$ONLY" ] && return 0
  case " $ONLY " in *" $1 "*) return 0 ;; esac
  return 1
}

group_offline() {
  echo
  echo "== offline"
  : >"$RUN/ac01.start"
  if wanted AC01; then ac01; fi
  if ! shot_stats_tool; then
    if wanted AC02; then fail AC02 "cannot build shot-stats, see $RUN/shot-stats-build.log"; fi
    if wanted AC03; then ac03; fi
    if wanted AC04; then fail AC04 "cannot build shot-stats, see $RUN/shot-stats-build.log"; fi
  else
    CTL="$(snapctl_path)"
    if wanted AC02; then
      if [ -x "$CTL" ]; then ac02; else fail AC02 "no snapctl at $CTL"; fi
    fi
    if wanted AC03; then ac03; fi
    if wanted AC04; then ac04; fi
  fi
  if wanted AC05; then ac05; fi
}

CTL=""
group_offline

echo
FAILS="$(awk -F'\t' '$2 == "FAIL"' "$RESULTS" | wc -l | tr -d ' ')"
PASSES="$(awk -F'\t' '$2 == "PASS"' "$RESULTS" | wc -l | tr -d ' ')"
echo "Results: $RESULTS ($PASSES PASS, $FAILS FAIL)"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
