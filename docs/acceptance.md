# Snap acceptance

Milestone 1 is group `offline` (AC01 to AC05, below); milestone 2 is group `m2` (AC-M2-1 to
AC-M2-10, in the [Milestone 2](#milestone-2) section further down).

## Milestone 1

`scripts/accept.sh offline` checks the five criteria below and prints one `PASS`, `FAIL` or `SKIP`
line per criterion. It exits 1 on any FAIL. Each run writes its logs, its fresh `SNAP_HOME`
folders and `results.tsv` to `build/accept/<timestamp>/`.

```sh
SNAP_SCRATCH="$TMPDIR/snap-check" scripts/accept.sh offline
SNAP_SCRATCH="$TMPDIR/snap-check" scripts/accept.sh offline AC02 AC05   # only these, for iterating
```

Everything runs headless. No check shows a window, takes focus, captures the screen, asks for a
permission, plays a sound or uses the network. Every `snapctl` and `Snap --shot` process gets
its own `SNAP_HOME` from `mktemp`, so nothing reads or writes the real Snap folder, ~/Downloads
or the real pasteboard. Processes the script starts are stopped by PID when it exits.

### AC01: all gates green

**Criterion.** `SNAP_SCRATCH=$TMPDIR/snap-check scripts/check.sh` exits 0. It runs the release
build, `swift test` with a fresh `SNAP_HOME`, `swiftlint --strict` (including the rule that
ScreenCaptureKit and `CGRequestScreenCaptureAccess` appear only in `Sources/SnapSystem`),
`otool -L` showing that `snapctl` and `snapbench` do not link ScreenCaptureKit, `scripts/bundle.sh --release`,
`codesign --verify --strict`, `plutil -lint` with `CFBundleIdentifier` `dev.sdusteric.snap` and
`LSUIElement` true, `codesign -d -r-` containing `identifier "dev.sdusteric.snap"` and
`Apple Development`, and no em or en dashes.

**How it is checked.** `accept.sh` runs `scripts/check.sh` with the same `SNAP_SCRATCH` and
passes when it exits 0. Each gate's output is in `build/check/<gate>.log`; the run's copy of the
whole output is `build/accept/<timestamp>/check.log`.

### AC02: Beautify matches the preset geometry

**Criterion.** `snapctl preset --default --json` prints padding 21, inset 21, cornerRadius 0.12,
shadow 32, alignment 4 and autoBalance true. `snapctl gen-fixture` plus `snapctl beautify
--report` give these exact output sizes: noise-2x 1256x856, block-2x 712x512 with auto-balance,
1312x912 without, 910x512 at ratio 16:9. Measured with `shot-stats` on block-2x with background
`solid:#F5F5F7`: the pixel 1 px inside the card's top-left corner is not red (corner rounding
shows the background); an 8 px band below the card is at least 8/255 darker than the background
at shadow 32 and within 2/255 at shadow 0; the red content's left/right and top/bottom margins
match within 1 px.

**How it is checked.**

1. The preset JSON is parsed and each of the six fields compared with the value above.
2. `gen-fixture noise-2x` and `gen-fixture block-2x` write the 1200x800 px, 144 DPI inputs of
   design section 10.2.
3. `beautify` runs four times (noise-2x; block-2x; block-2x `--no-autobalance`; block-2x
   `--ratio 16:9`). Both the reported `canvasSize` and the PNG's own pixel size (from
   `shot-stats`) must equal the expected size.
4. block-2x is rendered over `solid:#F5F5F7` twice, with the default preset (shadow 32) and with
   the same preset at shadow 0. The card rectangle comes from the `--report` JSON.
   - Corner: the 1x1 region at (card x + 1, card y + 1) must not be the fixture red
     (red above 200, green and blue below 80).
   - Shadow: the mean luminance of the region (card x, card y + card height, card width, 8) is
     compared with the luminance of #F5F5F7 (245.1). At shadow 32 it must be at least 8 lower;
     at shadow 0 it must be within 2.
   - Margins: binary searches along the middle row and the middle column find the first and last
     red pixel. Left and right margins, and top and bottom margins, must differ by at most 1 px.

### AC03: logic suites present and passing

**Criterion.** `swift test` output shows SelectionGeometryTests, WindowHitTesterTests,
CoordinateSpaceTests, FileNamerTests, QuickAccessStackTests, HotkeyConflictTests,
PermissionStateTests, AnnotationModelTests, BeautifyRendererTests and CaptureCoordinatorTests,
each with at least one passing test and no failure. A missing suite counts as FAIL.

**How it is checked.** The script reads `build/check/test.log` when AC01 wrote it in this run,
else it runs `swift test` itself with a fresh `SNAP_HOME`. Each suite must have a
`✔ Suite <name> passed` line and no `✘ Suite <name> failed` line, the log must have no `✘` line
at all, and the last `Test run with` summary must be a pass.

### AC04: background UI screenshots with no window

**Criterion.** `scripts/shots.sh` produces 12 PNGs in `build/shots`: overlay-area, quick-access,
background-editor, annotate, menu and settings, each in light and dark, at 2x their point sizes.
Each is non-blank (luminance stddev at least 4), and each light/dark pair differs by at least
40/255 mean luminance in its chrome region. The script exits 0, which means `lsappinfo front` was
unchanged around every launch and `winlist` never saw an on-screen window owned by the shot PID.

**How it is checked.** `shots.sh` runs `build/bundle/Snap.app/Contents/MacOS/Snap --shot
<scenario> --appearance light|dark --out <png>` by direct exec, one process per shot, each with
a fresh `SNAP_HOME`. It records `lsappinfo front` before and after (exit 3 on a change) and polls
`scripts/winlist.swift` every 100 ms for an on-screen window of that PID (exit 4). The shot mode
never calls `NSApplication.run`, never creates an `NSWindow` or `NSPanel`, and never uses a
SnapSystem live type: AppKit trees are drawn with `cacheDisplay(in:to:)` and SwiftUI with
`ImageRenderer`, at scale 2.

The point sizes are the design doc's shot table (section 16); the chrome regions are in pixels,
top-left origin:

| Scenario | Points | Pixels | Chrome region (x y w h) |
|---|---|---|---|
| overlay-area | 1280 x 800 | 2560 x 1600 | 740 460 1240 760 (the selection cut-out) |
| quick-access | 600 x 760 | 1200 x 1520 | 32 320 512 1168 (the card column) |
| background-editor | 920 x 640 | 1840 x 1280 | 1240 0 600 1180 (the sidebar) |
| annotate | 1100 x 720 | 2200 x 1440 | 0 0 2200 104 (the toolbar) |
| menu | 280 x 500 | 560 x 1000 | 0 16 560 840 (the menu body) |
| settings | 480 x 690 | 960 x 1380 | 0 0 960 1380 (the form) |

`accept.sh` checks that `shots.sh` exited 0, that `lsappinfo front` is also unchanged around the
whole script, each PNG's size and luminance stddev, and the light/dark difference of each
region, all with `scripts/shot-stats.swift`. If a layout moves, the regions stop differing and
the criterion fails rather than passing silently.

### AC05: capture-to-overlay latency with the fake capture source

**Criterion.** `snapbench latency --fake --runs 50 --display 5120x2880@2 --capture-delay-ms 0
--json` reports p95 under 20 ms from trigger to overlay present, under 30 ms to frozen image
ready, and under 30 ms from confirm to Quick Access card. In every run the event order is
present, then frozen, then confirm, then card, and only after that encode, history and clipboard.

`snapbench` drives the real `OverlayController` (no panels, a cursor stand-in that does nothing,
a simulated drag the moment the frozen image is shown) and the real `QuickAccessController` (no
panel), with `FakeCaptureSource` and a monotonic clock. It links SnapCore and SnapUI, never
SnapSystem, so like `snapctl` it does not link ScreenCaptureKit; `check.sh` verifies both.

**How it is checked.** The JSON report's `stages.present.p95Ms`, `stages.frozen.p95Ms` and
`stages.card.p95Ms` are compared with 20, 30 and 30 ms. `runDetails` must hold 50 runs, and each
run's `order` must be exactly `present, frozen, confirm, card, encode, history, clipboard`.

### Hands-on checks for the user, milestone 1 (not automated)

No agent may show a window, take focus, hide the cursor or post input events on this Mac, so
the window server's part of these behaviours cannot be run here. Snap's own part of each check
is covered offscreen: the suites below deliver events straight to view objects, write to a
private named pasteboard and render the panel content without a window. What is left for the
user is only what the window server does: key focus, cursor visibility, click routing and drops
into other apps.

Why no agent can run the rest: every remaining question is decided by the window server for
the user's live login session. A window placed off every display is still an on-screen window
to the window server (and to `winlist.swift`), so it counts as showing a window. Key focus and
click routing can only be observed by posting events with `CGEventPost`, which is input into
other apps and needs the Accessibility permission (a dialog). Cursor visibility is shared by the
whole session, so testing `NSCursor.hide` hides the user's cursor. A virtual display shares the
same session, cursor and focus. A second login session or a virtual machine needs the user or an
install. An XCUITest runner shows the app's real windows and needs the Accessibility and
Automation permissions, and Screen Sharing into a second session needs a settings change. None
of these is allowed, so the checks below stay manual.

Check them once by hand after installing with `scripts/bundle.sh --install`, with another app
(for example a text editor) frontmost:

1. Cmd+Shift+4: the crosshair replaces the arrow while Snap is not the active app
   (`NSCursor.hide` from a background app). Covered offscreen: every exit path calls hide and
   unhide in balance (`OverlayControllerTests`, `FakeCursor.isBalanced`). Not covered: whether
   the window server honours `NSCursor.hide` for an app that is not active. It is commonly
   reported that it does not. If the arrow stays, report it; the known remedy is the private
   CoreGraphics connection property `SetsCursorInBackground`, which Snap does not use today.
2. During the overlay, Esc cancels and Tab switches to window mode, so the non-activating
   overlay panel received keys through `makeKey()`. The frontmost app's title bar should not go
   inactive. Covered offscreen: the overlay view accepts first responder and forwards Esc, Space
   and Tab key events to the controller (`PanelGlueTests`), and the controller maps them to
   cancel, move and window mode (`OverlayControllerTests`). Not covered: whether the window
   server routes keys to a `.nonactivatingPanel` that called `makeKey()` while Snap is inactive.
3. Hover a Quick Access card, then press Esc: the card closes. Move the pointer off the card and
   type: keys reach the frontmost app again. Do it once with a single card and once with two or
   more cards, and watch the remaining cards for a one-frame flicker when the pointer leaves.
   Covered offscreen: the panel is asked to take keys only while a card is hovered, and closing
   the hovered card by Esc, close button, drag-out or auto close hands them back while other
   cards stay (`QuickAccessControllerTests.thePanelTakesKeysOnlyWhileACardIsHovered` and
   `closingTheHoveredCardAnyWayHandsTheKeysBack`). The panel hands the keys back by ordering
   itself out and front again, never by calling `resignKey()`: the AppKit header documents
   `resignKeyWindow` as an override point that must not be invoked directly, since it only
   informs the window and leaves key focus in place
   (`PanelGlueTests.handingTheKeysBackOrdersThePanelOutAndFrontInsteadOfResigningKey`, and the
   lint rule `no_direct_key_notifications`). Not covered: that the window server gives key focus
   to the frontmost app when Snap's key panel is ordered out, and that ordering it out and front
   in the same turn does not flash the cards. If the cards flash, report it.
4. Click just above the top card, inside the panel but where it is transparent: the click lands
   in the window below. Covered offscreen: the panel is non-opaque with a clear background and no
   window shadow, and every pixel of its content above the stack and its 40 pt shadow margin
   renders with alpha 0 in light and dark, while the card itself is opaque
   (`PanelGlueTests.thePanelIsFullyTransparentAboveTheStack`). Not covered: the window server's
   alpha hit test that passes such a click to the window below.
5. Drag a card thumbnail into Finder, Mail or a chat app: the PNG is dropped there, and Snap's
   history copy is still there afterwards. Covered offscreen: the drag offers only `.copy`, inside
   and outside the app, and its pasteboard writer puts exactly one file URL to the history PNG on
   the pasteboard (`PanelGlueTests.theDragOffersOnlyACopyOfTheHistoryFile`); an accepted drop
   closes the card and a cancelled one keeps it (`QuickAccessControllerTests`). Not covered: how
   the receiving app handles the drop.
6. With a card visible in the bottom-left corner, press Cmd+Shift+4 and select over it, then
   Cmd+Shift+3: neither PNG contains the card, and with Hide desktop icons on, neither shows the
   desktop icons. `snap.log` should have no "excluding Snap by app" line.

## Milestone 2

`scripts/accept.sh m2` checks the ten criteria below (design section 20) and prints one `PASS`,
`FAIL` or `SKIP` line per criterion with the measured numbers, also for a PASS. It exits 1 on
any FAIL and writes its logs, every fresh `SNAP_HOME` and `results.tsv` to
`build/accept/<timestamp>/`.

```sh
SNAP_SCRATCH="$TMPDIR/snap-check" scripts/accept.sh m2
SNAP_SCRATCH="$TMPDIR/snap-check" scripts/accept.sh m2 AC-M2-4 AC-M2-10   # only these
```

The same rules hold as for milestone 1: nothing shows a window, takes focus, captures the screen,
records audio, asks for a permission, plays a sound or uses the network. Every `snapctl`,
`snapbench` and `Snap --shot` process gets its own `SNAP_HOME` below the run folder and
`SNAP_NO_UPDATES=1`, and every process the script starts is stopped by PID when it exits.
Recording is measured only through `snapctl record --fake`, which drives the real
`RecordingController` with `FakeRecordingSource` (synthetic frames written by `AVAssetWriter`)
and a fake clock. A threshold that is not met is reported with its number, never loosened.

### AC-M2-1: all gates green

**Criterion.** `SNAP_SCRATCH=$TMPDIR/snap-check SNAP_NO_UPDATES=1 scripts/check.sh` exits 0 with
every M1 and Sparkle gate, plus: swiftlint `--strict` with `screen_capture_only_in_system`
extended to `SCStream`, `SCRecordingOutput`, `SCStreamConfiguration`, `SCContentFilter` and
`AVCaptureDevice` (allowed only in `Sources/SnapSystem`); the plist gate finding
`NSMicrophoneUsageDescription` equal to "Snap records your microphone only during a screen
recording you start with the microphone turned on."; `otool -L` showing that `snapctl` and
`snapbench` link neither ScreenCaptureKit nor Sparkle; no em or en dashes.

**How it is checked.** The run starts with AC01 (`check.sh`, logs in `build/check/`). AC-M2-1
passes when AC01 passed and, read again independently: the rule's regex in `.swiftlint.yml`
names all five identifiers and its `included` paths leave out `Sources/SnapSystem`; `plutil`
reads the exact microphone string from the built bundle; `otool -L` of the release `snapctl` and
`snapbench` mentions neither ScreenCaptureKit nor Sparkle; the dash gate's log says no dashes.

### AC-M2-2: milestone 1 still holds

**Criterion.** `scripts/accept.sh offline` prints PASS for AC01, AC02, AC03, AC04 and AC05 in the
same run.

**How it is checked.** Group `m2` runs the five offline criteria itself (the same functions as
group `offline`, so their lines appear in the output and in `results.tsv`) and passes when all
five recorded PASS.

### AC-M2-3: required suites present and passing

**Criterion.** `swift test` output (fresh `SNAP_HOME`, `SNAP_NO_UPDATES=1`) has a passing suite
line and no failure for each of PinBoardTests, HistoryStoreV2Tests, HistoryQueryTests,
AllInOneStateTests, SettingsMigrationTests, RecordingPlanTests, RecordingControllerTests,
VideoProbeTests, AnnotationM2Tests, MeshGradientTests, BlurredBackgroundTests, PinControllerTests,
HistoryWindowModelTests, QuickAccessVideoCardTests and AllInOneToolbarTests, each with at least
3 tests. A missing suite is a FAIL, and the log has no failure mark at all.

**How it is checked.** The test log is `build/check/test.log` from this run's `check.sh` (else
`swift test` runs here). Each suite needs a `✔ Suite <name> passed` line and no failed line; the
log must contain no `✘` at all and end with a passing `Test run with` summary. The number of
tests per suite comes from `swift test list --skip-build` on the same build (lines
`<Target>.<Suite>/<test>()`) and must be at least 3.

### AC-M2-4: recording through the fake source

**Criterion.** Measured with `snapctl record --fake` and `snapctl probe`:

- (a) `--target area --display 2560x1440@2 --rect 330,150,640,400 --frames 90 --fps 30 --json`
  leaves `history/<id>/` with `item.json` kind video, state complete, and an mp4 that probes as
  codec avc1, 1280x800, 3.00 s within 0.05 s, 90 frames within 1, playable; a 1280x800 poster PNG
  with luminance stddev at least 4; an event log where `itemWritten` comes before `started` and
  `firstFrame`.
- (b) The same with `--codec hevc` probes as hvc1.
- (c) `--display 2560x1440@1 --rect 330,150,641,401` gives 640x400 (even sizes).
- (d) `--audio system,microphone` gives exactly 1 audio track.
- (e) `--kill-after-frames 30`, then `snapctl history recover --json`, leaves that item in state
  interrupted, and `snapctl history list --json` shows no complete item whose file probes
  unplayable.
- (f) `--countdown 3` ticks 3, 2, 1 one second apart in fake time (within 10 ms) with
  `firstFrame` at or after 3.0 s; a run cancelled with Esc writes no folder.
- (g) `--runs 20` at 1280x800 and 90 frames: confirm to recording p95 under 50 ms and stop to
  card ready (poster and complete `item.json` written) p95 under 500 ms.

**How it is checked.** Each case runs in its own fresh `SNAP_HOME`. `item.json` is read from the
path the report gives; the mp4 is probed by a separate `snapctl probe <file> --json` (AVFoundation
reading, independent of the writer); the poster's size and stddev come from `shot-stats`. For (e)
a complete 90 frame recording and the killed one share a home, so the listing has a complete
item whose file is probed. For (f) tick times are taken relative to the first tick, and the
Esc run (`--press-esc` at the first tick) must report `cancelled` with the same folder count
before and after; the home then holds exactly one folder. For (g) the report's
`confirmToRecording.p95Ms` and `stopToCardReady.p95Ms` are compared with 50 and 500 ms, and all
20 runs must be complete.

### AC-M2-5: history at scale

**Criterion.** After `snapctl history gen --items 200 --days 5 --seed 7`, `snapctl history sweep
--now <the fixture's now> --skip <the fixture's first old id> --json` removes exactly the fixture
manifest's expected ids (every item older than 72 h except the skipped one); `snapctl history
list --runs 20 --json` over the remaining items reports p95 under 50 ms; `--query "notes today"`
and `--kind video` return exactly the manifest's expected ids; version 1 `item.json` files in the
fixture list as kind image, state complete.

**How it is checked.** The `history gen --json` manifest gives `now`, `skipID`, `timeZone`,
`oldIDs`, `expectedSweptIDs`, `remainingIDs`, `version1IDs` and the expected ids of each query.
The expected sweep must equal the old ids minus the skipped one, and the sweep's `removed` ids
must equal it as a set. The list commands run with `--now` set to the manifest's time and `TZ`
set to its time zone, so "today" means the fixture's day. The listed ids must equal
`remainingIDs`, `timing.p95Ms` must be under 50, the two queries must return exactly their
expected ids, and every remaining version 1 item must list as image and complete.

### AC-M2-6: annotate redaction and the new tools

**Criterion.** Measured with `snapctl annotate` and `shot-stats`: on `gen-fixture block-2x` a
black-out region inside the red block reads (0, 0, 0) within 1/255 on every channel over its
whole area, so no pixel keeps the fixture red; a pixelate region over the block edge is made of
uniform cells at least 8 px wide; on `gen-fixture noise-2x` a 200x200 px blur region has
luminance stddev at most 25% of the same region's in the input; a document with three steps and
the second deleted reports step numbers 1 and 2 and draws two circles whose center pixels are
the step color; a freehand item's path midpoint pixel is the stroke color.

**How it is checked.**

1. Black-out over 100, 100, 150 x 100 pt (inside the red block at 50, 50 to 350, 250 pt). The
   region in pixels comes from `annotate --report`; `shot-stats` reports its largest red, green
   and blue values, which must all be at most 1.
2. Pixelate over 320, 233, 60 x 40 pt, so the block's right edge (x 350 pt) and bottom edge
   (y 250 pt) fall inside cells. `shot-stats --cells` finds, on every row and column of the
   region, the runs of identical pixels and reports the shortest run that is not cut by the
   region's edge. At least one row must have such a run, and the shortest along x and along y
   must be 8 px or more.
3. Blur over a 200x200 px region of the noise fixture: the region's luminance stddev after
   divided by before must be at most 25%.
4. Steps at 420, 80, at 480, 180 and at 540, 300 pt in #0A84FF, the second deleted, and a
   freehand stroke in #34C759, all on the white part of block-2x. The report must list step
   numbers [1, 2] and two step items. Each circle's fill pixel (the report's `fill` point, 0.38
   of the diameter right of the center and clear of the digit) must be #0A84FF within 3/255;
   where the deleted step was, the pixel must not be. The freehand path's midpoint pixel must be
   #34C759 within 3/255. Ruling (2026-10-25): the criterion's "center pixels" is read as the
   circle's fill clear of the digit, because the design puts the white number at the center
   (D71). The exact center pixel is still printed, for information only.

### AC-M2-7: background additions

**Criterion.** Measured with `snapctl beautify` and `shot-stats`: `--background mesh:haze` on
block-2x twice gives byte-identical PNGs (same SHA-256) of 712x512, and the 2x2 px regions 2 px
inside each canvas corner are within 3/255 per channel of the Haze grid's corner colors;
`--background blurred` on noise-2x gives 1256x856 with the luminance stddev of a 16 px band of
the padding at most 50% of the input image's stddev; AC02's four sizes are unchanged.

**How it is checked.** The Haze corners are the grid's corner entries in `MeshGradients.swift`:
top-left #A5B4FC, top-right #F0ABFC, bottom-left #99F6E4, bottom-right #FDE68A. The padding band
is the top 16 px of the canvas over its full width (the card starts 28 px down). AC02's four
renders (noise-2x 1256x856, block-2x 712x512, without auto-balance 1312x912, ratio 16:9 910x512)
run again with the default preset.

### AC-M2-8: HUD latency and state

**Criterion.** `snapbench latency --fake --mode hud --runs 50 --display 5120x2880@2
--capture-delay-ms 0 --json` (the real `OverlayController` in HUD mode without panels) reports
p95 under 20 ms to present, under 30 ms to frozen ready and under 30 ms from confirm to card,
every run in the order present, frozen, confirm, card; the restored last area equals the stored
rect exactly; the same with `--record` requests no frozen capture in any run.

**How it is checked.** `stages.present`, `stages.frozen` and `stages.card` p95 against 20, 30
and 30 ms; each of the 50 runs' `order` must start with present, frozen, confirm, card (encode,
history and clipboard follow); each run's `restoredArea` must equal `hud.storedArea`. The
`--record` run (50 runs) must report `frozenCapturesRequested` 0 in every run and
`hud.noFrozenCaptureRequested` true.

### AC-M2-9: background screenshots of every M2 surface

**Criterion.** `scripts/shots.sh m2` exits 0 and writes 22 PNGs to `build/shots` (pin, history,
history-empty, hud, recording-countdown, recording, quick-access-video, annotate-tools,
background-mesh, settings-recording, menu-m2, each light and dark) at exactly 2x the point sizes
of design 20.11; each has luminance stddev at least 4; each light/dark pair differs by at least
40/255 in mean luminance over the scenario's first region in `docs/mockup/m2/regions.tsv`;
`lsappinfo front` is unchanged around every launch and `winlist` never sees an on-screen window
of the shot PID.

**How it is checked.** The bundle is the one `check.sh` just built (or `bundle.sh --release` when
AC-M2-1 did not run). `shots.sh m2` exits 3 when the frontmost app changed and 4 when a window
appeared; the script also compares `lsappinfo front` around the whole run. Each PNG must be newer
than the run's start, its size must be twice the scenario's points, and its stddev at least 4.
The first region of each scenario (points, top-left origin) is doubled to pixels for the
light/dark comparison.

| Scenario | Points | Pixels |
|---|---|---|
| pin, hud, recording-countdown, recording | 1280 x 800 | 2560 x 1600 |
| history, history-empty | 760 x 560 | 1520 x 1120 |
| quick-access-video | 600 x 760 | 1200 x 1520 |
| annotate-tools | 1100 x 720 | 2200 x 1440 |
| background-mesh | 920 x 640 | 1840 x 1280 |
| settings-recording | 480 x 690 | 960 x 1380 |
| menu-m2 | 420 x 600 | 840 x 1200 |

### AC-M2-10: shots match the mockup

**Criterion.** For each of the 22 PNGs, `swift scripts/shot-stats.swift --compare
build/shots/<scenario>-<theme>.png docs/mockup/png/m2/<scenario>-<theme>.png --grid 32 --regions
docs/mockup/m2/regions.tsv --scenario <scenario>` reports equal pixel sizes, a grid mean absolute
luminance difference of at most 20/255 and a 90th percentile of at most 48/255, and every named
region's mean luminance within 24/255 of the mockup's. The run prints all measured numbers; a
threshold that cannot be met is reported, not loosened.

**How it is checked.** `--compare` cuts both images into square cells, 32 across and as many
rows as fit (80 px cells on a 2560 px shot), takes each cell's mean Rec. 709 luminance, and
reports the mean, the 90th percentile (nearest rank) and the largest absolute difference. Each
named region of the scenario (points times 2) gets its mean luminance in both images and the
difference. The JSON of every comparison is kept as `acm2-10-<scenario>-<theme>.json` in the run
folder. It checks layout, light and dark, and the weight of each surface, not text rendering or
blur, which the user reviews by eye.

### Hands-on checks for the user, milestone 2 (not automated)

No agent may show a window, record the screen, open the microphone or post input events, so the
window server's and the devices' part of these behaviours is left for the user. Snap's own part
of each is covered by the suites named. Check them once after installing the M2 build, with
another app frontmost:

1. **Pin resize, pinch and click-through.** Capture an area, hover the card and press P: the pin
   opens over the captured spot at 100%. Drag an edge and a corner: the aspect stays locked and
   the size chip shows. Pinch and press Cmd+= and Cmd+-: 10% steps around the pointer, never under
   48 pt on the short side; Cmd+0 returns to 100%. Press 5, then scroll: opacity 50% then 5% steps,
   never under 20%. Press L: clicks pass through to the window below and the lock badge shows;
   unlock it from the menu's Pinned Captures submenu. Covered offscreen: `PinBoardTests`,
   `PinControllerTests`. Not covered: the borderless non-activating panel's live resize and
   pinch, and `ignoresMouseEvents` routing.
2. **History Quick Look.** Open Capture History from the menu, select a tile and press Space:
   Quick Look opens with the system zoom; arrow keys move the selection. Return shows the card
   again without changing the clipboard; Cmd+Delete moves the item to the Trash with no dialog.
   Covered offscreen: `HistoryWindowModelTests`. Not covered: `QLPreviewPanel` control.
3. **HUD keys.** Press Cmd+Shift+5: the last area comes back with handles above the toolbar.
   Press 1, 2 and 3, R, Tab, the arrows, then Return to capture and Esc to cancel. Covered
   offscreen: `AllInOneStateTests`, `AllInOneToolbarTests`, `OverlayControllerTests` and
   `snapbench latency --mode hud`. Not covered: key routing to the overlay panel while another
   app is active.
4. **A real 5 s recording without the microphone.** Cmd+Shift+5, R, Return: the countdown shows
   3, 2, 1; Esc during it cancels and leaves nothing in history. Record about 5 s of an area,
   then click the red timer: the video card shows the poster and the duration, Copied is on and
   pasting into Finder copies the mp4; Open plays it. The outline sits just outside the area and
   is not in the video. Covered offscreen: `RecordingControllerTests`, `RecordingPlanTests`,
   `VideoProbeTests`, `QuickAccessVideoCardTests`, AC-M2-4. Not covered: ScreenCaptureKit and
   `SCRecordingOutput` themselves.
5. **The same with the microphone.** Turn on Record microphone in Settings > Recording: macOS
   asks once. Record 5 s while speaking, with Record system audio on as well: the file plays
   with one audio track carrying both. With access denied, Settings shows the warning row and a
   recording is saved without the microphone. Not covered: whether macOS mixes the two sources
   (design 20.15); the offline mix export is tested.
6. **The timer stop paths.** Start a recording and stop it each way: a plain click on the timer,
   Cmd+Shift+5, the Stop Recording shortcut (set one in Settings > Shortcuts), Stop Recording in
   the Option-click menu, Cancel Recording (the item goes to the Trash), Quit Snap from the menu
   (the file is finished before Snap quits) and sleeping the Mac (the file is finished on sleep).
7. **Interrupted recovery after a forced quit.** Start a recording and force quit Snap from
   Activity Monitor. Relaunch: the item shows in history with the Interrupted pill and offers
   only Reveal and Move to Trash; it is swept with the rest after 3 days.
