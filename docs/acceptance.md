# Snap milestone 1 acceptance

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

## AC01: all gates green

**Criterion.** `SNAP_SCRATCH=$TMPDIR/snap-check scripts/check.sh` exits 0. It runs the release
build, `swift test` with a fresh `SNAP_HOME`, `swiftlint --strict` (including the rule that
ScreenCaptureKit and `CGRequestScreenCaptureAccess` appear only in `Sources/SnapSystem`),
`otool -L` showing that `snapctl` does not link ScreenCaptureKit, `scripts/bundle.sh --release`,
`codesign --verify --strict`, `plutil -lint` with `CFBundleIdentifier` `dev.sdusteric.snap` and
`LSUIElement` true, `codesign -d -r-` containing `identifier "dev.sdusteric.snap"` and
`Apple Development`, and no em or en dashes.

**How it is checked.** `accept.sh` runs `scripts/check.sh` with the same `SNAP_SCRATCH` and
passes when it exits 0. Each gate's output is in `build/check/<gate>.log`; the run's copy of the
whole output is `build/accept/<timestamp>/check.log`.

## AC02: Beautify matches the preset geometry

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

## AC03: logic suites present and passing

**Criterion.** `swift test` output shows SelectionGeometryTests, WindowHitTesterTests,
CoordinateSpaceTests, FileNamerTests, QuickAccessStackTests, HotkeyConflictTests,
PermissionStateTests, AnnotationModelTests, BeautifyRendererTests and CaptureCoordinatorTests,
each with at least one passing test and no failure. A missing suite counts as FAIL.

**How it is checked.** The script reads `build/check/test.log` when AC01 wrote it in this run,
else it runs `swift test` itself with a fresh `SNAP_HOME`. Each suite must have a
`✔ Suite <name> passed` line and no `✘ Suite <name> failed` line, the log must have no `✘` line
at all, and the last `Test run with` summary must be a pass.

## AC04: background UI screenshots with no window

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

## AC05: capture-to-overlay latency with the fake capture source

**Criterion.** `snapctl latency --fake --runs 50 --display 5120x2880@2 --capture-delay-ms 0
--json` reports p95 under 20 ms from trigger to overlay present, under 30 ms to frozen image
ready, and under 30 ms from confirm to Quick Access card. In every run the event order is
present, then frozen, then confirm, then card, and only after that encode, history and clipboard.

**How it is checked.** The JSON report's `stages.present.p95Ms`, `stages.frozen.p95Ms` and
`stages.card.p95Ms` are compared with 20, 30 and 30 ms. `runDetails` must hold 50 runs, and each
run's `order` must be exactly `present, frozen, confirm, card, encode, history, clipboard`.

## Hands-on checks for the user (not automated)

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
