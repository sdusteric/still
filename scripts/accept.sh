#!/usr/bin/env bash
# Snap acceptance runner: milestone 1 (group offline) and milestone 2 (group m2).
#
#   scripts/accept.sh offline [AC02 AC05 ...]
#   scripts/accept.sh m2 [AC-M2-4 AC-M2-10 ...]
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
# Group m2 runs AC-M2-1 to AC-M2-10 (docs/acceptance.md, M2 section). AC-M2-2 runs AC01 to AC05
# of group offline in the same run and passes when all five print PASS; AC-M2-1 reuses AC01's
# check.sh run. Every measured number is printed, also for a PASS.
#
# Env: SNAP_SCRATCH  SwiftPM scratch path (default <repo>/.build), e.g. $TMPDIR/snap-check
#
# Every run uses build/accept/<timestamp>. The real Snap data folder, ~/Downloads and the real
# pasteboard are never touched. Every process this script starts is stopped by PID on exit.

# shellcheck source=scripts/accept-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/accept-lib.sh"

usage() {
  sed -n '2,49p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

GROUP=${1:-}
shift 2>/dev/null || true
ONLY="$*"
case "$GROUP" in
  offline | m2) ;;
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

# ---------------------------------------------------------------------------------------------
# Group m2 (design section 20, docs/acceptance.md "Milestone 2")
# ---------------------------------------------------------------------------------------------

M2_SCENARIOS="pin history history-empty hud recording-countdown recording quick-access-video annotate-tools background-mesh settings-recording menu-m2"
M2_SUITES="PinBoardTests HistoryStoreV2Tests HistoryQueryTests AllInOneStateTests SettingsMigrationTests RecordingPlanTests RecordingControllerTests VideoProbeTests AnnotationM2Tests MeshGradientTests BlurredBackgroundTests PinControllerTests HistoryWindowModelTests QuickAccessVideoCardTests AllInOneToolbarTests"
MIC_USAGE="Snap records your microphone only during a screen recording you start with the microphone turned on."
REGIONS="$REPO/docs/mockup/m2/regions.tsv"
CHECK_RAN=0

# The status AC01 recorded in this run, empty when it did not run.
result_of() {
  awk -F'\t' -v id="$1" '$1 == id { s = $2 } END { print s }' "$RESULTS"
}

# run_ctl_in <home> <name> <args...>: snapctl with the given SNAP_HOME, which the caller keeps
# until its checks are done. Output to $RUN/<name>.out and .err.
run_ctl_in() {
  local home=$1 name=$2
  shift 2
  SNAP_HOME="$home" SNAP_NO_UPDATES=1 "$CTL" "$@" >"$RUN/$name.out" 2>"$RUN/$name.err"
}

# A python3 check: py <name> <script> <args...>. The script prints the measured numbers and
# exits 1 on a problem.
py() {
  shift
  python3 -I -c "$@"
}

ensure_bundle() {
  if [ "$CHECK_RAN" = 1 ] && [ -x "$APP/Contents/MacOS/Snap" ]; then return 0; fi
  # Shots run the bundle; build it from the current sources unless check.sh just did.
  run_logged bundle-m2 env SNAP_SCRATCH="$SCRATCH" "$REPO/scripts/bundle.sh" --release
}

# ---------------------------------------------------------------------------------------------
# AC-M2-1
# ---------------------------------------------------------------------------------------------

acm2_1() {
  local problems="" lines="" status lint plist dir name linked
  status="$(result_of AC01)"
  case "$status" in
    PASS) lines="$lines check.sh exit 0 (every M1 and Sparkle gate);" ;;
    "") problems="$problems [check.sh did not run]" ;;
    *) problems="$problems [check.sh failed, see $RUN/check.log]" ;;
  esac
  # The lint rule must cover the recording APIs (design D75); check.sh ran swiftlint --strict.
  lint="$(awk '/screen_capture_only_in_system:/ { on = 1 } on && /regex:/ { print; exit }' "$REPO/.swiftlint.yml")"
  for name in SCStream SCRecordingOutput SCStreamConfiguration SCContentFilter AVCaptureDevice; do
    case "$lint" in
      *"\\b$name\\b"*) ;;
      *) problems="$problems [screen_capture_only_in_system does not cover $name]" ;;
    esac
  done
  if awk '/screen_capture_only_in_system:/ { on = 1 } on && /included:/ { print; exit }' "$REPO/.swiftlint.yml" \
    | grep -q 'SnapSystem'; then
    problems="$problems [screen_capture_only_in_system includes Sources/SnapSystem]"
  fi
  lines="$lines lint rule covers SCStream, SCRecordingOutput, SCStreamConfiguration, SCContentFilter, AVCaptureDevice outside SnapSystem;"
  plist="$(plutil -extract NSMicrophoneUsageDescription raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$plist" = "$MIC_USAGE" ]; then
    lines="$lines NSMicrophoneUsageDescription matches;"
  else
    problems="$problems [NSMicrophoneUsageDescription is '$plist']"
  fi
  dir="$(swift build -c release --package-path "$REPO" --scratch-path "$SCRATCH" --show-bin-path 2>/dev/null || true)"
  for name in snapctl snapbench; do
    if [ ! -x "$dir/$name" ]; then
      problems="$problems [no $name in $dir]"
      continue
    fi
    linked="$(otool -L "$dir/$name")"
    if grep -q ScreenCaptureKit <<<"$linked"; then problems="$problems [$name links ScreenCaptureKit]"; fi
    if grep -qi sparkle <<<"$linked"; then problems="$problems [$name links Sparkle]"; fi
  done
  lines="$lines otool -L: snapctl and snapbench link neither ScreenCaptureKit nor Sparkle;"
  if grep -q 'no em or en dashes' "$REPO/build/check/dashes.log" 2>/dev/null; then
    lines="$lines no em or en dashes"
  else
    problems="$problems [dash gate log missing or failing]"
  fi
  if [ -n "$problems" ]; then fail AC-M2-1 "gates:$problems;$lines"; else pass AC-M2-1 "$lines"; fi
}

# ---------------------------------------------------------------------------------------------
# AC-M2-2
# ---------------------------------------------------------------------------------------------

acm2_2() {
  local id status problems="" lines=""
  for id in AC01 AC02 AC03 AC04 AC05; do
    status="$(result_of "$id")"
    lines="$lines $id ${status:-missing};"
    [ "$status" = PASS ] || problems="$problems [$id ${status:-did not run}]"
  done
  if [ -n "$problems" ]; then fail AC-M2-2 "M1 criteria in this run:$problems;$lines"; else pass AC-M2-2 "M1 criteria in this run:$lines"; fi
}

# ---------------------------------------------------------------------------------------------
# AC-M2-3
# ---------------------------------------------------------------------------------------------

acm2_3() {
  local log="$REPO/build/check/test.log" list="$RUN/test-list.txt" problems="" lines="" suite n count home
  if [ ! -f "$log" ] || [ ! "$log" -nt "$RUN/ac01.start" ]; then
    home="$(fresh_home)"
    SNAP_HOME="$home" SNAP_NO_UPDATES=1 run_logged swift-test-m2 \
      caffeinate -i swift test --package-path "$REPO" --scratch-path "$SCRATCH" || true
    remove_run_path "$home"
    log="$RUN/swift-test-m2.log"
  fi
  # Test counts per suite come from the test list of the same build.
  home="$(fresh_home)"
  SNAP_HOME="$home" SNAP_NO_UPDATES=1 swift test list --skip-build --package-path "$REPO" --scratch-path "$SCRATCH" \
    >"$list" 2>"$RUN/test-list.err" || true
  remove_run_path "$home"
  if grep -q '✘' "$log"; then
    problems="$problems [failure marks in the log: $(grep '✘' "$log" | head -3 | tr '\n' ' ')]"
  fi
  if grep -qE 'Test Case .* failed' "$log"; then problems="$problems [an XCTest case failed]"; fi
  n=0
  for suite in $M2_SUITES; do
    count="$(grep -cE "^[A-Za-z]+Tests\.$suite/" "$list" 2>/dev/null)"
    count="${count:-0}"
    if grep -qE "^✘ Suite \"?$suite\"? failed" "$log"; then
      problems="$problems [$suite failed]"
    elif ! grep -qE "^✔ Suite \"?$suite\"? passed" "$log"; then
      problems="$problems [$suite missing]"
    elif [ "$count" -lt 3 ]; then
      problems="$problems [$suite has $count tests]"
    else
      n=$((n + 1))
    fi
    lines="$lines $suite $count;"
  done
  if ! grep -qE '^✔ Test run with' "$log"; then problems="$problems [no passing test run summary]"; fi
  if [ -n "$problems" ]; then
    fail AC-M2-3 "suites:$problems; tests per suite:$lines"
  else
    pass AC-M2-3 "$n required suites passed, tests per suite:$lines $(grep -E '^✔ Test run with' "$log" | tail -1 | sed 's/^✔ //')"
  fi
}

# ---------------------------------------------------------------------------------------------
# AC-M2-4
# ---------------------------------------------------------------------------------------------

# check_recording <record json> <probe json> <poster stats line> <expected codec> <w> <h> [audio]
check_recording() {
  py check-recording '
import json, sys
record = json.load(open(sys.argv[1]))
probe = json.load(open(sys.argv[2]))
poster = sys.argv[3].split()
codec, width, height = sys.argv[4], int(sys.argv[5]), int(sys.argv[6])
audio = int(sys.argv[7]) if len(sys.argv) > 7 and sys.argv[7] else None
item = json.load(open(record["itemFile"]))
problems = []
if item.get("kind") != "video": problems.append("kind %s" % item.get("kind"))
if item.get("state") != "complete": problems.append("state %s" % item.get("state"))
size = probe.get("pixelSize") or [probe.get("width"), probe.get("height")]
duration = probe.get("durationSeconds") or 0
frames = probe.get("frameCount") or 0
if probe.get("codec") != codec: problems.append("codec %s" % probe.get("codec"))
if list(size) != [width, height]: problems.append("size %s" % size)
if abs(duration - 3.0) > 0.05: problems.append("duration %.3f" % duration)
if abs(frames - 90) > 1: problems.append("frames %s" % frames)
if probe.get("playable") is not True: problems.append("not playable")
if audio is not None and probe.get("audioTrackCount") != audio: problems.append("audio tracks %s" % probe.get("audioTrackCount"))
pw, ph, pstd = int(poster[0]), int(poster[1]), float(poster[3])
if (pw, ph) != (width, height): problems.append("poster %dx%d" % (pw, ph))
if pstd < 4: problems.append("poster stddev %.2f" % pstd)
kinds = [e["kind"] for e in record.get("events", [])]
def at(kind): return kinds.index(kind) if kind in kinds else None
w, s, f = at("itemWritten"), at("started"), at("firstFrame")
if w is None or s is None or f is None or not (w < s and w < f): problems.append("event order %s" % kinds)
print("%s %s %s %dx%d %.3f s %d frames playable %s audio %s poster %dx%d stddev %.1f, itemWritten before started and firstFrame %s%s" % (
    item.get("kind"), item.get("state"), probe.get("codec"), size[0], size[1], duration, frames, probe.get("playable"),
    probe.get("audioTrackCount"), pw, ph, pstd, w is not None and s is not None and f is not None and w < s and w < f,
    "" if not problems else " [" + "; ".join(problems) + "]"))
sys.exit(1 if problems else 0)
' "$@"
}

# record_case <label> <expected codec> <w> <h> <audio tracks or empty> <snapctl record args...>
record_case() {
  local label=$1 codec=$2 width=$3 height=$4 audio=$5 home file out
  shift 5
  home="$(fresh_home)"
  if ! run_ctl_in "$home" "acm2-4-$label" record --fake "$@" --json; then
    echo "[$label: snapctl record failed, see $RUN/acm2-4-$label.err]"
    remove_run_path "$home"
    return 1
  fi
  file="$(json_get "$RUN/acm2-4-$label.out" 'd["file"]')"
  run_ctl_in "$home" "acm2-4-$label-probe" probe "$file" --json
  local poster
  poster="$("$STATS" "$(json_get "$RUN/acm2-4-$label.out" 'd["poster"]["path"]')" 2>/dev/null)"
  out="$(check_recording "$RUN/acm2-4-$label.out" "$RUN/acm2-4-$label-probe.out" "$poster" "$codec" "$width" "$height" "$audio" 2>&1)"
  local rc=$?
  remove_run_path "$home"
  echo "($label) $out"
  return $rc
}

acm2_4() {
  local problems="" lines="" out home area="--target area --display 2560x1440@2 --rect 330,150,640,400 --frames 90 --fps 30"
  # shellcheck disable=SC2086
  out="$(record_case a avc1 1280 800 "" $area)" || problems="$problems [a]"
  lines="$lines $out;"
  # shellcheck disable=SC2086
  out="$(record_case b hvc1 1280 800 "" $area --codec hevc)" || problems="$problems [b]"
  lines="$lines $out;"
  out="$(record_case c avc1 640 400 "" --target area --display 2560x1440@1 --rect 330,150,641,401 --frames 90 --fps 30)" \
    || problems="$problems [c]"
  lines="$lines $out;"
  # shellcheck disable=SC2086
  out="$(record_case d avc1 1280 800 1 $area --audio system,microphone)" || problems="$problems [d]"
  lines="$lines $out;"

  # (e) a killed recording, recovered, next to a complete one.
  home="$(fresh_home)"
  # shellcheck disable=SC2086
  run_ctl_in "$home" acm2-4-e-complete record --fake $area --json
  # shellcheck disable=SC2086
  run_ctl_in "$home" acm2-4-e-kill record --fake $area --kill-after-frames 30 --json
  run_ctl_in "$home" acm2-4-e-recover history recover --json
  run_ctl_in "$home" acm2-4-e-list history list --json
  local id file
  : >"$RUN/acm2-4-e-probes.txt"
  for file in $(python3 -I -c '
import json, sys
for item in json.load(open(sys.argv[1])).get("items", []):
    if item.get("state") == "complete" and item.get("kind") == "video": print(item["file"].replace(" ", "%20"))
' "$RUN/acm2-4-e-list.out" 2>/dev/null); do
    file="${file//%20/ }"
    SNAP_HOME="$home" SNAP_NO_UPDATES=1 "$CTL" probe "$file" --json >>"$RUN/acm2-4-e-probes.txt" 2>/dev/null
    echo >>"$RUN/acm2-4-e-probes.txt"
  done
  out="$(py e '
import json, sys
kill = json.load(open(sys.argv[1]))
recovered = json.load(open(sys.argv[2]))
listing = json.load(open(sys.argv[3]))
text = open(sys.argv[4]).read()
probes, decoder, index = [], json.JSONDecoder(), 0
while True:
    while index < len(text) and text[index].isspace(): index += 1
    if index >= len(text): break
    value, index = decoder.raw_decode(text, index)
    probes.append(value)
kid = kill.get("id")
states = {i["id"]: i.get("state") for i in listing.get("items", [])}
complete = [i for i in listing.get("items", []) if i.get("state") == "complete" and i.get("kind") == "video"]
unplayable = [p.get("file") for p in probes if p.get("playable") is not True]
problems = []
if kid not in (recovered.get("interrupted") or []): problems.append("recover did not mark %s" % kid)
if states.get(kid) != "interrupted": problems.append("killed item is %s" % states.get(kid))
if len(probes) != len(complete): problems.append("probed %d of %d complete items" % (len(probes), len(complete)))
if unplayable: problems.append("complete but unplayable: %s" % unplayable)
print("(e) killed item %s: %s after recover; %d complete videos listed, %d probe unplayable%s" % (
    kid, states.get(kid), len(complete), len(unplayable), "" if not problems else " [" + "; ".join(problems) + "]"))
sys.exit(1 if problems else 0)
' "$RUN/acm2-4-e-kill.out" "$RUN/acm2-4-e-recover.out" "$RUN/acm2-4-e-list.out" "$RUN/acm2-4-e-probes.txt" 2>&1)" \
    || problems="$problems [e]"
  remove_run_path "$home"
  lines="$lines $out;"

  # (f) the countdown in fake time, and Esc writing nothing.
  home="$(fresh_home)"
  # shellcheck disable=SC2086
  run_ctl_in "$home" acm2-4-f record --fake $area --countdown 3 --json
  # shellcheck disable=SC2086
  run_ctl_in "$home" acm2-4-f-esc record --fake $area --countdown 3 --press-esc --json
  local folders
  folders="$(find "$home/history" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  out="$(py f '
import json, sys
run = json.load(open(sys.argv[1]))
esc = json.load(open(sys.argv[2]))
folders = int(sys.argv[3])
events = run.get("events", [])
ticks = [e for e in events if e["kind"] == "countdownTick"]
first = [e for e in events if e["kind"] == "firstFrame"]
problems = []
labels = [t.get("detail") for t in ticks]
if labels != ["3", "2", "1"]: problems.append("ticks %s" % labels)
t0 = ticks[0]["time"] if ticks else 0
gaps = [ticks[i + 1]["time"] - ticks[i]["time"] for i in range(len(ticks) - 1)]
if any(abs(g - 1.0) > 0.010 for g in gaps): problems.append("gaps %s" % gaps)
ff = (first[0]["time"] - t0) if first else None
if ff is None or ff < 3.0: problems.append("firstFrame at %s" % ff)
if esc.get("outcome") != "cancelled": problems.append("Esc run outcome %s" % esc.get("outcome"))
if esc.get("historyFoldersAfter") != esc.get("historyFoldersBefore"): problems.append("Esc run wrote a folder")
if folders != 1: problems.append("%d history folders after both runs, expected 1" % folders)
print("(f) ticks %s at %s s, gaps %s s, firstFrame at %s s; Esc run %s, folders %s to %s, %d in history%s" % (
    labels, [round(t["time"] - t0, 3) for t in ticks], [round(g, 3) for g in gaps], None if ff is None else round(ff, 3),
    esc.get("outcome"), esc.get("historyFoldersBefore"), esc.get("historyFoldersAfter"), folders,
    "" if not problems else " [" + "; ".join(problems) + "]"))
sys.exit(1 if problems else 0)
' "$RUN/acm2-4-f.out" "$RUN/acm2-4-f-esc.out" "$folders" 2>&1)" || problems="$problems [f]"
  remove_run_path "$home"
  lines="$lines $out;"

  # (g) latency over 20 runs at 1280x800 and 90 frames.
  home="$(fresh_home)"
  # shellcheck disable=SC2086
  run_ctl_in "$home" acm2-4-g record --fake $area --runs 20 --json
  out="$(py g '
import json, sys
r = json.load(open(sys.argv[1]))
c = (r.get("confirmToRecording") or {}).get("p95Ms")
s = (r.get("stopToCardReady") or {}).get("p95Ms")
runs = r.get("runs") or []
problems = []
if len(runs) != 20: problems.append("%d runs" % len(runs))
if any(x.get("outcome") != "complete" for x in runs): problems.append("a run did not complete")
if c is None or not c < 50: problems.append("confirm to recording p95 over 50 ms")
if s is None or not s < 500: problems.append("stop to card ready p95 over 500 ms")
print("(g) %d runs: confirm to recording p95 %s ms (limit 50), stop to card ready p95 %s ms (limit 500)%s" % (
    len(runs), c, s, "" if not problems else " [" + "; ".join(problems) + "]"))
sys.exit(1 if problems else 0)
' "$RUN/acm2-4-g.out" 2>&1)" || problems="$problems [g]"
  remove_run_path "$home"
  lines="$lines $out"

  if [ -n "$problems" ]; then fail AC-M2-4 "recording, failing parts$problems:$lines"; else pass AC-M2-4 "recording:$lines"; fi
}

# ---------------------------------------------------------------------------------------------
# AC-M2-5
# ---------------------------------------------------------------------------------------------

acm2_5() {
  local home out problems="" now skip zone kind
  home="$(fresh_home)"
  if ! run_ctl_in "$home" acm2-5-gen history gen --items 200 --days 5 --seed 7 --json; then
    remove_run_path "$home"
    fail AC-M2-5 "snapctl history gen failed, see $RUN/acm2-5-gen.err"
    return
  fi
  now="$(json_get "$RUN/acm2-5-gen.out" 'd["now"]')"
  skip="$(json_get "$RUN/acm2-5-gen.out" 'd["skipID"]')"
  zone="$(json_get "$RUN/acm2-5-gen.out" 'd["timeZone"]')"
  run_ctl_in "$home" acm2-5-sweep history sweep --now "$now" --skip "$skip" --json
  TZ="$zone" run_ctl_in "$home" acm2-5-list history list --runs 20 --now "$now" --json
  TZ="$zone" run_ctl_in "$home" acm2-5-query history list --query "notes today" --now "$now" --json
  TZ="$zone" run_ctl_in "$home" acm2-5-video history list --kind video --now "$now" --json
  remove_run_path "$home"
  if out="$(py check '
import json, sys
gen, sweep, listing, query, video = (json.load(open(p)) for p in sys.argv[1:6])
problems = []
expected = set(gen["expectedSweptIDs"])
old_but_skipped = set(gen["oldIDs"]) - {gen["skipID"]}
removed = set(sweep.get("removed") or [])
if expected != old_but_skipped: problems.append("manifest: expected sweep is not every old id but the skipped one")
if removed != expected: problems.append("sweep removed %d, expected %d (%d extra, %d missing)" % (
    len(removed), len(expected), len(removed - expected), len(expected - removed)))
remaining = set(gen["remainingIDs"])
listed = set(listing.get("ids") or [])
if listed != remaining: problems.append("list shows %d ids, %d remain in the manifest" % (len(listed), len(remaining)))
p95 = (listing.get("timing") or {}).get("p95Ms")
runs = (listing.get("timing") or {}).get("runs")
if p95 is None or not p95 < 50: problems.append("list p95 %s ms" % p95)
queries = {q.get("query") or ("kind:" + q.get("kind", "")): set(q["expectedIDs"]) for q in gen.get("queries", [])}
got_query, got_video = set(query.get("ids") or []), set(video.get("ids") or [])
if got_query != queries.get("notes today"): problems.append("query notes today: %d ids, expected %d" % (len(got_query), len(queries.get("notes today", ()))))
if got_video != queries.get("kind:video"): problems.append("kind video: %d ids, expected %d" % (len(got_video), len(queries.get("kind:video", ()))))
items = {i["id"]: i for i in listing.get("items", [])}
v1 = [i for i in gen.get("version1IDs", []) if i in items]
bad_v1 = [i for i in v1 if items[i].get("kind") != "image" or items[i].get("state") != "complete"]
if not v1: problems.append("no version 1 item left to check")
if bad_v1: problems.append("version 1 items not image/complete: %s" % bad_v1[:3])
print("sweep removed %d of %d expected (skipped %s); list of %d items over %s runs p95 %s ms (limit 50); \"notes today\" %d ids (expected %d); kind video %d ids (expected %d); %d version 1 items list as image, complete%s" % (
    len(removed & expected), len(expected), gen["skipID"], len(listed), runs, p95, len(got_query), len(queries.get("notes today", ())),
    len(got_video), len(queries.get("kind:video", ())), len(v1) - len(bad_v1), "" if not problems else "  [" + "; ".join(problems) + "]"))
sys.exit(1 if problems else 0)
' "$RUN/acm2-5-gen.out" "$RUN/acm2-5-sweep.out" "$RUN/acm2-5-list.out" "$RUN/acm2-5-query.out" "$RUN/acm2-5-video.out" 2>&1)"; then
    pass AC-M2-5 "$out"
  else
    fail AC-M2-5 "$out"
  fi
}

# ---------------------------------------------------------------------------------------------
# AC-M2-6
# ---------------------------------------------------------------------------------------------

# Field n of shot-stats for a region, from a precomputed line.
field() { echo "$1" | awk -v f="$2" '{print $f}'; }

# True when shot-stats' mean RGB of a 1x1 region is within 3/255 of r g b.
pixel_is() { # png x y r g b
  "$STATS" "$1" "$2" "$3" 1 1 2>/dev/null | awk -v r="$4" -v g="$5" -v b="$6" \
    'function a(x) { return x < 0 ? -x : x } { exit !(a($7 - r) <= 3 && a($8 - g) <= 3 && a($9 - b) <= 3) }'
}

pixel_rgb() { "$STATS" "$1" "$2" "$3" 1 1 2>/dev/null | awk '{printf "(%.0f, %.0f, %.0f)", $7, $8, $9}'; }

acm2_6() {
  local dir="$RUN/acm2-6" home problems="" lines="" stats rx ry rw rh cells x y
  mkdir -p "$dir"
  home="$(fresh_home)"
  run_ctl_in "$home" acm2-6-block gen-fixture block-2x --out "$dir/block-2x.png"
  run_ctl_in "$home" acm2-6-noise gen-fixture noise-2x --out "$dir/noise-2x.png"

  # Black-out inside the red block (block at 50,50 to 350,250 pt) and pixelate across its right
  # and bottom edges, so the edge falls inside cells.
  if run_ctl_in "$home" acm2-6-redact annotate --in "$dir/block-2x.png" --out "$dir/redact.png" --report \
    --doc '{"items":[{"kind":"blackout","rect":[100,100,150,100]},{"kind":"pixelate","rect":[320,233,60,40]}]}'; then
    rx="$(json_get "$RUN/acm2-6-redact.out" 'd["redactions"][0]["region"]["x"]')"
    ry="$(json_get "$RUN/acm2-6-redact.out" 'd["redactions"][0]["region"]["y"]')"
    rw="$(json_get "$RUN/acm2-6-redact.out" 'd["redactions"][0]["region"]["width"]')"
    rh="$(json_get "$RUN/acm2-6-redact.out" 'd["redactions"][0]["region"]["height"]')"
    stats="$("$STATS" "$dir/redact.png" "$rx" "$ry" "$rw" "$rh")"
    lines="$lines black-out ${rw}x${rh} px at $rx,$ry: mean RGB ($(field "$stats" 7), $(field "$stats" 8), $(field "$stats" 9)), max RGB ($(field "$stats" 11), $(field "$stats" 12), $(field "$stats" 13));"
    awk -v r="$(field "$stats" 11)" -v g="$(field "$stats" 12)" -v b="$(field "$stats" 13)" 'BEGIN { exit !(r <= 1 && g <= 1 && b <= 1) }' \
      || problems="$problems [black-out keeps a pixel above 1/255]"
    rx="$(json_get "$RUN/acm2-6-redact.out" 'd["redactions"][1]["region"]["x"]')"
    ry="$(json_get "$RUN/acm2-6-redact.out" 'd["redactions"][1]["region"]["y"]')"
    rw="$(json_get "$RUN/acm2-6-redact.out" 'd["redactions"][1]["region"]["width"]')"
    rh="$(json_get "$RUN/acm2-6-redact.out" 'd["redactions"][1]["region"]["height"]')"
    cells="$("$STATS" --cells "$dir/redact.png" "$rx" "$ry" "$rw" "$rh")"
    lines="$lines pixelate ${rw}x${rh} px at $rx,$ry: $cells;"
    if ! python3 -I -c '
import json, sys
c = json.loads(sys.argv[1])
ok = c["rowsWithCells"] > 0 and c["minRunX"] is not None and c["minRunX"] >= 8 and (c["minRunY"] is None or c["minRunY"] >= 8)
sys.exit(0 if ok else 1)' "$cells"; then
      problems="$problems [pixelate cells narrower than 8 px or none found]"
    fi
  else
    problems="$problems [annotate redact failed, see $RUN/acm2-6-redact.err]"
  fi

  # Blur a 200x200 px region of the noise fixture.
  if run_ctl_in "$home" acm2-6-blur annotate --in "$dir/noise-2x.png" --out "$dir/blur.png" --report \
    --doc '{"unit":"px","items":[{"kind":"blur","rect":[500,300,200,200]}]}'; then
    local before after
    before="$(stat_field 4 "$dir/noise-2x.png" 500 300 200 200)"
    after="$(stat_field 4 "$dir/blur.png" 500 300 200 200)"
    lines="$lines blur 200x200 px stddev $after vs $before in the input ($(awk -v a="$after" -v b="$before" 'BEGIN { printf "%.1f", 100 * a / b }')%, limit 25%);"
    awk -v a="$after" -v b="$before" 'BEGIN { exit !(b > 0 && a <= 0.25 * b) }' || problems="$problems [blur keeps too much detail]"
  else
    problems="$problems [annotate blur failed, see $RUN/acm2-6-blur.err]"
  fi

  # Three steps, the second deleted, and a freehand stroke, on the white part of block-2x.
  if run_ctl_in "$home" acm2-6-steps annotate --in "$dir/block-2x.png" --out "$dir/steps.png" --report \
    --doc '{"items":[{"kind":"step","at":[420,80],"color":"#0A84FF","width":4},{"kind":"step","at":[480,180],"color":"#0A84FF","width":4},{"kind":"step","at":[540,300],"color":"#0A84FF","width":4},{"kind":"freehand","points":[[380,330],[420,350],[460,360],[500,350],[540,330],[580,360]],"color":"#34C759","width":4}],"deleteSteps":[2]}'; then
    local numbers count i color
    numbers="$(json_get "$RUN/acm2-6-steps.out" 'd["steps"]')"
    count="$(json_get "$RUN/acm2-6-steps.out" 'len([i for i in d["items"] if i["kind"] == "step"])')"
    lines="$lines steps numbered $numbers, $count circles;"
    [ "$numbers" = "[1, 2]" ] || problems="$problems [step numbers $numbers]"
    [ "$count" = 2 ] || problems="$problems [$count step circles]"
    for i in 0 1; do
      # Ruling on AC-M2-6: the step color is sampled at the circle's fill point clear of the digit
      # (0.38 x diameter right of center, from --report), because D71 puts the white number at the center.
      x="$(json_get "$RUN/acm2-6-steps.out" "int([i for i in d['items'] if i['kind'] == 'step'][$i]['fill']['x'])")"
      y="$(json_get "$RUN/acm2-6-steps.out" "int([i for i in d['items'] if i['kind'] == 'step'][$i]['fill']['y'])")"
      color="$(pixel_rgb "$dir/steps.png" "$x" "$y")"
      lines="$lines step $((i + 1)) fill pixel $x,$y $color (expected (10, 132, 255));"
      pixel_is "$dir/steps.png" "$x" "$y" 10 132 255 || problems="$problems [step $((i + 1)) fill pixel is $color]"
      # For information only: the exact center, under the white digit.
      x="$(json_get "$RUN/acm2-6-steps.out" "int([i for i in d['items'] if i['kind'] == 'step'][$i]['center']['x'])")"
      y="$(json_get "$RUN/acm2-6-steps.out" "int([i for i in d['items'] if i['kind'] == 'step'][$i]['center']['y'])")"
      color="$(pixel_rgb "$dir/steps.png" "$x" "$y")"
      lines="$lines step $((i + 1)) center $x,$y $color (the digit, information only);"
    done
    # Where the deleted step was there is no circle.
    color="$(pixel_rgb "$dir/steps.png" 960 360)"
    lines="$lines deleted step's place $color;"
    pixel_is "$dir/steps.png" 960 360 10 132 255 && problems="$problems [the deleted step is still drawn]"
    x="$(json_get "$RUN/acm2-6-steps.out" "int(round([i for i in d['items'] if i['kind'] == 'freehand'][0]['midpoint']['x']))")"
    y="$(json_get "$RUN/acm2-6-steps.out" "int(round([i for i in d['items'] if i['kind'] == 'freehand'][0]['midpoint']['y']))")"
    color="$(pixel_rgb "$dir/steps.png" "$x" "$y")"
    lines="$lines freehand midpoint $x,$y $color (expected (52, 199, 89))"
    pixel_is "$dir/steps.png" "$x" "$y" 52 199 89 || problems="$problems [freehand midpoint is $color]"
  else
    problems="$problems [annotate steps failed, see $RUN/acm2-6-steps.err]"
  fi
  remove_run_path "$home"
  if [ -n "$problems" ]; then fail AC-M2-6 "annotate:$problems;$lines"; else pass AC-M2-6 "annotate:$lines"; fi
}

# ---------------------------------------------------------------------------------------------
# AC-M2-7
# ---------------------------------------------------------------------------------------------

acm2_7() {
  local dir="$RUN/acm2-7" home problems="" lines="" sha1 sha2 w h spec x y want got size name input expected flags
  mkdir -p "$dir"
  home="$(fresh_home)"
  run_ctl_in "$home" acm2-7-block gen-fixture block-2x --out "$dir/block-2x.png"
  run_ctl_in "$home" acm2-7-noise gen-fixture noise-2x --out "$dir/noise-2x.png"

  run_ctl_in "$home" acm2-7-mesh1 beautify "$dir/block-2x.png" --out "$dir/mesh-1.png" --background mesh:haze \
    || problems="$problems [beautify mesh:haze failed]"
  run_ctl_in "$home" acm2-7-mesh2 beautify "$dir/block-2x.png" --out "$dir/mesh-2.png" --background mesh:haze \
    || problems="$problems [beautify mesh:haze failed]"
  sha1="$(shasum -a 256 "$dir/mesh-1.png" 2>/dev/null | awk '{print $1}')"
  sha2="$(shasum -a 256 "$dir/mesh-2.png" 2>/dev/null | awk '{print $1}')"
  w="$(stat_field 1 "$dir/mesh-1.png")"
  h="$(stat_field 2 "$dir/mesh-1.png")"
  lines="$lines mesh:haze ${w}x${h}, SHA-256 ${sha1:0:16} twice $([ -n "$sha1" ] && [ "$sha1" = "$sha2" ] && echo identical || echo DIFFERENT);"
  [ -n "$sha1" ] && [ "$sha1" = "$sha2" ] || problems="$problems [mesh renders differ]"
  [ "${w}x${h}" = 712x512 ] || problems="$problems [mesh size ${w}x${h}]"
  # The Haze grid's corners (MeshGradients.swift): top-left, top-right, bottom-left, bottom-right.
  for spec in "TL 2 2 165 180 252" "TR $((w - 4)) 2 240 171 252" "BL 2 $((h - 4)) 153 246 228" "BR $((w - 4)) $((h - 4)) 253 230 138"; do
    set -- $spec
    got="$("$STATS" "$dir/mesh-1.png" "$2" "$3" 2 2 2>/dev/null | awk '{printf "%.1f %.1f %.1f", $7, $8, $9}')"
    lines="$lines $1 ($got) vs ($4 $5 $6);"
    echo "$got" | awk -v r="$4" -v g="$5" -v b="$6" 'function a(x) { return x < 0 ? -x : x }
      { exit !(NF == 3 && a($1 - r) <= 3 && a($2 - g) <= 3 && a($3 - b) <= 3) }' || problems="$problems [$1 corner $got]"
  done

  if run_ctl_in "$home" acm2-7-blurred beautify "$dir/noise-2x.png" --out "$dir/blurred.png" --background blurred --report; then
    local band input
    w="$(stat_field 1 "$dir/blurred.png")"
    h="$(stat_field 2 "$dir/blurred.png")"
    band="$(stat_field 4 "$dir/blurred.png" 0 0 "$w" 16)"
    input="$(stat_field 4 "$dir/noise-2x.png")"
    lines="$lines blurred ${w}x${h}, top 16 px padding band stddev $band vs input $input ($(awk -v a="$band" -v b="$input" 'BEGIN { printf "%.1f", 100 * a / b }')%, limit 50%);"
    [ "${w}x${h}" = 1256x856 ] || problems="$problems [blurred size ${w}x${h}]"
    awk -v a="$band" -v b="$input" 'BEGIN { exit !(b > 0 && a <= 0.5 * b) }' || problems="$problems [padding band too busy]"
  else
    problems="$problems [beautify blurred failed, see $RUN/acm2-7-blurred.err]"
  fi

  # AC02's four sizes.
  for spec in "noise|noise-2x|1256x856|" "block|block-2x|712x512|" "block-noab|block-2x|1312x912|--no-autobalance" \
    "block-16x9|block-2x|910x512|--ratio 16:9"; do
    IFS='|' read -r name input expected flags <<<"$spec"
    # shellcheck disable=SC2086
    run_ctl_in "$home" "acm2-7-$name" beautify "$dir/$input.png" --out "$dir/$name.png" $flags
    size="$(stat_field 1 "$dir/$name.png")x$(stat_field 2 "$dir/$name.png")"
    lines="$lines $input${flags:+ $flags} $size;"
    [ "$size" = "$expected" ] || problems="$problems [$input $flags is $size, expected $expected]"
  done
  remove_run_path "$home"
  if [ -n "$problems" ]; then fail AC-M2-7 "backgrounds:$problems;$lines"; else pass AC-M2-7 "backgrounds:$lines"; fi
}

# ---------------------------------------------------------------------------------------------
# AC-M2-8
# ---------------------------------------------------------------------------------------------

acm2_8() {
  local bench home out
  bench="$(bench_path)"
  if [ ! -x "$bench" ]; then
    fail AC-M2-8 "no snapbench at $bench"
    return
  fi
  home="$(fresh_home)"
  SNAP_HOME="$home" SNAP_NO_UPDATES=1 "$bench" latency --fake --mode hud --runs 50 --display 5120x2880@2 \
    --capture-delay-ms 0 --json >"$RUN/acm2-8-hud.out" 2>"$RUN/acm2-8-hud.err"
  SNAP_HOME="$home" SNAP_NO_UPDATES=1 "$bench" latency --fake --mode hud --record --runs 50 --display 5120x2880@2 \
    --capture-delay-ms 0 --json >"$RUN/acm2-8-record.out" 2>"$RUN/acm2-8-record.err"
  remove_run_path "$home"
  if out="$(python3 -I -c '
import json, sys
problems, parts = [], []
try:
    r = json.load(open(sys.argv[1]))
except Exception as error:
    print("HUD bench produced no report: %s" % error); sys.exit(1)
limits = {"present": 20.0, "frozen": 30.0, "card": 30.0}
for stage, limit in limits.items():
    p95 = ((r.get("stages") or {}).get(stage) or {}).get("p95Ms")
    parts.append("%s p95 %s ms (limit %g)" % (stage, "none" if p95 is None else "%.3f" % p95, limit))
    if p95 is None or not p95 < limit: problems.append(stage + " over limit")
runs = r.get("runDetails") or []
want = ["present", "frozen", "confirm", "card"]
bad = [d.get("run") for d in runs if (d.get("order") or [])[:4] != want]
parts.append("%d runs, %d out of order" % (len(runs), len(bad)))
if len(runs) != 50: problems.append("expected 50 runs")
if bad: problems.append("wrong order in runs %s" % bad[:5])
hud = r.get("hud") or {}
mismatched = [d.get("run") for d in runs if d.get("restoredArea") != hud.get("storedArea")]
parts.append("stored area %s restored exactly in %d of %d runs" % (hud.get("storedArea"), len(runs) - len(mismatched), len(runs)))
if mismatched or not hud.get("storedArea"): problems.append("restored area differs in runs %s" % mismatched[:5])
try:
    rec = json.load(open(sys.argv[2]))
except Exception as error:
    rec = {}; problems.append("record bench produced no report: %s" % error)
rruns = rec.get("runDetails") or []
frozen = sum(d.get("frozenCapturesRequested", 0) or 0 for d in rruns)
parts.append("--record: %d runs, %d frozen captures requested" % (len(rruns), frozen))
if len(rruns) != 50: problems.append("record bench ran %d runs" % len(rruns))
if frozen != 0 or (rec.get("hud") or {}).get("noFrozenCaptureRequested") is not True: problems.append("record mode requested a frozen capture")
print(", ".join(parts) + ("  [" + "; ".join(problems) + "]" if problems else ""))
sys.exit(1 if problems else 0)
' "$RUN/acm2-8-hud.out" "$RUN/acm2-8-record.out" 2>&1)"; then
    pass AC-M2-8 "$out"
  else
    fail AC-M2-8 "$out"
  fi
}

# ---------------------------------------------------------------------------------------------
# AC-M2-9 and AC-M2-10
# ---------------------------------------------------------------------------------------------

# The point size of a scenario (design 20.11).
m2_points() {
  case "$1" in
    pin | hud | recording-countdown | recording) echo "1280 800" ;;
    history | history-empty) echo "760 560" ;;
    quick-access-video) echo "600 760" ;;
    annotate-tools) echo "1100 720" ;;
    background-mesh) echo "920 640" ;;
    settings-recording) echo "480 690" ;;
    menu-m2) echo "420 600" ;;
  esac
}

# The first region of a scenario in regions.tsv, in pixels at 2x: "x y w h".
first_region() {
  awk -F'\t' -v s="$1" '$1 == s { print $3 * 2, $4 * 2, $5 * 2, $6 * 2; exit }' "$REGIONS"
}

acm2_9() {
  local before after rc=0 problems="" lines="" scn mode f pts width height deviation region light dark diff count=0
  if ! ensure_bundle; then
    fail AC-M2-9 "bundle.sh failed, see $RUN/bundle-m2.log"
    return
  fi
  before="$(front)"
  run_logged shots-m2 "$REPO/scripts/shots.sh" m2
  rc=$?
  after="$(front)"
  case $rc in
    0) ;;
    3) problems="$problems [frontmost app changed during a shot]" ;;
    4) problems="$problems [an on-screen window of the shot PID appeared]" ;;
    *) problems="$problems [shots.sh m2 exit $rc, see $LAST_LOG]" ;;
  esac
  [ "$before" = "$after" ] || problems="$problems [lsappinfo front changed: $before -> $after]"
  for scn in $M2_SCENARIOS; do
    pts="$(m2_points "$scn")"
    for mode in light dark; do
      f="$REPO/build/shots/$scn-$mode.png"
      if [ ! -s "$f" ] || [ ! "$f" -nt "$RUN/ac01.start" ]; then
        problems="$problems [no fresh $scn-$mode.png]"
        continue
      fi
      width="$(stat_field 1 "$f")"
      height="$(stat_field 2 "$f")"
      deviation="$(stat_field 4 "$f")"
      if [ "$width $height" != "$(echo "$pts" | awk '{print $1 * 2, $2 * 2}')" ]; then
        problems="$problems [$scn-$mode is ${width}x${height}, expected 2x of $pts pt]"
      elif ! awk -v d="${deviation:-0}" 'BEGIN { exit !(d >= 4) }'; then
        problems="$problems [$scn-$mode stddev ${deviation:-0}]"
      else
        count=$((count + 1))
      fi
    done
    region="$(first_region "$scn")"
    # shellcheck disable=SC2086
    light="$(stat_field 3 "$REPO/build/shots/$scn-light.png" $region)"
    # shellcheck disable=SC2086
    dark="$(stat_field 3 "$REPO/build/shots/$scn-dark.png" $region)"
    if [ -z "$light" ] || [ -z "$dark" ]; then
      problems="$problems [no region stats for $scn]"
      continue
    fi
    diff="$(awk -v a="$light" -v b="$dark" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.1f", d }')"
    lines="$lines $scn $diff;"
    awk -v d="$diff" 'BEGIN { exit !(d >= 40) }' || problems="$problems [$scn light/dark differ by $diff/255]"
  done
  if [ -n "$problems" ]; then
    fail AC-M2-9 "M2 shots:$problems; light/dark difference over the first region:$lines"
  else
    pass AC-M2-9 "$count PNGs at 2x of design 20.11, stddev at least 4, frontmost unchanged, no window; light/dark difference over the first region:$lines"
  fi
}

acm2_10() {
  local scn mode shot mock out problems="" lines="" n=0
  for scn in $M2_SCENARIOS; do
    for mode in light dark; do
      shot="$REPO/build/shots/$scn-$mode.png"
      mock="$REPO/docs/mockup/png/m2/$scn-$mode.png"
      if [ ! -s "$shot" ] || [ ! -s "$mock" ]; then
        problems="$problems [missing $scn-$mode]"
        continue
      fi
      "$STATS" --compare "$shot" "$mock" --grid 32 --regions "$REGIONS" --scenario "$scn" \
        >"$RUN/acm2-10-$scn-$mode.json" 2>"$RUN/acm2-10-$scn-$mode.err"
      if out="$(python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1]))
name = sys.argv[2]
problems = []
g = r.get("grid") or {}
if not r.get("sizeMatch"): problems.append("size %s vs %s" % (r.get("sizeA"), r.get("sizeB")))
mean, p90 = g.get("meanAbsDiff"), g.get("p90AbsDiff")
if mean is None or mean > 20: problems.append("grid mean %s > 20" % mean)
if p90 is None or p90 > 48: problems.append("grid p90 %s > 48" % p90)
regions = r.get("regions") or []
if not regions: problems.append("no regions")
for region in regions:
    d = region.get("absDiff")
    if d is None or d > 24: problems.append("%s %s > 24" % (region.get("name"), d))
print("%s grid mean %s p90 %s, regions %s%s" % (name, mean, p90,
    " ".join("%s %s" % (x.get("name"), x.get("absDiff")) for x in regions),
    "" if not problems else " [" + "; ".join(problems) + "]"))
sys.exit(1 if problems else 0)
' "$RUN/acm2-10-$scn-$mode.json" "$scn-$mode" 2>&1)"; then
        n=$((n + 1))
      else
        problems="$problems [$scn-$mode]"
      fi
      lines="$lines $out;"
    done
  done
  if [ -n "$problems" ]; then
    fail AC-M2-10 "shots vs mockup, failing:$problems; measured:$lines"
  else
    pass AC-M2-10 "$n of 22 shots match the mockup (grid mean <= 20, p90 <= 48, regions <= 24):$lines"
  fi
}

# ---------------------------------------------------------------------------------------------
# m2
# ---------------------------------------------------------------------------------------------

group_m2() {
  echo
  echo "== m2"
  : >"$RUN/ac01.start"
  if wanted AC-M2-1 || wanted AC-M2-2 || wanted AC-M2-3; then
    ac01
    CHECK_RAN=1
  fi
  if ! shot_stats_tool; then
    local id
    for id in AC-M2-2 AC-M2-4 AC-M2-6 AC-M2-7 AC-M2-9 AC-M2-10; do
      if wanted "$id"; then fail "$id" "cannot build shot-stats, see $RUN/shot-stats-build.log"; fi
    done
  else
    CTL="$(snapctl_path)"
    if wanted AC-M2-2; then
      if [ -x "$CTL" ]; then ac02; else fail AC02 "no snapctl at $CTL"; fi
      ac03
      ac04
      ac05
    fi
    if wanted AC-M2-1; then acm2_1; fi
    if wanted AC-M2-2; then acm2_2; fi
    if wanted AC-M2-3; then acm2_3; fi
    if [ -x "$CTL" ]; then
      if wanted AC-M2-4; then acm2_4; fi
      if wanted AC-M2-5; then acm2_5; fi
      if wanted AC-M2-6; then acm2_6; fi
      if wanted AC-M2-7; then acm2_7; fi
    else
      for id in AC-M2-4 AC-M2-5 AC-M2-6 AC-M2-7; do
        if wanted "$id"; then fail "$id" "no snapctl at $CTL"; fi
      done
    fi
    if wanted AC-M2-8; then acm2_8; fi
    if wanted AC-M2-9; then acm2_9; fi
    if wanted AC-M2-10; then acm2_10; fi
  fi
}

CTL=""
case "$GROUP" in
  offline) group_offline ;;
  m2) group_m2 ;;
esac

echo
FAILS="$(awk -F'\t' '$2 == "FAIL"' "$RESULTS" | wc -l | tr -d ' ')"
PASSES="$(awk -F'\t' '$2 == "PASS"' "$RESULTS" | wc -l | tr -d ' ')"
echo "Results: $RESULTS ($PASSES PASS, $FAILS FAIL)"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
