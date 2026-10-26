# Snap design

Date: 2026-10-24
Status: approved for M1 by the planner. The user opted out of question rounds, so every decision below is the planner's. Each one is marked **(my call)** where it appears, and all of them are collected with ids in "Decisions to review" at the end.

Snap is a macOS menu bar screenshot app for one person, written to replace CleanShot X (Setapp 5.0.1) on their Mac. It does the few things the user actually does in CleanShot, fast and without stealing focus.

## 1. Why

CleanShot's own counters on this Mac show what the user does:

| Year | Screenshots | Videos | Annotate sessions | Of which Background | Other annotate tools |
|---|---|---|---|---|---|
| 2024 | 59 | 19 | 10 | 8 | rectangle 1 |
| 2025 | 448 | 0 | 22 | 19 | crop 1 |
| 2026 (to Oct 24) | 537 | 1 | 2 | 1 | none |

Uploads: 0. Scrolling capture: 1 ever. GIF: 1 ever.

What the numbers say:

- Screenshots are the product. About 1.5 a day this year, almost all through Cmd+Shift+3, Cmd+Shift+4 and Cmd+Shift+5.
- After a capture the user works from the Quick Access Overlay and the clipboard (`afterScreenshotActions = [0, 1]`: show the overlay, copy to the clipboard). Drag-out closes the overlay item (`deletePopupAfterDragging = 1`). Saves go to ~/Downloads without asking.
- The Background beautifier is the only editing tool used in earnest (28 of 34 annotate sessions over three years). Crop and rectangle were used once each.
- Video recording went from 19 in 2024 to 1 since. It can wait for M2.

So M1 is: area, window and fullscreen screenshots, the Quick Access Overlay, clipboard and save, the Background beautifier with the user's own preset as the default, a small annotate editor, a menu bar item, settings and hotkeys.

## 2. Goals

1. The overlay appears the moment the hotkey is pressed. Hotkey to a visible selection overlay in under 50 ms at p95 on this Mac; a frozen, pixel-exact image behind it shortly after (section 6.6).
2. Never steals focus from the app being captured. The selection overlay, the Quick Access Overlay and every prompt after the first-run onboarding are non-activating panels.
3. Never loses a capture. Every capture is written to a local history folder before anything else can fail, and kept for 3 days.
4. One-click Background with the user's saved CleanShot preset values as the default (padding 21, inset 21, corner radius 0.12, shadow 32, center alignment, auto-balance on), drawn on original backgrounds.
5. Same hotkeys as today: Cmd+Shift+3 fullscreen, Cmd+Shift+4 area, Cmd+Shift+5 window in M1 (all-in-one in M2), with a clean hand-over from CleanShot.
6. One self-contained, signed .app whose Screen Recording grant survives rebuilds.

## 3. Non-goals

- Cloud upload, share links, any account or sync.
- Scrolling capture, OCR (text recognition), GIF export in M1. Scrolling capture and OCR are not planned at all; GIF is an M2 maybe.
- Screen recording in M1 (it is M2).
- Mac App Store distribution, sandboxing, other users' Macs. Snap targets this one Mac (macOS 27, Apple Silicon).
- Matching CleanShot feature for feature, or reusing any CleanShot artwork, text or assets.

## 4. Anti-goals

These are failures, not missing features. Each has a guard in the design.

- **A capture that misses the moment because the app is slow to respond to the hotkey.** Overlay panels are created at launch and only ordered front on the hotkey; the dim layer shows before the capture finishes; the capture never waits on PNG encoding, the clipboard or disk. Latency is logged on every capture and measured headless with a fake capture source (sections 6.6 and 14).
- **Stealing focus from the app being captured.** No `NSApp.activate` outside the onboarding and settings windows and the annotate editor. Overlays are `.nonactivatingPanel` panels. Background screenshots and acceptance check that the frontmost app is unchanged.
- **Losing a capture.** The PNG is written to `SNAP_HOME/history` (atomic write, temp file then rename) right after the capture is cropped, before the clipboard, the save folder or the overlay timer. Auto close never deletes the history copy. Retention is 3 days.
- **Anything that phones home.** No network code at all. A lint rule rejects `URLSession`, `NWConnection` and `import Network` in `Sources/`. No analytics, no crash reporter. The one exception, added after M1, is Sparkle 2 auto-update in the app target only (app-updates `CONTRACT.md`); it never starts in tests, shots, tools or with `SNAP_NO_UPDATES=1`.
- **Repeated permission nags.** `CGRequestScreenCaptureAccess` is called at most once per install, from a button the user presses. After that Snap only shows a small non-modal hint when a hotkey is pressed while permission is missing (section 13).

## 5. Architecture overview

```
 Carbon hotkey (main thread)
        |
        v
 CaptureCoordinator (SnapCore, protocols only)
   |-- OverlayPresenter.show(mode)        panels already exist; order front, dim layer, crosshair
   |-- CaptureSource.captureDisplays()    live: ScreenCaptureKit; fake: generated images
   |-- WindowSource.snapshot()            live: CGWindowList; fake: canned list
   |       (both run in parallel; the overlay is visible before either returns)
   v
 Selection (area or window) -> crop of the frozen image, or a single-window capture
   v
 CaptureResult -> QuickAccess card shown first
               -> background queue: PNG encode, history write, clipboard, optional save
```

- `SnapCore` holds the pipeline and every piece of pure logic. It knows ScreenCaptureKit, Carbon and AppKit only through protocols, so the same coordinator runs in the app, in `snapctl` and in tests.
- `SnapSystem` holds the live implementations: ScreenCaptureKit capture, the CGWindowList window source, Carbon hotkeys, the symbolic hotkey reader, the pasteboard writer and the permission probe. It is the only target allowed to import ScreenCaptureKit or call `CGRequestScreenCaptureAccess` (a lint rule enforces it).
- `SnapUI` holds the views and panels, `@MainActor` by default, and depends only on `SnapCore`.
- `Snap` (the app) wires live implementations into the coordinator. `snapctl` wires fakes and never links `SnapSystem`.

## 6. Capture pipeline

### 6.1 Displays and coordinates

- Each `NSScreen` is matched to an `SCDisplay` by `deviceDescription["NSScreenNumber"] == SCDisplay.displayID` (verified: both report display 4 here).
- `CGWindowList` bounds and `SCDisplay.frame` use a global top-left origin in points; `NSScreen.frame` uses a bottom-left origin. `CoordinateSpace` in `SnapCore` converts with `y_cg = primaryHeight - (y_ns + h)` and is unit tested with fake screen layouts.
- The brief describes a 3440x1440 ultrawide; on the day of this design the Mac reported one 5K panel at 2560x1440 points, scale 2 (`system_profiler`). An ultrawide at 3440x1440 is usually scale 1. Every scale-dependent path (crop, DPI, loupe, beautify units) is tested with fake displays at 2560x1440@2 and 3440x1440@1, and with both side by side **(my call)**.
- The display list is cached and refreshed on `NSApplication.didChangeScreenParametersNotification`. Overlay panels are rebuilt at the same moment.

### 6.2 Frozen capture with the overlay first

The order of events on a hotkey **(my call)**:

1. The Carbon handler records the event time and calls `CaptureCoordinator.begin(mode)`.
2. The coordinator orders the pre-built overlay panels front, one per screen, showing the 0.38 black dim and the crosshair over the live screen. Mouse events now go to Snap, so a drag that starts right away is not lost to the app underneath.
3. In parallel: ScreenCaptureKit captures every display, excluding Snap's own panels and (when the setting is on) Finder's desktop-icon window; `CGWindowListCopyWindowInfo([.optionOnScreenOnly])` takes the window list for hit-testing.
4. When a display's image arrives, its panel draws the frozen image 1:1 under the same dim. Live and frozen pixels look the same, so the swap is invisible unless something was moving.
5. A selection made before the frozen image arrives is kept; the crop waits for the image.

Why the overlay goes first: the capture time of ScreenCaptureKit on this Mac is unknown (no capture was allowed during research), and a capture-first design would make the user wait for it before the crosshair appears.

Capture details:

- API: `SCScreenshotManager.captureScreenshot(contentFilter:configuration:)` (macOS 26) with `SCScreenshotConfiguration`, `dynamicRange = .sdr`, `showsCursor = false`, and width and height set from `filter.contentRect * filter.pointPixelScale`. Snap writes files itself rather than using `fileURL`, so it controls DPI and color profile **(my call)**.
- Filter: `SCContentFilter(display:excludingWindows:)` with Snap's overlay windows and the Finder desktop-icon window. `SCShareableContent` is fetched with `excludingDesktopWindows: false`, otherwise the icon window would not be in the list to exclude.
- The shareable content is cached between captures and refreshed in the background after each capture, on screen changes and when Finder relaunches. If a capture fails with a stale filter, the coordinator refetches once and retries. If Snap's freshly shown panels are missing from a cached list, the coordinator refetches before the capture; if they are still missing, it falls back to `SCContentFilter(display:excludingApplications:[Snap], exceptingWindows:[])` and logs that desktop icons were not hidden.
- Color: the image keeps the display's color space (Display P3 here) and the PNG embeds the ICC profile **(my call)**. No sRGB conversion in M1.
- `CGWindowListCreateImage` and `CGDisplayCreateImage` are not used: they are obsoleted in macOS 15 and fail to compile for a macOS 27 target (verified).

### 6.3 Hiding desktop icons

`captureWithoutDesktopIcons = 1` in CleanShot, so this is on by default. Snap excludes the window owned by `com.apple.finder` whose `windowLayer` equals `CGWindowLevelForKey(.desktopIconWindow)` (verified as -2147483603 on this Mac through CGWindowList). The wallpaper is a separate window owned by "Wallpaper" and stays in the capture. No system setting is changed, and no cover window is drawn. Unverified: that `SCWindow.windowLayer` reports the same value; the fallback is matching by `windowID` against the CGWindowList entry at that layer.

### 6.4 Fullscreen (Cmd+Shift+3)

Captures the display under the mouse pointer with the same filter, with no selection overlay. The result goes straight to the Quick Access Overlay **(my call: one display, not one file per display)**.

### 6.5 Window capture

- Window mode is entered with Cmd+Shift+5 in M1 or by pressing Space or Tab in the area overlay.
- Hit-testing uses the window list snapshot from step 3: layer 0, alpha above 0, at least 40x40 points, not owned by Snap. The menu bar and the Dock are also selectable, as in CleanShot (they are matched by their own layers). The topmost window containing the pointer wins. `WindowHitTester` in `SnapCore` is pure and tested with fake lists, including the alpha-0 Finder helper windows seen on this Mac.
- On click, Snap captures that one window live with `SCContentFilter(desktopIndependentWindow:)`, transparent background (`shouldBeOpaque = false`), and the system shadow included (`ignoreShadows = false`), matching `transparentWindowBackground = 1` and `captureWindowShadow = 1`. Option-click inverts the shadow setting for that capture. The output size comes from `filter.contentRect * pointPixelScale`, since the shadow makes it larger than the window frame.
- Window titles are not needed for hit-testing. The highlight label shows the owner name when CGWindowList provides it, and nothing otherwise. Permission is never inferred from missing names.

### 6.6 Latency targets

| Stage | Target | How it is measured |
|---|---|---|
| Hotkey event to overlay panels ordered front | p95 under 50 ms | App: Carbon event time to the `CATransaction` completion after `orderFrontRegardless`, logged per capture. Headless: `snapbench latency --fake`. |
| Hotkey event to frozen image drawn | p95 under 250 ms (unverified on real hardware) | App log only. |
| Confirm (mouse-up or click) to Quick Access card shown | p95 under 60 ms | App log; headless with the fake path. |
| Headless fake path, 5120x2880@2 display, capture delay 0 | p95 under 20 ms to `present`, under 30 ms to frozen ready, under 30 ms confirm to card | `snapbench latency --fake --runs 50 --json` (acceptance AC05): the real overlay and Quick Access controllers without panels. |

Rules that keep these numbers: overlay panels and their layers are built at launch; the frozen `CGImage` is handed to a layer as `contents` without a redraw; PNG encoding, history write and pasteboard work run on a background queue after the card is shown; nothing on the hotkey path touches the disk. The coordinator records an ordered event log (`present`, `frozen`, `confirm`, `card`, `encode`, `history`, `clipboard`) that tests assert on, so a change that moves encoding ahead of the card fails a test.

The app writes one line per capture to `SNAP_HOME/logs/snap.log`: `latency mode=area overlay_ms=.. frozen_ms=.. card_ms=..`. The user can read real numbers there; agents never produce them, since agents never capture the screen.

## 7. Area selection overlay

- Window: one borderless `NSPanel` per screen, `[.borderless, .nonactivatingPanel]`, level `.screenSaver`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `canBecomeKey = true`, `becomesKeyOnlyIfNeeded = false`, `hidesOnDeactivate = false`, clear background, `.accessory` activation policy. Built at launch and kept ordered out.
- Drawing: a custom layer-backed `NSView` drawing with Core Graphics. Before a drag the whole screen is dimmed (black, 0.38, see 17.6). During and after a drag the selection is cut out of the dim (even-odd fill) and shows the bright image. Selection border: 1 pt white with a 1 pt black hairline at 0.3 outside.
- Crosshair: full-screen 1 pt lines in white at 0.62 with a 0.3 black hairline, drawn on half-pixel offsets, with an 8 pt gap at the pointer, shown only before the drag (hidden from mouse down). The system cursor is hidden while the overlay is up and restored on every exit path (confirm, cancel, error, screen change).
- Size label: during the drag it is the caption under the magnifier (chip, 22 pt tall, radius 11, `W × H` in points, tabular digits). With instant capture off, a chip of the same style sits 8 pt under the selection after mouse up. Visual details are in 17.6.
- Magnifier: a 120 pt circle showing 15 x 15 physical pixels at 8 pt each with nearest-neighbour scaling, drawn from the frozen image (nothing until it arrives), with a 1.5 pt accent square on the centre pixel and a caption chip: `x, y` before the drag, `W × H` during it. Sits 24 pt down and right of the pointer before the drag; during the drag it sits on the side of the pointer away from the selection and flips at edges. Hidden on mouse-up.
- Key hints: a bottom-center chip bar (17.6), shown before the drag and in window mode, for the first 10 captures only (setting "Show key hints").
- Instant capture: on by default; mouse-up confirms **(my call, for speed: about 1.5 captures a day, almost never adjusted)**. With it off, the rectangle stays editable with 8 handles, and Return or a double-click inside confirms.
- Keys: Esc or right-click cancels. Space while dragging moves the rectangle. Shift constrains to a square. Option resizes from the centre. Arrow keys nudge 1 point, Shift+arrow 10 points; Cmd+arrow resizes by 1 point. Tab switches between area and window mode.
- Pixel grid: the selection snaps to whole pixels of the display's scale. `SelectionGeometry` (pure) owns normalize, clamp to the starting display, snap, nudge, aspect and axis lock, resize from centre, and the point-to-pixel crop rect. A drag cannot cross displays; it is clamped to the display where it started.
- Minimum size: a selection under 4x4 points on mouse-up counts as a click; in area mode a click with no drag captures the window under the pointer if there is one, else cancels **(my call, CleanShot-like)**.
- Sound: off by default, a quiet shutter if turned on. Never played in tests.

## 8. Quick Access Overlay

- Panel: one non-activating `NSPanel`, borderless, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`, transparent, `hidesOnDeactivate = false`. It hosts a SwiftUI stack of cards and is anchored to the bottom-left corner of the screen under the pointer at the time of capture, 16 pt inside `visibleFrame` **(my call: CleanShot's prefs have no position key, so its left-side default stands)**. Corner is a setting.
- Size: `popupSize = 2` maps to Medium: thumbnail box 240x220 pt, aspect-fit, minimum height 96. Small and Large are 180 and 300 pt wide. Card padding 8, so a Medium card is 256 pt wide. Card radius 16, `.regularMaterial`, 0.5 pt edge stroke, one soft shadow (17.5). Thumbnail radius 8 (concentric with the card) on a solid `thumbnailBacking` (#F0F0F2 light, #2E2E31 dark, the mockup's `fill2`) for transparent window captures and the letterbox of a tall capture.
- Resting state: thumbnail, a dimension pill (`842 × 516`, 11 pt on black 0.58) at its bottom-left, and a "Copied" chip top-right for 2 s.
- Hover: a 0.20 black scrim over the thumbnail (no scale). Top-left: Close. Bottom-center control bar: split button **Background** (main part applies the default preset, chevron opens the editor), then icon buttons **Annotate**, **Save**, **Copy** with tooltips. Copy turns into a check mark for 900 ms, then the card closes (close after Copy or Save is on by default). Reveal in Finder appears in the bar after a save. Copy is not the primary action because the clipboard already holds the image.
- Keyboard: the panel becomes key only while the pointer is over it, so Snap never takes Esc away from other apps. On a hovered card: C copy, S save, A annotate, B background, Delete or Esc close. Option-C, or Option-click on Copy, is Copy File (section 9); while Option is held the Copy button shows a document icon and the tooltip "Copy File (⌥C)".
- Drag-out: the thumbnail is an AppKit drag source (`NSViewRepresentable` wrapper). It drags a file URL to the item's current PNG in `SNAP_HOME/history/<id>/`, named with the file pattern, as an `NSDraggingItem(pasteboardWriter: url as NSURL)`. `draggingSession(_:sourceOperationMaskFor:)` returns `.copy` outside the app so Finder never moves Snap's copy. A drop that is not `.none` closes the card (`deletePopupAfterDragging = 1`); a cancelled drag keeps it.
- Auto close: 15 s per card (`popupAutoCloseInterval = 15`, `popupAutoCloseMode = 1`), paused while hovered or dragging, restarted from the full interval on mouse exit. A 2 pt `tertiaryLabelColor` line at the bottom of the card shows the time left, only during the last 5 s and only when not hovered.
- Stack: newest card at the corner edge, older ones pushed away, 8 pt apart, at most 5 and at most 70% of `visibleFrame` height (the oldest is closed when a sixth arrives or the stack gets too tall; its file is in history). `QuickAccessStack` (pure, injected clock) owns order, timers, pause and resume.
- Dismiss: close button, Esc on hover, auto close, a swipe or drag toward the near screen edge (past 80 pt or faster than 400 pt/s), or a successful drag-out. Dismiss, entry and Reduce Motion follow the motion table in 17.7.

## 9. Clipboard and file output

- Clipboard (on after every capture, `afterScreenshotActions` item 1): one `NSPasteboardItem` with `public.png` data written eagerly and `public.tiff` supplied lazily through `NSPasteboardItemDataProvider`, because a 5K TIFF is about 59 MB **(my call)**. The PNG carries the DPI, so it pastes at point size (verified: a 144 DPI PNG on a pasteboard reads back as 200x100 points from 400x200 pixels). "Copy file" (Option on the card's Copy button, or Option-C on a hovered card) writes the URL of the item's current PNG in history instead.
- PNG: ImageIO with `kCGImagePropertyDPIWidth/Height = 72 * scale` (verified: 144 DPI writes a 5669 px/m `pHYs` chunk and `NSImage` reads it at half the pixel size) and the ICC profile of the image's color space.
- File name: default pattern `Snap {yyyy}-{MM}-{dd} at {HH}.{mm}.{ss}`, giving `Snap 2026-10-24 at 14.03.22.png`, with ` 2`, ` 3` on collisions **(my call)**. Tokens: `{yyyy} {MM} {dd} {HH} {mm} {ss} {counter} {app}`. Dots, not colons, in the time. `FileNamer` is pure and tested.
- History (the "never lose a capture" guard): every capture is written to `SNAP_HOME/history/<id>/<file name>.png` by temp file and rename, plus `item.json` (time, mode, display scale, source app when known). Edited versions (Background, annotate) are written next to it as `<file name> (edited).png`. Retention is 3 days, swept at launch and hourly **(my call: `historyCapacity = 3` read as 3 days)**. Menu bar "Recent Captures" lists the last 3.
- Save: copies the item's current PNG to the save folder (default ~/Downloads, `popupAskForDestinationWhenSaving = 0`, so no panel), atomically, with the collision suffix. Saving is not automatic in M1, matching `[0, 1]`; "Save to folder" is an optional after-capture action in settings.

## 10. Background beautifier

### 10.1 Model

```
BackgroundPreset {
  id, name,
  background: .gradient(GradientID) | .solid(RGBA) | .image(path, blur) | .none,
  padding: Double        points, 0...120     default 21
  inset: Double          points, 0...80      default 21
  cornerRadius: Double   fraction, 0...1     default 0.12
  shadow: Double         0...100             default 32
  ratio: nil | (w, h)                        default nil (free)
  alignment: 0...8       row-major 3x3        default 4 (centre)
  autoBalance: Bool                          default true
}
```

Presets are stored in `SNAP_HOME/presets.json`. The starred preset is the default. The first-run default uses the user's CleanShot values above with the gradient "Dusk" in place of CleanShot's built-in image `bg16`, which is not reused **(my call)**.

### 10.2 Geometry (the spec that `snapctl` checks)

Input: an image of `W x H` pixels at scale `s` (from its DPI: 144 gives 2, none or 72 gives 1). Points: `Wp = W / s`, `Hp = H / s`.

1. Unit: `u = clamp(min(Wp, Hp) / 600, 0.5, 3.0)`. Padding and inset are multiplied by `u` so a preset looks the same on a small window shot and a full-screen shot **(my call)**. `P = padding * u`, `I = inset * u`.
2. Edge analysis: the border colour is the most common colour among the image's outermost pixels (per channel tolerance 6 of 255). The border is "uniform" when at least 90% of border pixels match it. Content bounds are the smallest rectangle containing every pixel that does not match the border colour.
3. Inset: the screenshot is placed on a "card" filled with the border colour, with `I` on every side. If the border is not uniform, `I = 0` (padding the edge of a photo with a guessed colour looks wrong) **(my call)**. My reading of CleanShot's inset: it adds room inside the rounded card using the screenshot's own edge colour; its `calculatedInsets` and `balanceInsets` symbols point that way. This is a definition for Snap, not a confirmed copy.
4. Auto-balance (on, uniform border only): the image is first trimmed to its content bounds, so uneven blank margins disappear and the content sits with exactly `I` on all four sides. Off: the whole image is used and the original margins stay.
5. Card size: `Cw = contentW + 2I`, `Ch = contentH + 2I` (points), where content is the trimmed or whole image.
6. Corner radius: `R = min(cornerRadius * 100 * u, min(Cw, Ch) / 2)` points. 0.12 gives 12 pt on a 600 pt shot **(my call: the stored 0...1 value is read as a slider position up to 100 pt, since 12% of the shorter side would make window shots look like pills)**. Window captures with transparent corners keep their alpha inside the card.
7. Canvas: free ratio gives `(Cw + 2P) x (Ch + 2P)`. With a ratio, the shorter side grows until the ratio holds; the canvas never shrinks below the padded size. Alignment places the card in the free space (0 top-left ... 4 centre ... 8 bottom-right) and only matters with a ratio.
8. Pixels: the canvas is rendered at scale `s`, so the output is `round((Cw + 2P) * s) x round((Ch + 2P) * s)` pixels, written at the same DPI as the input.
9. Shadow under the card, drawn before it with `CGContext.setShadow`: opacity `0.10 + 0.40 * shadow/100`, blur `(12 + 36 * shadow/100) * u`, y offset `(6 + 18 * shadow/100) * u` downward, black; plus a contact shadow at opacity 0.12, blur `3u`, offset `1u`. At 32 that is about 0.23 opacity, 23.5u blur, 11.8u offset. A 1 px inner stroke on the card edge, black at 0.08, keeps light content distinct from light backgrounds.
10. Background: gradient, solid, image (aspect-fill, optional blur 0 to 40) or none (transparent canvas).

Worked examples (used by acceptance AC02), all inputs 1200x800 px at 144 DPI, so `s = 2`, `Wp x Hp = 600 x 400`, `u = 0.667`, `P = I = 14` points:

| Input | autoBalance | Card (pt) | Output (px) |
|---|---|---|---|
| A: diagonal noise, no uniform border | on | 600 x 400 (I = 0) | 1256 x 856 |
| B: white with a red block at px (100, 100) to (700, 500), margins 50/250/50/150 pt | on | 300 + 28 by 200 + 28 = 328 x 228 | 712 x 512 |
| B | off | 628 x 428 | 1312 x 912 |
| B, ratio 16:9, alignment 4 | on | 328 x 228 | 356 x 256 grows to 455.1 x 256: 910 x 512 |

`render(image, preset, scale) -> CGImage` is one function in `SnapCore`, used at reduced scale for previews and full scale for output. It is Core Graphics only, so it runs headless in `snapctl` and tests.

### 10.3 Backgrounds, all original and drawn in code

- Gradients (12, linear 135 degrees): Dusk #5B6CFF to #B65BFF (default), Citrus #FFB347 to #FF5E62, Lagoon #2BC0E4 to #3A7BD5, Mint #6EE7B7 to #3B82F6, Rose #FF9A9E to #FAD0C4, Ember #F12711 to #F5AF19, Slate #334155 to #0F172A, Aurora #00C9A7 to #845EC2 to #FF6F91, Sand #F5E6CC to #E3C9A0, Ocean #0F2027 to #2C5364, Orchid #C471F5 to #FA71CD, Fog #E5E7EB to #9CA3AF.
- Solids (10): white, #F5F5F7, light gray, #1C1C1E, black, #0A84FF, #30D158, #FF9F0A, #FF375F, #BF5AF2, plus a colour well for any custom colour.
- Own image: "Choose Image..." with `NSOpenPanel`; Snap is not sandboxed, so it stores the path. Missing file falls back to the default gradient.
- None: transparent canvas, for pasting onto slides.
- No bundled image assets in M1. "Blurred screenshot" as a background is M2.

### 10.4 One-click action and the editor

- One click on Background (card button, B key, or menu "Apply Background to Last Capture") renders with the default preset, writes the edited PNG to history, cross-fades the thumbnail (160 ms), updates the size pill and restarts the card timer. Copy, Save and drag then use the edited image. A second click restores the original. Option-click, or the chevron on the card's Background button, opens the editor.
- Editor: a floating utility `NSPanel`, 920 x 640, 300 pt sidebar on the right plus a live preview (aspect-fit on a checkerboard, re-rendered at preview scale, coalesced to one render per frame). Sections: Background (Gradient, Color, Image, None tabs; 36 pt swatches, radius 8, 6 columns, 2 pt accent ring on the selected one), sliders with numeric fields for Padding, Inset, Corner radius (0 to 100%), Shadow; Ratio menu (Auto, 1:1, 4:3, 3:2, 16:9, 9:16, 1.91:1); a 3x3 alignment grid of 20 pt squares, dimmed when the ratio is Auto; Auto-balance toggle. Top of the sidebar: preset popup (Save Preset..., Set as Default, Delete). Footer: Reset, Save, Copy (default button). This panel activates Snap, since it takes text and slider input; it is opened only by the user.

## 11. Annotate editor (minimal)

Used 34 times in three years, almost only for Background, so M1 keeps it small **(my call)**.

- Window: a standard titled `NSWindow` with a unified 52 pt toolbar (17.6), centred, sized to fit the image at up to 80% of the visible frame, minimum 560x400. It activates Snap (an editor needs keyboard focus). Fit to window by default; Cmd+0 toggles 100%; pinch zoom 25% to 800%.
- Tools in M1: Select (V), Crop (C), Rectangle (R), Arrow (A), Text (T), Pixelate (P). Then a colour well (default #FF3B30), stroke width 2, 4 or 7 (default 4), Undo, Redo, Background (opens the panel from section 10.4 on the current image), Copy, Save.
- Crop: 8 handles, outside dimmed 0.5, Return applies, Esc cancels, Shift keeps the ratio, snaps to image edges within 6 px. Non-destructive until export.
- Rectangle: stroke, radius 4, Option for 0.2 fill, Shift for a square. Arrow: straight line with a filled head 4.5x the stroke width, Shift snaps to 45 degrees. Text: click to place, 30 pt semibold system font (`annotateLastTextSize = 30`), plain or on a pill. Pixelate: cell size about 1/12 of the region's shorter side, minimum 8 px, flattened at export so the original pixels under the region are not in the file.
- Model: `AnnotationDocument` in `SnapCore` (original image ref, crop rect, ordered items with kind, geometry, colour, width, text), with pure hit-testing, move, resize, delete, duplicate and flattening through Core Graphics and Core Image (`CIPixellate`). Undo through `UndoManager` in the view layer, built on value snapshots of the document.
- Copy (Cmd+C) puts the flattened image on the clipboard; Save (Cmd+S) writes to the save folder with a 1.5 s "Saved to Downloads" toast and a Reveal link; Shift+Cmd+S opens a save panel. Closing never prompts, since the original is in history.
- Deferred to M2: Highlight, blur and black-out styles, numbered steps, freehand.

## 12. Menu bar, settings and hotkeys

### 12.1 Menu bar

`NSStatusItem` with the template symbol `viewfinder`, standard `NSMenu` built from a pure `MenuModel` (titles, key equivalents, enabled state) so the shot mode can render the same items:

1. Capture Area (Cmd+Shift+4)
2. Capture Window (Cmd+Shift+5)
3. Capture Fullscreen (Cmd+Shift+3)
4. separator
5. Apply Background to Last Capture (no default hotkey)
6. Open Last Capture in Annotate (no default hotkey)
7. Recent Captures: last 3, each with a 32 pt thumbnail and a time; clicking one shows its Quick Access card again. "Open History Folder".
8. separator
9. A status line when something needs attention: "Screen Recording needs your OK" (design 20.16), or "Waiting for CleanShot X to quit to take over its shortcuts".
10. Settings... (Cmd+,), Quit Snap (Cmd+Q)

### 12.2 Settings

A SwiftUI `TabView` in a custom `NSWindow`, 480 pt wide, grouped `Form` with group headings, four tabs (General, Capture, Quick Access, Shortcuts):

- **General:** Launch at login (`SMAppService.mainApp`, off by default, never touched by tests), save folder (default ~/Downloads), file name pattern with live preview, sound on capture (off).
- **Capture:** after-capture actions in order: Show Quick Access Overlay (on), Copy to clipboard (on), Save to folder (off), Open in Annotate (off). Instant capture on mouse-up (on). Hide desktop icons (on). Window shadow (on). Magnifier (on). Crosshair (on).
- **Quick Access:** corner, size (Small, Medium, Large; Medium), auto close toggle and seconds (15, range 3 to 60), close after drag-out (on), close after Copy or Save (on), default Background preset with "Edit...".
- **Shortcuts:** recorder fields for the five actions with conflict warnings and the CleanShot notice.
- The Capture tab also holds "Show key hints" (on for the first 10 captures).

Settings live in `SNAP_HOME/settings.json`, not `UserDefaults`, so one environment variable isolates all state **(my call, as in Reel)**.

### 12.3 Hotkeys and the hand-over from macOS and CleanShot

- Registration: Carbon `RegisterEventHotKey` on the application event target. It needs no Accessibility or Input Monitoring permission (verified: it registers from a command-line process).
- Defaults: Cmd+Shift+3 fullscreen, Cmd+Shift+4 area, Cmd+Shift+5 window mode. In M2 Cmd+Shift+5 becomes the all-in-one HUD, as in CleanShot.
- macOS: on this Mac the system shortcuts for Cmd+Shift+3, Cmd+Shift+4 and Cmd+Shift+5 are already disabled (`com.apple.symbolichotkeys` 28, 30 and 184 have `enabled = 0`). Ctrl+Cmd+Shift+4 (31) is still enabled; Snap does not use it. `HotkeyConflicts` reads `CopySymbolicHotKeys()` at launch and whenever Snap's settings window opens, and shows a warning in settings and the menu for any enabled system shortcut that matches one of Snap's combos, naming the exact place to turn it off. Snap never rewrites the system plist.
- CleanShot: it uses the same three combos (`LAVAtakeFullscreen`, `LAVAtakeArea`, `LAVAtakeAllInOne`, all key code 20, 21 or 23 with mods 768). Two processes registering the same combo both get success (verified), and which one receives the key is unknown. So while a process with bundle id `com.getcleanshot.app-setapp` or `pl.maketheweb.cleanshotx` is running, Snap does not register the conflicting combos. It shows "Waiting for CleanShot X to quit" in the menu and registers them when `NSWorkspace.didTerminateApplicationNotification` reports CleanShot gone **(my call)**. Snap never quits or signals CleanShot.
- A failed registration (`eventHotKeyExistsErr` and others) is shown next to the shortcut in settings, never as an alert.

## 13. Screen Recording permission

- The grant is keyed by bundle id plus the designated requirement. Snap is signed with the one valid Apple Development identity, pinned by SHA-1 `1EDDD87FAAACC222585E8C76E983DB798EC38331` (verified on this Mac to be the only valid codesigning identity), with no hardened runtime, no entitlements and `--timestamp=none`. The designated requirement then names the bundle id and the certificate, not a cdhash, so the grant survives rebuilds. Ad-hoc signing is never used for the app.
- One copy of the app lives in `~/Applications/Snap.app`. The build copy in `build/bundle` is never launched as an app.
- Onboarding: at launch Snap calls `CGPreflightScreenCaptureAccess()` (no prompt). If false and `state.json` has no `screenRecordingRequested`, it shows one onboarding window (17.6, never modal, with "Skip for now") explaining why, with a button that calls `CGRequestScreenCaptureAccess()` once and records the date. After that it never calls the request again. It deep-links to the Screen Recording pane of System Settings, and re-checks the preflight when Snap's settings or menu opens. If capture still fails after a grant, the onboarding window offers "Relaunch Snap".
- Hotkey while denied: a small non-activating panel near the pointer, "Screen Recording needs your OK" and "Turn on Snap in Screen & System Audio Recording." (wording of 20.16) with an "Open System Settings" button. It auto-closes after 6 s. No modal alert, no repeated request.
- Lapses: a capture error, including `SCStreamErrorUserDeclined` (-3801), marks the permission as unknown, shows the same small panel once, and logs it. This covers the monthly "Continue to Allow" re-approval, whose behaviour on macOS 27 is unverified.
- `PermissionState` in `SnapCore` is a pure state machine (preflight result, requested flag, last error, app activation) with an injected preflight closure, so the "at most one request" rule is a unit test.

## 14. Files and data

`SNAP_HOME` (default `~/Library/Application Support/Snap`) holds all state, so tests and shots isolate everything with one variable **(my call, Reel's pattern)**:

```
SNAP_HOME/
  settings.json     settings (section 12.2)
  presets.json      Background presets
  state.json        first-run and permission flags, last capture id
  history/<id>/     capture PNG, edited PNG, item.json; 3-day retention
  logs/snap.log     events, errors and latency lines; rotates at 5 MB, never sent anywhere
```

- When `SNAP_HOME` is set to anything other than the default, the default save folder becomes `$SNAP_HOME/Saved` instead of ~/Downloads, so no test or shot can write to the user's Downloads even if a settings file is missing **(my call)**.
- Writes are atomic (temp file in the same directory, then rename). Stores surface or log errors; `try?` is banned in `*Store*.swift` by lint.

## 15. Package layout

One SwiftPM package, `swift-tools-version: 6.4`, `platforms: [.macOS(.v27)]`, Swift 6 language mode, no Xcode project; `scripts/bundle.sh` assembles the .app **(my call, as in Reel and Haul)**.

```
Package.swift
CLAUDE.md                       build, test and safety rules for agents
VERSION                         0.1.0
.swiftlint.yml
resources/Info.plist.in         LSUIElement true, LSMinimumSystemVersion 27.0
scripts/check.sh                all gates
scripts/bundle.sh               build, sign by SHA-1, optional --install
scripts/make-icon.swift         generated icon
scripts/shots.sh                background screenshots
scripts/winlist.swift           on-screen windows of one PID (CGWindowList)
scripts/shot-stats.swift        PNG size and luminance statistics
scripts/accept.sh, scripts/accept-lib.sh
Sources/SnapCore/               Foundation, CoreGraphics, ImageIO, CoreImage. No AppKit.
  Model/        DisplayInfo, WindowInfo, CapturedImage, CaptureMode, CaptureItem, SnapPaths,
                Settings, SettingsStore, StateStore, PresetStore, HistoryStore, Log
  Geometry/     SelectionGeometry, CoordinateSpace, WindowHitTester
  Output/       PNGWriter, FileNamer
  Beautify/     BackgroundPreset, Gradients, EdgeAnalysis, BeautifyRenderer
  Annotate/     AnnotationDocument, AnnotationItem, Flattener
  Pipeline/     CaptureSource, WindowSource, OverlayPresenter, Clock protocols,
                CaptureCoordinator, LatencyLog
  Logic/        QuickAccessStack, HotkeyCombo, HotkeyConflicts, PermissionState, MenuModel
  Fakes/        FakeCaptureSource, FakeWindowSource, FakeClock, SyntheticImages
Sources/SnapSystem/             ScreenCaptureKit, Carbon, AppKit pasteboard. Nonisolated by default.
                LiveCaptureSource, LiveWindowSource, HotkeyCenter, SymbolicHotkeys,
                PasteboardWriter, PermissionProbe, ConflictingApps
Sources/SnapUI/                 AppKit and SwiftUI, MainActor by default, depends on SnapCore only.
  Overlay/      OverlayPanel, SelectionOverlayView, MagnifierLayer, OverlayController
  QuickAccess/  QuickAccessPanel, QuickAccessCardView, ThumbnailDragView, QuickAccessController
  Background/   BackgroundEditorView, SwatchGrid, AlignmentGrid, BackgroundEditorPanel
  Annotate/     AnnotateWindowController, AnnotateCanvasView, AnnotateToolbar, TextEditingOverlay
  Settings/     SettingsView, ShortcutRecorder, SettingsWindowController
  Menu/         StatusMenuController, MenuPreviewView
  Shared/       Theme (spacing, radii, motion), PermissionHintPanel, OnboardingView
Sources/Snap/                   app executable, MainActor by default
                main.swift, AppDelegate, AppWiring, ShotMode, ShotScenarios
Sources/snapctl/                headless CLI, depends on SnapCore only
                main.swift, BeautifyCommand, FixtureCommand, PresetCommand
Sources/snapbench/              headless latency bench (AC05), SnapCore and SnapUI, no SnapSystem
                main.swift, LatencyBench
Tests/SnapCoreTests/, Tests/SnapSystemTests/, Tests/SnapUITests/
```

- `SnapCore` has no AppKit dependency, so logic and renderer tests run in milliseconds and `snapctl` stays headless.
- `SnapUI` talks to capture, hotkeys and the pasteboard only through protocols in `SnapCore`; the app injects the `SnapSystem` implementations. The UI can be built and shot against fakes.
- Only `SnapUI` and `Snap` use `.defaultIsolation(MainActor.self)`.
- `snapctl` must not link ScreenCaptureKit: `check.sh` verifies with `otool -L`.
- Swift Testing: `@Suite struct XTests`, `@Test func descriptiveName()`.
- Lint (swiftlint `--strict`, custom rules only, as in Reel): no `try!` in Sources; no `try?` in `*Store*.swift`; no `URLSession`, `NWConnection` or `import Network`; no em or en dashes; and `ScreenCaptureKit`, `SCShareableContent`, `SCScreenshotManager`, `CGRequestScreenCaptureAccess` only under `Sources/SnapSystem/`.
- Comments only for the non-obvious, one or two lines. `@unchecked Sendable` only at a documented boundary (the Carbon callback box).

`snapctl` commands:

- `gen-fixture <name> --out <png>`: writes the synthetic test inputs (noise, white with red block, transparent-corner window, 1x and 2x variants).
- `beautify <in.png> --out <out.png> [--preset default|<json>] [--background solid:#RRGGBB|gradient:<name>|mesh:<name>|blurred|none] [--ratio W:H] [--no-autobalance] [--report]`: renders with the same `BeautifyRenderer` and, with `--report`, prints JSON geometry (unit, padding, inset, card rect, radius, canvas size, uniform border flag).
- `preset --default --json`: prints the first-run default preset.
- `latency --fake --runs N --display WxH@S [--capture-delay-ms D] --json`: runs `CaptureCoordinator` with fakes and a recording presenter; prints p50, p95 and max for each stage and the event order of every run.

## 16. Test strategy

Rules for every test, script and agent run:

- Agents never capture the real screen. No test, script or shot calls ScreenCaptureKit, `CGRequestScreenCaptureAccess`, `screencapture` or `CGWindowListCreateImage`. Live capture code is exercised only by the user running the installed app.
- No test or shot shows a window, activates an app or triggers a permission prompt. No `open`, no osascript, no LaunchServices registration.
- Every test sets a fresh `SNAP_HOME` from `mktemp`; the default save folder then lives inside it.
- Pasteboard tests use a private `NSPasteboard(name:)`, never the general pasteboard.
- No sound.
- Processes are tracked and stopped by PID; temp dirs are deleted only by the exact path `mktemp` printed.

**Fakes.** `FakeCaptureSource` synthesizes a gradient-and-grid image per fake display at its scale (1x and 2x, including 5120x2880), with an optional delay. `FakeWindowSource` returns canned front-to-back lists, including alpha-0 helpers and windows at other layers. `FakeClock` drives timers.

**Unit suites (required by acceptance AC03):**
- `SelectionGeometryTests`: normalize, clamp to a display, pixel snapping at 1x and 2x, nudge, Shift square, Option from centre, point-to-pixel crop.
- `WindowHitTesterTests`: topmost wins, layer and alpha filters, minimum size, own PID skipped, menu bar and Dock.
- `CoordinateSpaceTests`: NSScreen and top-left conversions across two displays of different scale and height.
- `FileNamerTests`: pattern tokens, collision suffixes, no colons.
- `HotkeyConflictTests`: symbolic hotkey entries and running CleanShot gate registration as designed.
- `QuickAccessStackTests`: ordering, max 5, 15 s auto close, pause on hover, restart on exit, close after drag.
- `PermissionStateTests`: at most one request, hint after denial, lapse handling.
- `AnnotationModelTests`: add, move, resize, delete, crop, flatten removes original pixels under pixelate.
- Also: `BeautifyRendererTests` (the section 10.2 table), `CaptureCoordinatorTests` (event order: `present` before `frozen`, `card` before `encode`, `history` before `clipboard`), `PNGWriterTests` (pHYs and ICC), `StoreTests`, `PasteboardWriterTests` (private pasteboard), `SymbolicHotkeysTests` (parsing an injected dictionary).

**Image checks by pixel statistics, not golden files.** Renders are checked by size, alpha at named points, colour at named points, and mean or deviation of luminance in named regions, so font smoothing or material changes do not break them.

**Background screenshots without a window.** The app binary has a shot mode: `Snap.app/Contents/MacOS/Snap --shot <scenario> --appearance light|dark --out <png>`. It never calls `NSApplication.run`, never creates an `NSWindow` or `NSPanel`, never touches `SnapSystem`'s live types, and renders with fakes. Verified on this Mac for this design: a plain `NSView` tree containing an `NSHostingView` renders through `cacheDisplay(in:to:)` with no window, `NSApplication.shared.windows` stays empty, the frontmost app is unchanged, and setting `appearance` on the root view changes the result (hosting region mean luminance 115 light, 34 dark). A layer `backgroundColor` was not captured by `cacheDisplay`, so views draw their backgrounds in `draw(_:)` or SwiftUI. Reel verified `ImageRenderer` with `.regularMaterial` and SF Symbols headless.

Scenarios, each in light and dark, rendered at 2x:

| Scenario | Content | Size (pt) |
|---|---|---|
| `overlay-area` | fake desktop, dim, cut-out selection, magnifier with size caption (and `overlay-before`, `overlay-window` variants) | 1280 x 800 |
| `quick-access` | fake desktop corner with three cards: resting, hovered, closing with countdown | 600 x 760 |
| `background-editor` | editor panel with a sample capture and the default preset | 920 x 640 |
| `annotate` | editor window content with a rectangle, arrow, text and pixelate item | 1100 x 720 |
| `menu` | `MenuPreviewView` built from the same `MenuModel` as the real menu | 280 x 500 |
| `settings` | Capture tab (and Shortcuts) | 480 x 690 |
| `onboarding` | step 1 and step 2 states, hint panel | 520 x 500 |

The menu shot is a rendering of the menu model, not of `NSMenu` itself, which cannot be drawn without showing it **(my call)**. `scripts/shots.sh` runs each scenario as a direct exec of the bundle binary (never `open`), with a fresh `SNAP_HOME`, records `lsappinfo front` before and after (exit 3 on change), polls `scripts/winlist.swift` every 100 ms for any on-screen window of the PID (exit 4), stops only that PID, and writes into `build/shots/`.

**Gates** (`scripts/check.sh`, logs in `build/check/<gate>.log`, `SNAP_SCRATCH` for the scratch path): `swift build -c release`, `swift test` (fresh `SNAP_HOME`), `swiftlint lint --strict`, `snapctl` does not link ScreenCaptureKit, `scripts/bundle.sh --release`, `codesign --verify --strict`, `plutil -lint` and bundle id and `LSUIElement`, designated requirement names `identifier "dev.sdusteric.snap"` and the Apple Development certificate, no em or en dashes.

**Acceptance** (`scripts/accept.sh offline`): Reel's and Haul's pattern. One `PASS`, `FAIL` or `SKIP` line per criterion id, `results.tsv` in `build/accept/<timestamp>/`, exit 1 on any FAIL, a missing required test suite counts as FAIL.

## 17. Visual design

Final spec from the design pass (the orchestrator ran it with impeccable, apple-design and find-animation-opportunities). The M2 surfaces (pin, history, HUD, recording, video card, new annotate tools, mesh backgrounds, Recording settings) extend it in section 20.11 and 20.12. Mockup: `docs/mockup/index.html` (static, light and dark side by side, 1 CSS px = 1 pt), renders in `docs/mockup/png/`. Where the mockup and this section disagree, this section wins.

### 17.1 Direction

Snap is an Operate-mode utility the user sees 1.5 times a day, so the capture moment carries all the design weight and every screen after it stays quiet. Rules that decide trade-offs:

1. The screenshot is the only colorful thing. Chrome is neutral gray plus the system accent. Color comes from the user's pixels and the Background gradients.
2. The overlay path uses no blur, no material and no animation. It draws flat fills so it costs nothing at the moment the hotkey is pressed.
3. After the capture there is one obvious next step: the card shows "Copied" (the clipboard already holds the image), and Background is the one labeled button on it.
4. Windows and menus look like the system's own. Where AppKit provides a control (menu, tabs, buttons, switches, sliders), use it and do not restyle it. The mockup draws them only to show layout.
5. Elevation is declared once per surface: a 0.5 pt edge ring plus one soft shadow on floating panels, nothing on flat content.

### 17.2 Color tokens

All values are the mockup's. Use the system semantic color when one exists and treat the hex as the target look.

| Token | Light | Dark | Use |
|---|---|---|---|
| `text` (labelColor) | #1D1D1F | #F2F2F7 | Labels, names |
| `text2` (secondaryLabelColor) | #6E6E73 | #A1A1A6 | Help text, captions, shortcut glyphs |
| `text3` (tertiaryLabelColor) | #8A8A8F | #8E8E93 | Icons and the countdown line only, never text that must be read |
| `separator` | black 8% | white 8% | Hairlines |
| `separatorStrong` | black 16% | white 18% | Menu separators, vertical dividers |
| `fill` | black 5% | white 7.5% | Fields, segmented track, recorder |
| `window` | #FFFFFF | #1E1E20 | Window, toolbar |
| `sidebar` | #F6F6F8 | #242427 | Background editor controls |
| `canvas` | #E6E6EA | #141416 | Preview and annotate canvas |
| `settingsBg` / `group` | #F3F3F5 / #FFFFFF | #1E1E20 / #28282B | Settings form |
| `accent` | #007AFF | #0A84FF | System accent: window highlight, handles, selected swatch ring, default button, switch |
| `accentText` | #0068DA | #409CFF | Accent-colored text and selected tab |
| `button` | #FFFFFF with edge | white 13% | Secondary buttons, popups |
| `thumbnailBacking` | #F0F0F2 | #2E2E31 | Solid backing behind a card thumbnail that does not fill its box |
| `card` (`.regularMaterial` target) | rgba(246,246,248,.78) | rgba(44,44,47,.74) | Quick Access card, zoom pill, hint panel |
| `menu` | rgba(246,246,248,.86) | rgba(44,44,47,.84) | Menu preview only (the real menu is the system's) |
| `warning` | #B25000 text, #F08A00 dot | #FF9F0A | "Waiting for CleanShot X to quit", CleanShot notice |
| `success` | #30B350 | #30D158 | Permission granted check |
| `annotateRed` | #FF3B30 | #FF3B30 | Default annotation color |
| `dim` (overlay) | black 0.38 | black 0.38 | Selection overlay, same in both modes |
| `chip` (overlay, card controls) | rgba(28,28,30,.84), white text, 0.5 pt ring white 18% | same | Size caption, hint bar, window label, card buttons, dimension pill (black .58) |
| `crosshair` | white 62% with a black 30% hairline | same | Pre-drag guide lines |

Contrast: `text2` on white is 5.1:1 and on #1E1E20 is 6.5:1. White on the accent button is 4.0:1 (light) and 3.6:1 (dark), the macOS default, so button labels are 13 pt medium, never smaller. Chips hold 15:1.

### 17.3 Type

SF Pro through the system font. No custom fonts. Use `font-variant-numeric: tabular-nums` equivalents (`monospacedDigitSystemFont`) for every number that changes.

| Role | Size / line | Weight | Where |
|---|---|---|---|
| Title | 22 / 28, tracking -0.015 em | semibold | Onboarding heading |
| Headline | 14 / 20 | semibold | Onboarding step titles, hint panel title |
| Body | 13 / 18 | regular, medium for emphasis | Rows, labels, menu items, buttons |
| Group heading | 13 / 18 | semibold | Settings and editor group headings |
| Caption | 12 / 16 | regular or medium | Hints, help text under rows, card button label (semibold) |
| Caption small | 11 to 11.5 / 15 | regular | Settings help text, menu recent time |
| Chip | 11 / 22, tabular | medium | Size caption, coordinates, dimension pill |
| Annotation text | 30 pt | semibold | Annotate text tool (`annotateLastTextSize`) |

### 17.4 Spacing, sizes, radii

4 pt grid: 4, 8, 12, 16, 24. Radii are concentric: an inner radius equals the outer radius minus the padding between them.

| Item | Value |
|---|---|
| Quick Access card | 256 wide at Medium (240 thumbnail + 8 padding), radius 16, thumbnail radius 8, gap between cards 8, inset from `visibleFrame` 16 |
| Card chips | Copied chip 22 high; dimension pill 18 high, radius 9; close button 22 circle; control bar 32 high, capsule |
| Overlay chip | 22 high, radius 11, padding 0 9; hint bar 30 high, radius 15 |
| Magnifier | 120 pt circle, 15 x 15 physical pixels at 8 pt each with a 0.5 pt black 14% pixel grid, 2 pt white ring plus 1 pt black 30% ring, centre square 1.5 pt accent with a 1 pt white inner line, caption chip 12 pt below; during a drag it shows the dim and the selection edge as the overlay does; it flips 8 pt before a screen edge |
| Selection border | 1 pt white, 1 pt black 30% outside |
| Window highlight | 2 pt accent border, accent 14% fill, radius 14 (macOS window corners are about 16), label chip 34 pt above the window, or inside the top edge when there is no room |
| Controls | Buttons 24 high, capsule (AppKit regular push button); popups 24 (28 full width in the editor); segmented 22 high; switches 36 x 20 |
| Swatches | 36 x 36, radius 8, 6 columns, 8 gap, selected ring 2 pt accent at 4 pt offset |
| Background editor | Window 920 x 640, sidebar 300 (padding 16 20), preview fills the rest with 28 padding (radius 4, 0.5 pt edge, shadow 0 14 36 -10 black 40%, caption 11 pt), headings 14 above and 8 below (18 under the preset popup), slider rows 28 apart, value fields 40 x 22 on `fill`, 12 pt, footer separated by a hairline with padding 12 20 16 |
| Annotate | Window 1100 x 720 default, toolbar 52, tool buttons 34 x 26 in a segmented group |
| Settings | 480 wide, toolbar tabs 76 x 52 with 4 between them, selected tab radius 10, form padding 20, group radius 10, row min height 40 (padding 8 12), 16 between groups, heading 6 above and 8 below |
| Onboarding | 520 wide, padding 32, app icon 64 (radius 14.4), step padding 16, step icon 36, footer 12 by 20 |
| Hint panel | 500 x about 64, radius 16, 12 padding |
| Menu | 280 wide, padding 6, row 24 (recent capture rows 42 with a 32 x 32 thumbnail, radius 6), radius 12 (the system draws it) |

### 17.5 Materials

- Quick Access card, zoom pill and hint panel use `.regularMaterial` (not Liquid Glass, which did not render headless for Reel). Light card edge: 0.5 pt black 12%. Dark: 0.5 pt white 14%. Shadow: 0 14 32 -8 black 34%.
- Under Reduce Transparency the card, zoom pill and hint panel become opaque `window` color.
- Overlay chips and the selection overlay never use a material (rule 2). The hover control bar on the card uses a 16 pt blur over the thumbnail because it sits on arbitrary image content and is not on the hotkey path.
- Windows (Background editor, annotate, settings, onboarding) use the system window material and shadow. Do not draw a custom shadow.
- Thumbnails get a 0.5 pt inner black 18% stroke so a white screenshot keeps its edge on a light card.

### 17.6 Surfaces

**Selection overlay** (mockup sections 1a, 1b, 1c). One panel per screen, drawn with flat layers.
- Pre-drag: whole screen dimmed black 0.38 (0.38 and not the 0.45 of the first draft, so the user can still read the screen they are about to capture). Crosshair: 1 pt lines in `crosshair` across the whole screen with an 8 pt gap at the pointer, shown only before the drag. Magnifier 24 pt down and right of the pointer with a caption chip `x, y` (point coordinates). Hint bar at the bottom center, 28 pt above the edge of the screen: "Drag to capture", `Tab` Window, `Esc` Cancel.
- Dragging: the selection is cut out of the dim and shows the bright image. The crosshair and the hint bar are gone (hidden, not faded, on mouse down). The magnifier stays beside the pointer and its caption becomes the size (`640 × 400`, points, tabular). The magnifier sits on the side of the pointer away from the selection's center and flips at screen edges, so it never covers the content being selected. There is no separate size label while instant capture is on.
- Instant capture off: after mouse up the selection keeps 8 handles (8 pt circles, white fill, 1.5 pt accent border) and a size chip sits 8 pt under it (above when there is no room). Return confirms.
- Window mode: the window under the pointer gets the highlight, the label chip (`Notes | 842 × 516`, owner name and size), and the hint bar changes to "Click to capture", `Tab` Area, `⌥` Toggle shadow, `Esc` Cancel. The highlight jumps between windows with no easing.
- Hints: shown for the first 10 captures, then off. Setting "Show key hints" brings them back.
- The system cursor is hidden while the overlay is up (section 7).

**Quick Access card** (mockup section 2).
- Resting: thumbnail with the dimension pill bottom-left (`842 × 516`, `914 × 588` after Background) and a `Copied` chip top-right (check in #5BE37D, 12 pt) for the first 2 s, then it fades out.
- Hover: scrim black 0.20 over the thumbnail, the dimension pill and chip fade out, a close button appears top-left (22 pt circle chip, x 11 pt), and a control bar appears bottom-center: a split button `Background | chevron` (`rectangle.center.inset.filled`, a capture centered in its backdrop, 12 pt semibold label; the main part applies or removes the default preset, the chevron part opens the editor), then icon buttons Annotate (pencil), Save (download) and Copy (copy), each 28 wide with a tooltip showing its key. The bar is 211 pt wide, so it fits Medium and Large. At Small (180) the labels are dropped and all four buttons are icons.
- Dragging the thumbnail: the system drag image is the thumbnail at 0.45 scale with radius 6, rotated -2 degrees, with a lifted shadow. The card thumbnail scales to 1.03 until the drag ends. A drop target shows its own highlight.
- Countdown: not visible for the first 10 s. In the last 5 s a 2 pt `text3` line grows in at 3 pt from the card's bottom edge (inside the 8 pt padding) and shrinks linearly to nothing at close. Hover pauses it and hides it.
- Stack: newest card nearest the corner, 8 pt between cards, at most 5, and the oldest also closes when the stack would be taller than 70% of `visibleFrame` height.
- Keys on a hovered card: `C` Copy, `⌥C` Copy File, `S` Save, `A` Annotate, `B` Background, `Delete` or `Esc` close.

**Background editor** (mockup section 3). Titled utility window, 920 x 640, title "Background", no toolbar. Left: preview on `canvas`, composition centered and aspect-fit, no checkerboard except for the None background, a caption under it `914 × 588 pt · 1828 × 1176 px`. Right sidebar, top to bottom: preset popup (star, name, "Default"); "Background" heading, segmented Gradient | Color | Image | None, 12 swatches in 2 rows; "Spacing" heading with Padding, Inset, Corners, Shadow (label 54, slider, 40 pt value field); "Canvas" heading with Ratio popup, 3 x 3 Align grid of 18 pt squares (dimmed at 55% while Ratio is Auto), Auto-balance switch; footer: Reset (quiet) left, Save and Copy right, Copy is the default button (Return) because the next step is a paste. Esc closes. Cmd+C copies and closes too. Save writes to the save folder.

**Annotate editor** (mockup section 4). Titled window, 1100 x 720, unified 52 pt toolbar: traffic lights, then a segmented tool group (Select, Crop, Rectangle, Arrow, Text, Pixelate, 34 x 26 each, active tool in `accentText` on a raised segment), divider, color well (16 pt circle, chevron), stroke popup (2, 4, 7 shown as lines), divider, Undo and Redo; trailing: Background (secondary), Copy (secondary), Save (default). The image sits on `canvas` at 100% when it fits, with the window shadow rule from 17.5. Selected items show a 1.5 pt accent border with 8 pt handles, 2 pt clear of a rectangle's stroke so the accent never covers the annotation color; the handles sit on that border. A floating zoom pill (`Fit`) sits bottom-right, 16 pt in. Pixelate cells are 8 px and drawn blocky as in the mockup.

**Menu bar menu** (mockup section 5). Template symbol `viewfinder` in the status item (the mockup shows it highlighted while the menu is open). Standard `NSMenu` rows, 24 pt, shortcut glyphs in `text2`. Recent captures: 42 pt rows with a 32 x 32 thumbnail (radius 6), title `Screenshot HH.mm.ss` and a relative time at 11 pt. A status line row (warning color, 12 pt, a 7 pt dot) appears only when something needs attention. Menu content follows section 12.1.

**Settings** (mockup section 6). Four toolbar tabs instead of three: General, Capture, Quick Access, Shortcuts. Each tab is a grouped form with group headings. Capture tab groups: After capture (Show Quick Access card, Copy to clipboard, Save to folder, Open in Annotate), Selection (Capture on mouse release, Show magnifier, Show crosshair, Show key hints), Screen (Hide desktop icons, Include window shadow). Shortcuts tab: a warning notice when CleanShot X is running, group Capture (three recorders), group Last capture (Apply Background, Open in Annotate, both unset), and a footnote about System Settings. Quick Access tab: corner, size, auto close and seconds, close after drag-out, close after Copy or Save, default preset with Edit. General tab: launch at login, save folder, file name pattern with live preview, sound.

**First run** (mockup section 7). One window, 520 wide, app icon, "Welcome to Snap", one line, and two steps in one grouped list. Step 1 "Allow Screen Recording": the primary button "Allow Access..." (calls the one permitted request, then opens the System Settings pane) and a line naming the exact pane, "Screen & System Audio Recording". Step 2 "Take over your shortcuts": inactive until step 1 is done. Once step 1 is granted its row shrinks to a green check and "Screen Recording is on" and step 2 shows the CleanShot X state ("Waiting for CleanShot X to quit" with a warning dot, or nothing to do when CleanShot is not running). Footer: "You can change all of this later in Settings." and a quiet "Skip for now" that becomes the default button "Done" when step 1 is done. The window never blocks: Snap is usable without either step. The permission hint panel (500 wide, `card` material, warning-tinted monitor icon, "Screen Recording needs your OK", "Open System Settings") shows near the pointer for 6 s as in section 13.

### 17.7 Motion

Curves: `enter = cubic-bezier(.16, 1, .3, 1)` and `exit = cubic-bezier(.4, 0, 1, 1)` (the same as Haul). The one spring is response 0.30, damping 1.0 (no bounce, nothing here follows a flick), except the swipe release and a cancelled drag, which use damping 0.85 because they carry momentum.

| # | Moment | What moves | Duration and curve | Reduce Motion |
|---|---|---|---|---|
| M0 | Overlay appears, selection, magnifier, window highlight retargeting, hint bar hiding, cancel, confirm | Nothing animates. Layer actions are disabled (`CATransaction.setDisableActions(true)`), panels are ordered in and out with no fade. Everything follows the pointer 1:1. | 0 ms | Same |
| M1 | Card enters | translateX -24 to 0 and opacity 0 to 1; older cards move up by one card height plus 8 | Spring 0.30 / 1.0 (about 280 ms) | Opacity only, 100 ms |
| M2 | Stack reflow (card added, closed, or Background changes a thumbnail height) | Remaining cards move to their new offsets | Same spring | Instant |
| M3 | Hover in | Scrim 0 to .20, control bar opacity 0 to 1 and translateY 4 to 0, dimension pill and Copied chip fade out | 120 ms enter | Opacity only |
| M3b | Hover out | The reverse | 100 ms exit | Opacity only |
| M4 | Press on any card button | Highlight on mouse down, scale .96 | 80 ms down, 120 ms enter back | Highlight only |
| M5 | Copied chip | Appears with the card, fades out at 2 s | 160 ms | Same |
| M5b | Copy pressed on the card | Icon cross-fades to a check (scale .85 to 1), holds 900 ms, card dismisses | 120 ms enter | Cross-fade |
| M6 | Dismiss (close, Esc, auto close, after Copy or Save, after drag-out) | translateX 0 to -40 (toward the screen edge the card is anchored to), opacity 1 to 0; gap closes with M2 | 220 ms exit | Opacity only, 100 ms |
| M7 | Swipe dismiss | 1:1 with the pointer, rubber band (constant .55) away from the edge, release hands velocity to a spring; dismiss past 80 pt or 400 pt/s | Spring 0.30 / 0.85 | Snap, no overshoot |
| M8 | Drag-out | Thumbnail scale 1.0 to 1.03 and a raised shadow at drag start; a cancelled drag springs back | 140 ms enter; cancel spring 0.30 / 0.85 | No scale |
| M9 | Countdown line | Fades in at 10 s, drains linearly to 15 s; hover pauses and hides it | Fade 200 ms | Same (state indicator) |
| M10 | Background applied or removed | Thumbnail cross-fades; the pill text swaps without animation | 160 ms enter | Same |
| M11 | Background editor | Sliders, swatches, ratio, align: preview updates with no animation, at most one render per frame. Swatch ring appears in 100 ms. Window open and close are the system's. | 0 / 100 ms | Same |
| M12 | Annotate | Tool switch, drawing, undo: none. "Saved to Downloads" toast rises 8 pt and fades in, holds 1.5 s, fades out. | In 160 ms enter, out 200 ms | Opacity only |
| M13 | First run, step 1 granted | Green check scales .6 to 1 (spring 0.35 / 0.75, the one playful moment), step 2 expands | 240 ms enter | Instant |
| M14 | Permission hint panel | Fades in and rises 6 pt; fades out at 6 s | In 160 ms, out 200 ms | Opacity only |
| M15 | Menu, settings tabs, window open and close | System behavior | System | System |

Rejected motion (find-animation-opportunities, with the gate question that killed each):
- Fly-to-corner animation from the selection to the card: the overlay panels must leave at mouse up and the card appears at once; a flying image needs a full-screen click-through panel and delays the card by about 300 ms. Frequency is low (1.5 a day) but speed is the product. Rejected; revisit as an opt-in later.
- Fade-in or fade-out of the overlay dim, crosshair or hints: hotkey path, must be visible in the first frame. Rejected.
- Easing of the selection edge, loupe or window highlight: direct manipulation, easing reads as lag. Rejected.
- Per-item animation in the menu bar menu or settings rows: system controls, tens of views a month. Rejected.
- Animated Background preview transitions between swatches: the user is comparing results, so a transition hides the comparison. Rejected.
- Looping shimmer or pulse on the permission step: a nag. Rejected.

### 17.8 App icon

Unchanged: generated by `scripts/make-icon.swift`, a rounded square with a blue-to-violet gradient (#3B4CE0 to #8A4DE8 at 145 degrees) and a white viewfinder bracket (four corner arcs, 1.9 stroke at a 24 pt grid). The mockup draws it at 64 pt. Nothing from CleanShot.

## 18. Milestones

### M1: screenshots the user takes every day

- Package scaffold, shared types, `scripts/check.sh`, `scripts/bundle.sh` (bundle id `dev.sdusteric.snap`, SHA-1 signing), lint rules, `CLAUDE.md`.
- Core logic: selection geometry, coordinates, window hit-testing, file naming, stores, history, Quick Access stack, hotkey conflicts, permission state, menu model.
- Beautify renderer, presets and `snapctl beautify`, `gen-fixture`, `preset`.
- Capture pipeline: coordinator, live ScreenCaptureKit and window sources, PNG writer, pasteboard, Carbon hotkeys, CleanShot hand-over, permission probe, `snapbench latency`.
- UI: selection overlay (area and window), Quick Access Overlay with drag-out, Background editor, minimal annotate editor, menu, settings, onboarding and permission hint.
- App wiring, shot mode, `scripts/shots.sh`, `scripts/accept.sh offline`.

Acceptance criteria are in the brief returned with this design (AC01 to AC05) and repeated in the header of `scripts/accept.sh`.

### M2: recording and the rest

Designed in section 20, in this order: pin to screen, capture history window, all-in-one HUD on Cmd+Shift+5, screen recording to mp4, annotate additions (highlight, blur and black-out, numbered steps, freehand), Background additions (blurred capture, mesh gradients). GIF export, "save the last 15 seconds", self-timer and per-app presets are out of M2 (D74). Acceptance criteria AC-M2-1 to AC-M2-10 are in the M2 brief and the header of `scripts/accept.sh`.

## 19. Risks

- ScreenCaptureKit timing on this Mac is unmeasured; the overlay-first design hides it, but a slow frozen capture delays the magnifier and the crop. The latency log shows real numbers in the first week.
- Excluding Snap's freshly shown panels from the capture depends on them appearing in `SCShareableContent` at once (unverified). The fallback excludes the whole Snap app and gives up desktop icon hiding for that capture.
- Whether `SCWindow.windowLayer` reports the desktop-icon layer, and whether widgets live elsewhere, is unverified.
- Who receives a hotkey that two apps register is unknown; Snap avoids the case by waiting for CleanShot to quit.
- Non-activating panel focus, cursor hiding, drag-out into other apps and the Screen Recording onboarding all need a hands-on check by the user; no agent can show a window.
- The monthly re-approval prompt on macOS 27 is unverified; the lapse handling in section 13 is the mitigation.
- CleanShot enum meanings (`afterScreenshotActions`, `historyCapacity`, `inset`, `cornerRadius`) are inferred. Snap defines its own meanings in this document.
- Shots approximate materials; they check layout, type and appearance, not exact blur.

## 20. Milestone 2

Date: 2026-10-24. Status: design for M2, written by the planner while the user was away. Every call is marked **(my call)** where it appears and listed as D45 to D79 at the end of the document. Section 20 replaces the short M2 list that section 18 used to carry. Where section 20 and the mockup disagree, section 20 wins.

### 20.1 Scope and order

The usage numbers decide the order. Screenshots dominate (537 this year), Background is the main edit, recordings are rare (1 this year, 19 in 2024) and history held 3 days. So M2 is built in this order, each part behind its own tests and acceptance checks, so a late part can slip without holding back an earlier one **(my call, D45)**:

1. Pin to screen (20.2).
2. Capture history window (20.3, 20.4).
3. All-in-one HUD on Cmd+Shift+5 (20.5).
4. Screen recording to mp4 (20.6, 20.7).
5. Annotate additions: highlight, blur and black-out, numbered steps, freehand (20.8).
6. Background additions: blurred-capture background and mesh gradients (20.9).

Out of M2: GIF export, "save the last 15 seconds" (`SCClipBufferingOutput`), self-timer screenshots, pause and resume, trimming, a scrubbing preview on the video card, and per-app default presets (moved out of the old M2 list because the user never asked for it and it adds a settings surface) **(my call, D74)**. GIF was used once ever and is not trivial (frame sampling, palette, size limits), so it stays out.

Unchanged from M1: the overlay-first pipeline, the Quick Access card stack, "never lose a capture", one permission request per install, no network (Sparkle in the app target is the separate, documented exception in section 4), and the safety rules for agents.

### 20.2 Pin to screen

A pin is a capture floating above other windows, for reference while working: a value to copy by hand, a design to match, an error to read while fixing it.

**Entry points** **(my call, D46).**
- A Pin button on a hovered Quick Access card: a 22 pt circle chip at the top-right of the thumbnail, mirroring Close at the top-left (mockup 11c). Key `P` on a hovered card. Pinning closes the card, since the same image is now on screen; the file stays in history.
- Menu bar: "Pin Last Capture". Settings > Shortcuts: "Pin Last Capture", unset by default.
- History window: the Pin button in the footer, `P`, and the context menu.
- Recordings cannot be pinned in M2.

**Placement** **(my call, D47).** When the capture's own screen rect is known (area and window captures record it in `item.json`, 20.4) and it lies fully inside one current display's `visibleFrame`, the pin opens exactly there at 100% point size, so it lands on top of what it shows. Otherwise it opens centered on the display under the pointer, scaled down to fit 60% of that display's `visibleFrame` with the aspect kept. The frame is always clamped inside the `visibleFrame`.

**Window** **(my call, D48).** One `NSPanel` per pin: `[.borderless, .nonactivatingPanel, .resizable]`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`, `isMovableByWindowBackground = true`, `contentAspectRatio` set to the image. Opaque captures (area, fullscreen) are clipped to a radius of 8 pt and get the floating-panel elevation from 17.5 (0.5 pt edge ring plus one soft shadow). Window captures keep their own alpha and their own captured shadow: no clip, no ring, `hasShadow = false`.

**Moving, sizing, zoom.** Drag anywhere on the image to move (1:1, no easing). Drag an edge or corner to resize with the aspect locked. Pinch, or Cmd+= and Cmd+-, zoom by 10% steps around the pointer, from 10% to 400% of the point size, never smaller than 48 pt on the short side. Cmd+0 returns to 100%. During any resize or zoom a size chip sits 8 pt above the bottom edge, centered: `460 × 268 · 100%` (chip style from 17.2, tabular digits).

**Opacity** **(my call, D49).** A slider in the hover chrome, 20% to 100% in 5% steps, updated live while dragging. Keys on a focused pin: `2` to `9` set 20% to 90%, `0` sets 100%. Scroll wheel or two-finger scroll over the pin changes it by 5%. The floor is 20% so a pin can never become invisible and get lost.

**Click-through** **(my call, D50).** A toggle in the hover chrome (pointer with a slash). When on, the panel sets `ignoresMouseEvents = true`, the hover chrome can no longer appear, and an 18 pt lock badge (chip color at 0.72, 10 pt lock glyph) sits 6 pt inside the top-left corner so the user knows why clicks pass through. A click-through pin is unlocked from the menu bar: "Pinned Captures" submenu lists each pin (32 pt thumbnail, time) with Unlock, Close and a final "Close All Pins". Snap installs no global key or mouse monitor for this, so no Accessibility or Input Monitoring permission is ever needed.

**Hover chrome** (mockup 8). Appears when the pointer enters an unlocked pin, with the M3 and M3b timings from 17.7. Close: 22 pt circle chip, 8 pt inside the top-left corner. Control bar: chip capsule, 30 pt high, 8 pt inside the top-right corner, holding a 14 pt drop glyph, the 72 pt opacity slider (white track at 0.28, white fill, 14 pt knob), the value (11 pt medium, tabular, 32 pt wide), a hairline divider, the click-through toggle and a More button. More is an `NSMenu`: Copy (Cmd+C), Save (Cmd+S), Open in Annotate (A), Show in Quick Access, Reveal in Finder, Reset Size (Cmd+0), Close (Esc). For pins narrower than 260 pt the slider hides and the value becomes a scrub control (drag left or right on it); below 120 pt only Close and More remain.

**Keys** on a pin that is key (it becomes key on click, without activating Snap): Esc or Cmd+W close, Cmd+C copy the current image, Cmd+S save, A annotate, L toggle click-through, the opacity and zoom keys above.

**Lifetime** **(my call, D51).** Pins live for the session only and are not restored after a relaunch; the image is in history for 3 days and can be pinned again from there. At most 8 pins: a ninth closes the oldest. Each pin holds one decoded image (a 5K capture is about 59 MB), so 8 is also the memory ceiling. A pin keeps its image in memory, so it survives the history sweep; its Reveal item is disabled once the file is gone.

**Displays.** When a display disappears, its pins move to the center of the main display, clamped. Pins do not follow Spaces changes beyond `canJoinAllSpaces`.

**Model.** `PinBoard` in `SnapCore/Logic` (pure, injected displays): add with placement and the cap, close, move, resize with the aspect lock, zoom around a point with the clamps, opacity step and floor, click-through flag, display removal, and the list the menu shows. `PinController` in `SnapUI/Pin` owns the panels and draws nothing that `PinBoard` did not decide.

**Failure modes.** The item's PNG cannot be read: no pin, the log names the path, the card or history tile stays. The sweep removes a pinned item's folder: the pin stays, Reveal is disabled. A display layout change: relocation above.

### 20.3 Capture history window

**Purpose.** Find any capture from the last 3 days and put it back to work: show its card again, pin it, copy it, drag it out.

**Opening** **(my call, D52, D55).** Menu bar "Capture History…" (replaces "Open History Folder", which moves into the window footer), Settings > Shortcuts "Open Capture History" (unset by default). "Recent Captures" in the menu stays at 3 rows and now includes recordings. It is a standard titled `NSWindow` (it activates Snap: the user opened it and it has a search field), one instance, 760 × 560 pt by default, minimum 560 × 400, frame autosaved in `state.json`.

**Layout** (mockup 9). Unified 52 pt toolbar: title "History" (15 pt semibold) with the subtitle "Last 3 days" (11 pt, `text2`); trailing a segmented filter All | Screenshots | Recordings and a 190 × 28 pt search field, placeholder "Search by app or date". Body on `window`: sections per day, heading 13 pt semibold ("Today", "Yesterday", then "Thursday, Oct 22") with the count in `text2`, 16 pt above the grid and 10 below. Grid: tiles 164 pt wide, 16 pt column gap, 14 pt row gap, 28 pt side padding, so four columns at the default width; columns grow with the window. Tile: a 164 × 112 pt box on `thumbnailBacking`, radius 8, 0.5 pt inner stroke black 18%, the current image aspect-fit; caption 6 pt below: time (12 pt medium, tabular) and app name (12 pt, `text2`, truncated). Badges: a duration pill for recordings (bottom-left, 18 pt, black 0.58, play glyph and `0:42`), a 20 pt pencil chip top-left for edited captures, an "Interrupted" pill (warning fill) for a recording that did not finish. Selected tile: a 2 pt accent ring at 4 pt outside the box (the swatch ring rule from 17.4). Footer, 48 pt with a hairline: left "12 captures · 41 MB · kept for 3 days" (12 pt, `text2`, tabular); right Pin, Copy and the default button "Show in Quick Access". With nothing selected the three buttons are disabled.

**Interaction.** Click selects, Cmd-click and Shift-click extend. Arrow keys move the selection. Return or double-click shows the item's Quick Access card again with a fresh timer, without writing the clipboard (the user asked to see it, not to copy it). Space opens Quick Look (`QLPreviewPanel`). Cmd+C copies the image (a recording copies its file URL). `P` pins. Dragging a tile drags the file URL with `.copy`, as the card does. Cmd+F focuses search, Esc clears it. Context menu: Show in Quick Access, Copy, Pin to Screen, Open in Annotate, Reveal in Finder, Move to Trash. Cmd+Delete and Move to Trash move the item folder to the Trash with `FileManager.trashItem`, so a slip is recoverable from the Trash and needs no confirmation dialog.

**Search and filter** **(my call).** The filter picks by kind. The search text is split into words; an item matches when every word matches its app name, its file name, or one of its date words: "today", "yesterday", the weekday ("thursday", "thu"), the month day ("oct 22", "22 oct"), or a time prefix ("14", "14:0"). Matching is case and diacritic insensitive. With at most a few hundred items it runs on every keystroke with no debounce. `HistoryQuery` in `SnapCore/Logic` does filtering, matching and grouping by local day with an injected clock and calendar.

**Empty states** (mockup 9, right). No items: a 56 pt rounded square on `fill` with the history glyph, "No captures in the last 3 days" (14 pt semibold), and "Snap keeps every screenshot and recording here for 3 days. Press ⇧⌘4 to take one." with the shortcut shown as a key cap (the real current shortcut, or "Capture Area in the menu bar" when it is unset). Footer "0 captures · kept for 3 days" and "Open Folder". No search results: "No captures match “notes”" with a "Clear Search" button in the same place.

**Thumbnails.** Generated off the main thread with `CGImageSourceCreateThumbnailAtIndex`, 328 px on the long side for 164 pt at 2x, from the current PNG (or the poster for a recording), cached in an `NSCache` keyed by path and modification date. A tile shows `thumbnailBacking` until its thumbnail is ready; there is no spinner.

**Live updates.** The app posts an in-process notification when a capture is stored, edited, swept or trashed; the window reloads its list on it and on becoming key. No file system watcher.

### 20.4 History data

**The folder stays the database** **(my call, D53).** No index file. `HistoryStore.allItems()` reads each `history/<id>/item.json`; at a few hundred items this is well under the budget, and a test with 200 items enforces p95 under 50 ms for listing (AC-M2-5). There is nothing to get out of sync.

**`item.json` version 2.** New fields, all optional when decoding so version 1 files read as completed screenshots:

```
{
  "version": 2,
  "id": "20261024-140322-3f9a1c2e",
  "createdAt": "2026-10-24T14:03:22Z",
  "kind": "image" | "video",
  "mode": "area" | "window" | "fullscreen",
  "scale": 2,
  "originalName": "Snap 2026-10-24 at 14.03.22.png",
  "editedName": "Snap 2026-10-24 at 14.03.22 (edited).png",
  "sourceApp": "Notes",
  "screenRect": [x, y, w, h],              global top-left points, area and window captures (pin placement)
  "pixelSize": [w, h],
  "state": "complete" | "recording" | "interrupted",    video only
  "durationSeconds": 42.4,                 video only
  "posterName": "Snap 2026-10-24 at 14.03.22 poster.png",   video only
  "codec": "avc1" | "hvc1", "fps": 30, "audio": ["system", "microphone"]   video only
}
```

**Retention and pruning** **(my call, D54).** Retention stays 3 days, swept at launch and hourly as in M1. The sweep now skips ids that are in use: an open card, a pin, an open annotate or Background editor, the history selection being shown in Quick Access, and a recording in progress. The app passes that set to `sweep(skipping:)`; a skipped item is swept on the next run after it stops being in use. There is no size cap: recordings are rare, and a cap would break "never lose a capture" within 3 days. The history footer shows the total size so a large recording is visible.

**Recording files and temporary handling** **(my call, D61).** A recording is written straight into its own history folder; there is no separate temp folder to clean up or to lose.
1. Before the stream starts, Snap creates `history/<id>/` and writes `item.json` with `kind: video` and `state: recording`. This is the "history first" rule of section 9 applied to video.
2. `SCRecordingOutput` writes `history/<id>/<file name>.mp4` (same file name pattern as screenshots, extension `.mp4`).
3. On a clean finish Snap probes the file (`AVURLAsset` duration and tracks), writes `<file name> poster.png` (the frame at 0.5 s or at half the duration when shorter, `AVAssetImageGenerator` with the track transform applied, PNG at the capture's DPI), then rewrites `item.json` with `state: complete`, duration, codec, fps, audio and pixel size.
4. At launch, before the first sweep, any item still in `state: recording` becomes `state: interrupted` (the app or the Mac stopped mid-recording). It is kept and swept like any other item, shown in history with the "Interrupted" pill, Reveal and Move to Trash only, because an mp4 without its final index may not play.
5. A recording that fails before its first frame (permission, stream start error) removes its own empty folder: this and the user's Move to Trash are the only removals outside retention.
6. Cancel Recording moves the folder to the Trash.

**Save.** Save copies the mp4 to the save folder with the same naming and collision rules as PNGs. Edited outputs do not exist for video.

### 20.5 All-in-one HUD (Cmd+Shift+5)

**Hotkey change** **(my call, D56).** Cmd+Shift+5 opens the HUD, as in CleanShot. Window capture keeps Tab and Space in the area overlay, a menu item, and a "Capture Window" shortcut that is unset by default. Settings migration (version 1 to 2): if Capture Window still holds the default Cmd+Shift+5, it moves to All-in-One and Capture Window becomes unset; a user-changed shortcut is left alone. The CleanShot hand-over from 12.3 covers the same key code.

**What it is** **(my call, D57).** The HUD is the area overlay from section 7 with a toolbar, not a new window. The pre-built overlay panels order front exactly as for Cmd+Shift+4 (same latency budget, same flat drawing, nothing animates, M0), plus one pre-built toolbar view (mockup 10):
- Toolbar: chip material (17.2, flat, no blur, rule 2 of 17.1), 44 pt high, radius 14, 6 pt padding, centered at the bottom of the display under the pointer, 28 pt above its `visibleFrame` bottom. If the restored area would sit under it, it moves to 28 pt below the `visibleFrame` top.
- Contents, left to right: Close (30 pt, x), divider, a two-part mode switch Screenshot | Record (camera and record glyphs, 28 pt high, 12 pt medium labels; Record shows its dot in red), divider, three target buttons Area, Window, Fullscreen (36 × 32, 17 pt glyphs, tooltips with keys 1, 2, 3), divider, "Options" (an `NSMenu`), and the primary button: "Capture" in the accent, or "Record" in `record` red, 30 pt high, 13 pt semibold.
- Options menu, screenshot mode: Hide Desktop Icons, Include Window Shadow, Show Magnifier. Record mode: Microphone (None, then each input device), Record System Audio, Show Cursor, Highlight Clicks, Countdown (Off, 3 seconds, 5 seconds). These are the same settings as the Settings window, written to `settings.json`.

**Last area** **(my call, D58).** When an area is confirmed from the HUD or from Cmd+Shift+4, `state.json` stores `lastArea: {displayID, displayFrame, rect}`. The HUD restores it only when a display with the same id and frame is present; it shows with 8 handles (10 pt, white, 1.5 pt accent border), a size chip 8 pt below, and is editable: drag inside moves it, handles resize it, a drag outside draws a new one, arrows nudge as in section 7. Instant capture does not apply in the HUD; Return, a double-click inside, or the primary button confirms. With no usable last area the HUD shows the plain crosshair and the toolbar, and the first drag draws the area.

**Targets.** Area: as above. Window: the window highlight of 17.6, a click confirms at once. Fullscreen: the display under the pointer gets the accent 14% fill and a label chip with its name and size, a click confirms.

**Keys.** 1, 2, 3 pick the target; R toggles Screenshot and Record; Tab toggles Area and Window; Return confirms; Esc cancels; arrows nudge the area.

**Frozen or live** **(my call, D59).** In Screenshot mode the HUD starts the frozen display capture exactly like area mode (6.2), so the confirm is an instant crop. In Record mode the frozen layer is hidden and the screen behind the dim is live, because a recording starts from what is on screen when the countdown ends; switching modes only toggles the frozen layer's visibility.

**Latency.** Hotkey to HUD visible: the same p95 under 50 ms as the area overlay, measured headless with `snapbench latency --fake --mode hud` (AC-M2-8).

### 20.6 Screen recording

**Starting.** From the HUD in Record mode, from the menu "Record Screen…" (opens the HUD in Record mode), or the "Record Screen" shortcut (unset by default, opens the HUD in Record mode). Snap records one thing at a time; while recording, Cmd+Shift+5 means Stop.

**Plan** (`RecordingPlan`, pure, in `SnapCore/Recording`) **(my call, D60).** Built from the target, the displays and the settings; it holds every value the live code passes to ScreenCaptureKit, so the live code only copies fields:
- Area: `SCContentFilter(display:excludingWindows:)` with Snap's own panels and, when "Hide desktop icons" is on, Finder's icon window (6.3); `sourceRect` = the area in display-local points; output size = area × scale for Retina, or × 1 for the 1x setting.
- Window: `SCContentFilter(desktopIndependentWindow:)`; output size from `contentRect × pointPixelScale`; the window shadow is not recorded (`ignoreShadowsSingleWindow = true`), since a shadow is static padding in a video **(my call)**.
- Fullscreen: the display under the pointer, whole.
- Output width and height are rounded down to even numbers (H.264 and HEVC need them) and must be at least 64 × 64 px; a smaller area is refused with the size chip turning to "Too small to record".
- `minimumFrameInterval` 1/30 s (30 fps) or 1/60 s; `queueDepth` 6; `showsCursor` from Show Cursor (default on); `showMouseClicks` from Highlight Clicks (default on), so Snap draws no click overlay and installs no event monitor **(my call, D66)**; colour space sRGB and BT.709 for the file, unlike screenshots, because players and chat apps assume it **(my call)**.
- Audio: `capturesAudio` from Record System Audio, `excludesCurrentProcessAudio = true`, 48 kHz stereo; `captureMicrophone` and `microphoneCaptureDeviceID` from Record Microphone and the chosen device.
- `SCRecordingOutputConfiguration`: `outputURL` in the history folder (20.4), `outputFileType = .mp4`, `videoCodecType` `.h264` (default) or `.hevc`.
- Exclusions **(my call, D62):** the overlay, countdown, outline, HUD, Quick Access and permission hint panels are excluded; pins are recorded, because the user placed them on screen as content.

**Countdown** (mockup 11a). After Record is confirmed the toolbar hides; the dim stays outside the area with the selection border; an 88 pt disc (chip color, 0.5 pt ring white 18%, shadow 0 10 30 black 35%) sits at the center of the area, window or display, with the number in 44 pt semibold tabular white; a hint chip 12 pt below: "Recording in 3 s", `↩` Start now, `Esc` Cancel. Default 3 s; Off and 5 s in settings. Return starts at once, Esc cancels and nothing is written. The overlay panel is key during the countdown, so these keys reach Snap without a global monitor.

**While recording** (mockup 11b) **(my call, D63).**
- No dim. For an area, a click-through outline panel draws the selection border (1 pt white with 1 pt black 30% on both sides) 2 pt outside the area, so it is never in the frames; it is also excluded from the filter. Window and fullscreen targets have no outline.
- The status item becomes a red timer: an 18 pt capsule in `record` red, a white 8 pt rounded stop square, and the elapsed time in 12 pt semibold tabular white (`0:42`, `1:02:05` after an hour), updated once a second. Tooltip "Stop Recording (⇧⌘5)".
- A click on the timer stops at once. Option-click or right-click opens a menu: Stop Recording (⇧⌘5), Cancel Recording, then three information rows (target and size, fps and codec; microphone device or "Microphone off"; "System audio on" or off).
- Stop also by Cmd+Shift+5 or the optional "Stop Recording" shortcut (unset by default).
- No pause in M2: `SCRecordingOutput` writes one continuous file, and pause would mean stitching segments.
- Screenshots still work during a recording; their overlay is excluded from the video like every Snap panel.
- While finishing, the timer shows "Saving"; finishing normally takes well under a second.

**Result** **(my call, D67).** On a clean stop the Quick Access stack gets a video card (mockup 11c): the poster as the thumbnail, a duration pill in place of the dimension pill (play glyph, `0:42`), and the Copied chip, because the after-capture actions apply to video too and Copy puts the mp4's file URL on the pasteboard (`public.file-url`, so pasting into Finder, Mail or a chat attaches the file). Hover: scrim, Close, and a control bar with the labeled main button "Open" (opens the file in the default player with `NSWorkspace`), then Save, Reveal in Finder and Copy. Keys: O open, S save, C copy, R reveal, Delete or Esc close. Drag-out drags the mp4 URL with `.copy`. Background, Annotate and Pin do not apply to video. Auto close, stacking and motion are as for screenshots.

**Audio** **(my call, D64).** System audio and microphone are both off by default (recordings are rare and usually silent screen demos). When both are on, the file should carry one mixed AAC track, because most chat and browser players play only the first audio track. Whether `SCRecordingOutput` mixes the microphone into the system track or writes two tracks on macOS 27 is unverified. If it writes two tracks, Snap runs a post-stop export: an `AVMutableComposition` with the video track passed through and the two audio tracks mixed by an `AVAudioMix` into one AAC track, written next to the original and swapped in by rename, before the card appears. The export is tested offline with a fake two-track file (AC-M2-4).

**Disk** **(my call, D68).** Snap refuses to start with less than 2 GB free on the volume holding `SNAP_HOME` (the size chip shows "Not enough disk space"). While recording it checks every 5 s and stops cleanly below 500 MB, keeping the file and noting it on the card ("Stopped: disk almost full").

**Failure modes** **(my call, D69).**

| Situation | What Snap does |
|---|---|
| Screen Recording denied or lapsed at start (`SCStreamErrorUserDeclined`, -3801) | Removes the empty item folder, shows the permission hint from section 13, marks permission unknown. |
| Stream fails to start for another reason | Removes the empty folder, logs the error, shows a hint chip "Recording could not start" near the pointer for 4 s. |
| Stream stops mid-recording (window closed, display removed, system error) | Finishes the file with what was recorded, shows the card with a note: "Stopped: the window closed" or "Stopped: the display was disconnected". |
| Microphone access denied or the device disappears | Records without the microphone; the card shows "No microphone" for 4 s; Settings shows the warning row (20.10). |
| Disk low | See Disk. |
| Snap quits during a recording | `applicationShouldTerminate` returns `.terminateLater`, stops and finishes the file (up to 5 s), then quits. |
| The Mac sleeps | Stops and finishes on `NSWorkspace.willSleepNotification`. |
| Crash or power loss | The item stays `recording` and becomes `interrupted` at the next launch (20.4). |
| The finished file does not probe as playable | `state: interrupted`, card with Reveal only. |
| A second Record request while recording | Cmd+Shift+5 stops instead; the menu item reads "Stop Recording". |

**Logging.** `snap.log` gets `recording start id=.. target=area size=2560x1600 fps=30 codec=avc1 audio=none` and `recording stop id=.. duration=42.4 bytes=.. reason=user`, never frame data.

### 20.7 Permissions

- Screen Recording: already granted for screenshots; the same grant ("Screen & System Audio Recording") covers video and system audio. No new request, no new onboarding step.
- Microphone **(my call, D65, D79):** `NSMicrophoneUsageDescription` = "Snap records your microphone only during a screen recording you start with the microphone turned on." `AVCaptureDevice.authorizationStatus(for: .audio)` is the probe. `AVCaptureDevice.requestAccess(for: .audio)` is called at most once per install, and only from a user action that turns the microphone on (the Settings switch or the HUD Options menu); never at launch, never from a recording start. Denied or restricted: the switch stays on as the user's intent, recordings proceed without the microphone, and Settings shows a warning row "Microphone access is off for Snap. Recordings are saved without it." with "Open Privacy Settings" (deep link to Privacy & Security > Microphone).
- Snap is not sandboxed and the app has no hardened runtime (section 13 and `bundle.sh`), so no audio-input entitlement is needed; the grant is keyed to the same designated requirement as Screen Recording and survives rebuilds.
- Lint **(my call, D75):** the `screen_capture_only_in_system` rule grows to `SCStream`, `SCRecordingOutput`, `SCStreamConfiguration`, `SCContentFilter` and `AVCaptureDevice`, all allowed only under `Sources/SnapSystem/`. `check.sh`'s plist gate also requires `NSMicrophoneUsageDescription` with the exact text above.

### 20.8 Annotate additions

**Toolbar** (mockup 12) **(my call, D70).** Tools, left to right: Select (V), Crop (C), Rectangle (R), Arrow (A), Text (T), Highlight (H), Redact (P), Steps (N), Freehand (F), 34 × 26 each in the segmented group. Pixelate stops being its own tool and becomes the first style of Redact; documents from M1 keep their pixelate items. The slot after the group shows the active tool's options: the color well and stroke popup for Rectangle, Arrow, Text, Steps and Freehand; the highlight color for Highlight; a style popup for Redact.

**Highlight (H).** A drag draws a rectangle filled with the highlight color at 38% opacity, radius 2, no stroke. It has its own remembered color, default #FFD60A, because the red stroke color makes an unreadable highlight. Shift constrains to the line height of a drag that is wider than 3 times its height (a horizontal band).

**Redact (P), three styles.** Pressing P again cycles Pixelate, Blur, Black-out; the popup shows the current style with its icon and lists the three with their keys. A drag draws the region.
- Pixelate: as in M1 (cell about 1/12 of the shorter side, minimum 8 px).
- Blur: `CIGaussianBlur` with radius max(8 px, 1/8 of the region's shorter side), the input clamped to its extent and cropped back so edges do not fade.
- Black-out: solid #000000, radius 0.
- All three are flattened at export so the original pixels under the region are not in the file. Blur and pixelate can leak the shape of large text; the style menu says "Black-out is the only style that cannot be reversed." Default style: Pixelate (M1 behaviour).

**Steps (N)** **(my call, D71).** A click places a numbered circle: diameter 24, 28 or 36 pt for stroke widths 2, 4 or 7, filled with the current color, the number in white semibold (15 pt at 28) with tabular digits. Numbers are not stored: each step's number is its order among step items, so deleting step 2 renumbers 3 to 2. Steps move but do not resize; selected, they show a 1.5 pt accent ring 2.5 pt outside the circle.

**Freehand (F)** **(my call, D72).** A drag records points, dropping any closer than 1.5 pt to the last kept point; the path is drawn as a Catmull-Rom spline converted to cubic Béziers, with round caps and joins in the current color and width. Hit testing uses the path's distance within width/2 + 4 pt. Freehand items move and delete; they do not resize.

**Model.** `AnnotationKind` gains `highlight`, `blur`, `blackout`, `step` and `freehand`; `AnnotationItem` gains `points` (freehand) and `highlightColor` is a document setting. `Flattener` draws the new kinds and applies blur and black-out to the base image before anything is drawn on top. Undo, hit-testing, move and delete follow the M1 rules.

### 20.9 Background additions

**Mesh gradients** **(my call, D73).** A fifth segment "Mesh" in the Background editor (Gradient | Mesh | Color | Image | None, mockup 13) with six original meshes: Haze, Bloom, Tide, Dune, Nebula, Orchard. Each is a 3 × 3 grid of colors interpolated bicubically across the canvas: computed in `SnapCore` at 64 × 64 samples, upscaled with high-quality interpolation and a 2 px blur so it never bands, deterministic (the same preset gives the same bytes). Core Graphics has no mesh gradient, and drawing it in code keeps it headless and testable. `BackgroundPreset.background` gains `.mesh(MeshID)`.

**Blurred capture.** The Image segment gains a first tile, "Blurred capture": the capture itself, aspect-filled to the canvas, Gaussian blur with radius 6% of the canvas's long side, brightness -0.06 and saturation 1.15 so the card stands out. `BackgroundPreset.background` gains `.blurredCapture`. It renders at preview scale in the editor with the same coalescing as M1.

`snapctl beautify --background mesh:<name>|blurred` exposes both (AC-M2-7).

### 20.10 Menu, settings and shortcuts in M2

**Menu bar menu** (mockup 15). Capture Area, Capture Window, Capture Fullscreen, All-in-One… (⇧⌘5), Record Screen…; separator; Apply Background to Last Capture, Open Last Capture in Annotate, Pin Last Capture; separator; Recent Captures (3 rows, recordings shown as "Recording HH.mm.ss · 0:42" with the poster), Capture History…, Pinned Captures (n) submenu (only when pins exist); the status line; Settings…, Quit Snap. While recording, the status item is the red timer (20.6) and a plain click stops.

**Settings** gets a fifth tab, Recording (mockup 14), between Quick Access and Shortcuts:
- Video: Format (H.264, HEVC; help "HEVC files are about half the size."), Frame rate (30 fps | 60 fps), Resolution (Retina | 1x).
- While recording: Countdown (Off, 3 seconds, 5 seconds), Show cursor (on), Highlight clicks (on).
- Audio: Record system audio (off), Record microphone (off; help "Asked once, when you turn this on."), a microphone device popup when on, and the warning row when access is off.

**Shortcuts tab.** Capture: Capture Area ⇧⌘4, Capture Fullscreen ⇧⌘3, All-in-One ⇧⌘5, Capture Window (unset), Record Screen (unset), Stop Recording (unset; ⇧⌘5 always stops a recording). Last capture: Apply Background, Open in Annotate, Pin Last Capture (all unset). Other: Open Capture History (unset).

**`settings.json` version 2.** Adds `recording {format, fps, scale, countdownSeconds, showCursor, highlightClicks, systemAudio, microphone, microphoneDeviceID}`, `annotate {highlightColor, redactStyle}` and the new shortcut slots; migration from version 1 is a pure function with tests (`SettingsMigrationTests`). `state.json` adds `lastArea`, `hudMode`, `hudTarget`, `historyWindowFrame` and `microphoneRequested`.

### 20.11 Visual design for M2

The direction and every token of section 17 carry over: the screenshot is the only colorful thing, chrome is neutral plus the accent, overlay-path surfaces are flat, and floating panels declare elevation once. Mockup sections 8 to 15 in `docs/mockup/index.html`; solo renders at 2x per surface and theme in `docs/mockup/png/m2/<scenario>-<theme>.png`; overview pairs in `docs/mockup/png/11-pin.png` to `20-menu-m2.png`; named comparison regions in `docs/mockup/m2/regions.tsv`.

**New tokens** (`Theme`):

| Token | Light | Dark | Use |
|---|---|---|---|
| `record` | #FF3B30 | #FF453A | Recording timer, Record button, record dot |
| `highlightDefault` | #FFD60A at 38% | same | Highlight tool default |
| `pinRadius` | 8 pt | same | Opaque pins |
| `lockBadge` | chip color at 0.72, 18 pt | same | Click-through pin |
| `hudBar` | chip, 44 pt high, radius 14 | same | All-in-one toolbar |
| `countdownDisc` | chip, 88 pt, 44 pt semibold digits | same | Countdown |
| `historyTile` | 164 × 112, radius 8, gaps 16 / 14 | same | History grid |

**Surfaces and their shot scenarios** (point sizes; the shot is 2x; the solo mockup PNG is the same size):

| Scenario | Size (pt) | Content |
|---|---|---|
| `pin` | 1280 × 800 | fake desktop, a hovered pin with chrome, a 60% pin, a click-through pin with its lock badge |
| `history` | 760 × 560 | window content with toolbar, two day sections, one selected tile, a recording, an edited and an interrupted item |
| `history-empty` | 760 × 560 | the empty state |
| `hud` | 1280 × 800 | dim, restored area with handles and size chip, toolbar in Screenshot mode |
| `recording-countdown` | 1280 × 800 | dim, area, disc with 3, hint chip |
| `recording` | 1280 × 800 | live desktop, area outline, red timer status item, the Option-click menu |
| `quick-access-video` | 600 × 760 | a hovered screenshot card with Pin, a hovered video card, a fresh video card with Copied |
| `annotate-tools` | 1100 × 720 | toolbar with the new tools, Redact style menu open, highlight, black-out, blur, three steps, freehand |
| `background-mesh` | 920 × 640 | editor on the Mesh segment with Haze |
| `settings-recording` | 480 × 690 | Recording tab, microphone access denied |
| `menu-m2` | 420 × 600 | `MenuPreviewView` of the M2 menu model |

Shot scenes reproduce the mockup's scene layout (wallpaper gradient, window rects, card and pin positions, the same sample content drawn simply) so that the comparison in 20.14 measures the design, not a different composition.

### 20.12 Motion for M2

Rows continue the table in 17.7 **(my call, D78)**. Gates applied (find-animation-opportunities): keyboard-initiated and hotkey-path surfaces never animate; state changes get the shortest motion that makes them legible; Reduce Motion falls back to opacity.

| # | Moment | What moves | Duration and curve | Reduce Motion |
|---|---|---|---|---|
| M16 | HUD appears, target switch, mode switch, Esc | Nothing (M0 rules: hotkey path, used daily) | 0 ms | Same |
| M17 | Pin opens from a card | The image grows from the card thumbnail's frame to the pin frame; the card leaves with M6 | Spring 0.30 / 1.0 | Fade in 100 ms at the pin frame |
| M18 | Pin opens from the menu or history | Fade in and scale .96 to 1 at the pin frame | 160 ms enter | Fade 100 ms |
| M19 | Pin closes | Fade out, scale 1 to .96 | 120 ms exit | Fade 100 ms |
| M20 | Pin hover chrome | Same as M3 and M3b | 120 ms in, 100 ms out | Opacity only |
| M21 | Pin move, resize, zoom, opacity | 1:1 with the pointer or the key, no easing; the size chip appears and leaves with no fade | 0 ms | Same |
| M22 | Countdown digit | The new digit cross-fades in place, no scale (the user reads it while getting ready) | 120 ms enter | Cross-fade |
| M23 | Recording starts | Dim, disc and hint leave at once; the outline appears at once | 0 ms | Same |
| M24 | Timer status item | Digits change in place, no pulse, no blink | 0 ms | Same |
| M25 | Video card, restored card | Same as M1, M2, M6 | As M1 | As M1 |
| M26 | History window | Selection ring and tile states change instantly; no grid stagger; Quick Look uses the system zoom | 0 ms | Same |
| M27 | Annotate new tools, Background mesh | None, as M11 and M12 | 0 ms | Same |
| M28 | History tile moved to the Trash | The tile fades out and scales 1 to .96; the remaining tiles move to their new slots on the spring | 120 ms exit; spring 0.30 / 1.0 | The tile fades 100 ms, the others jump |

Rejected: a pulsing record dot or outline (a looping animation during the whole recording is a distraction and reads as a nag); a fly-to-card animation after Stop (the card already enters with M1); a staggered history grid (a tool window opened to find something, decoration delays it); an animated countdown ring (the digit already carries the state; a ring adds motion at the moment the user is getting ready).

### 20.13 Package and files

```
Sources/SnapCore/
  Model/        CaptureItem (+kind, state, video fields), HistoryStore (v2, in-use sweep, trash), Settings (v2 + migration),
                StateStore (+lastArea, hud, microphoneRequested)
  Logic/        PinBoard, HistoryQuery, AllInOneState, MenuModel (+M2 items)
  Recording/    RecordingTarget, RecordingPlan, RecordingSource (protocol), RecordingController, DiskSpaceProbe (protocol),
                VideoProbe, PosterWriter, AudioMixExport
  Annotate/     AnnotationItem (+highlight, blur, blackout, step, freehand), Flattener, FreehandPath
  Beautify/     MeshGradients, BlurredCaptureBackground, BackgroundPreset (+mesh, blurredCapture)
  Fakes/        FakeRecordingSource (AVAssetWriter, synthetic frames), FakeDiskSpace, FakeMicrophoneAuthorization,
                HistoryFixture
Sources/SnapSystem/
  LiveRecordingSource (SCStream, SCRecordingOutput), MicrophoneAuthorization, LiveDiskSpace, InputDevices
Sources/SnapUI/
  Pin/          PinPanel, PinView, PinChromeView, PinController
  History/      HistoryWindowController, HistoryView, HistoryTile, ThumbnailCache, HistoryDemo
  Overlay/      AllInOneToolbar, CountdownView, RecordingOutlinePanel (+OverlayController HUD mode)
  QuickAccess/  QuickAccessCardView (+Pin button, video card), QuickAccessController (+video)
  Annotate/     AnnotateToolbar (+tools, Redact style popup), AnnotateCanvasView (+tools)
  Background/   BackgroundEditorView (+Mesh segment, Blurred capture tile)
  Settings/     SettingsView (+Recording tab, shortcut rows)
  Menu/         StatusMenuController (+timer, pinned submenu), MenuPreviewView
Sources/snapctl/  RecordCommand, ProbeCommand, HistoryCommand, AnnotateCommand (+ BeautifyCommand flags)
Sources/snapbench/ LatencyBench (+ --mode hud)
```

`snapctl` gains an AVFoundation link (fake recorder, probe, poster, audio mix export) and still never links ScreenCaptureKit or Sparkle; `check.sh` keeps verifying both with `otool -L`.

### 20.14 Testing offline with fakes

No agent may call ScreenCaptureKit, record the screen, record or play audio, request microphone access, or show a window. Every M2 path is tested through fakes and headless tools **(my call, D76, D77)**:

**Fakes.**
- `FakeRecordingSource`: implements `RecordingSource` by writing a real mp4 with `AVAssetWriter` from synthetic frames (the gradient and grid of `SyntheticImages`, with a frame counter block so frames differ), at the plan's size, fps and codec, optionally with a silent AAC track per requested audio source (generated sample buffers, never a device, never played). It can fail on start, stop mid-way with a reason, or be "killed" after N frames without finishing the file (to test interrupted recovery).
- `FakeDiskSpace`, `FakeMicrophoneAuthorization` (granted, denied, not determined; counts requests), `FakeClock` for countdowns and the timer, `HistoryFixture` (N items spread over D days, images and videos, some edited, some interrupted, v1 and v2 `item.json`).

**Unit suites (required by AC-M2-3).** `PinBoardTests` (placement at the capture rect, fallback and 60% fit, clamps, aspect-locked resize, zoom limits, opacity steps and floor, ninth pin closes the oldest, display removal), `HistoryStoreV2Tests` (v1 decode, v2 round trip, in-use sweep skip, interrupted marking at launch, trash), `HistoryQueryTests` (kind filter, word matching on app, file and date words, grouping by local day across midnight and DST), `AllInOneStateTests` (last area restore and display fingerprint, keys, mode toggling hides the frozen layer, settings migration of ⇧⌘5), `RecordingPlanTests` (area sourceRect and even pixel sizes at 1x and 2x, window and fullscreen filters, minimum size, fps, codec, audio flags, exclusions), `RecordingControllerTests` (countdown with a fake clock, Return skips, Esc cancels and writes nothing, stop by status item and by ⇧⌘5, history-first `item.json`, finish writes poster and `complete`, start failure removes the folder, mid-stream stop keeps the file with a reason, disk refusal and low-disk stop, microphone denied records without it, quit and sleep finish the file), `VideoProbeTests` (duration, frame count, codec, poster size from fake files, audio mix export turns two tracks into one), `AnnotationM2Tests` (highlight alpha, blur and black-out flatten remove the original pixels, step numbering and renumbering, freehand decimation, smoothing and hit test), `MeshGradientTests` (corners match the grid colors within 3/255, determinism), `BlurredBackgroundTests`, `SettingsMigrationTests`, and in `SnapUITests`: `PinControllerTests`, `HistoryWindowModelTests`, `QuickAccessVideoCardTests` (controllers driven without panels, as M1's controller tests).

**`snapctl` additions.**
- `record --fake --target area|window|fullscreen --display WxH@S [--rect x,y,w,h] --frames N --fps F [--codec h264|hevc] [--audio system,microphone] [--kill-after-frames K] [--runs R] --json`: runs `RecordingController` with `FakeRecordingSource` and a fake clock into `SNAP_HOME/history`, prints the item, file path, probe results and timings (confirm to recording, stop to card ready).
- `probe <file.mp4> --json`: duration, frame count, codec FourCC, pixel size, audio track count, playable flag (AVFoundation reading, independent of the writer).
- `history gen --items N --days D [--seed S]`, `history list [--query q] [--kind image|video] --json [--runs R]`, `history sweep --now <ISO date> [--skip id,...] --json`, `history recover --json` (marks `recording` items `interrupted`).
- `annotate --in <png> --doc <json> --out <png>`: flattens an `AnnotationDocument` (for the redact checks).
- `beautify` accepts `--background mesh:<name>` and `--background blurred`.

**`snapbench`.** `latency --fake --mode hud` drives the real overlay controller in HUD mode without panels and reports present, frozen and confirm stages; in Record mode it also asserts that no frozen capture was requested.

**Shots.** `scripts/shots.sh m2` renders the eleven scenarios of 20.11 in light and dark through the existing shot mode (no window, `lsappinfo front` unchanged, `winlist` empty, `SNAP_NO_UPDATES=1`).

**Comparison with the mockup.** `scripts/shot-stats.swift` gains `--compare <shot.png> <mockup.png> [--grid 32] [--regions docs/mockup/m2/regions.tsv --scenario <name>]`. Both images must have the same pixel size. It reports the mean and 90th percentile of the absolute difference of mean luminance over a 32-column grid of square cells, and the mean luminance difference in each named region. The acceptance thresholds are in AC-M2-10. This checks layout, light and dark, and the weight of each surface; it does not check text rendering or blur, which the user reviews by eye.

**Acceptance notes.** AC-M2-6 samples each step circle at its fill point clear of the digit (0.38 of the diameter right of the center, printed by `snapctl annotate --report`), not at the exact center, because D71 puts the white number there (orchestrator's ruling, 2026-10-25).

### 20.15 M2 risks

- Whether `SCRecordingOutput` mixes microphone and system audio into one track on macOS 27 is unverified; the post-stop mix export is the fallback and is tested offline.
- `showMouseClicks` drawing and its look are the system's; if it is missing or looks wrong, a Snap-drawn click overlay would need a global mouse monitor, which this design avoids. Hands-on check by the user.
- The time from countdown end to the first recorded frame is unmeasured; a fast click right after the countdown may be missed. The first-frame time is logged per recording.
- Interrupted mp4 files are usually unplayable without the final index; Snap keeps them for 3 days but does not try to repair them.
- A borderless resizable nonactivating panel's resize and pinch behaviour, the click-through lock, Quick Look from the history window, the HUD's key handling and the recording timer all need hands-on checks by the user, because no agent can show a window.
- Eight 5K pins hold about 470 MB of decoded images; the cap is the guard.
- The shot-to-mockup comparison thresholds are a first guess; if a threshold proves unreachable with a faithful scene, the run reports the measured numbers rather than loosening it, and the user decides.

### 20.16 Reliability and trust additions

Date: 2026-10-25. From user research on what Mac users dislike in CleanShot X and its alternatives (recordings that stop silently or carry no sound, annotations that cannot be edited after the fact, the macOS Screen Recording re-approval prompt). Four small additions, each behind its own tests; no new window and no new setting **(my calls, D80 to D85)**.

**Recording heartbeat (D80).** While recording, `RecordingController` reads the session's sample counts once a second (`RecordingSession.sampleCounts`: video frames, system audio buffers, microphone buffers). `RecordingHeartbeat` (pure, in `SnapCore/Recording`) reports the first watched track that has delivered nothing for 3 s: video always, system audio and microphone only when the plan records them, video before audio. A stall only warns; it never stops the recording, and Stop keeps whatever was written.
- Menu bar: the timer capsule turns amber (`Theme.Recording.stalledFill`, #F08A00 light, #FF9F0A dark) with dark ink (#1D1D1F, 7:1) and a warning triangle after the time, so the state does not rest on hue alone. The click still stops. Tooltip: the message, then "Stop Recording (⇧⌘5)". No pulse, no blink (M24).
- Recording menu (Option-click): a first status row, not clickable: "Recording stalled: no new frames for 5 s", "Recording stalled: no system audio for 4 s" or "Recording stalled: no microphone audio for 4 s". The seconds count up while the menu is reopened.
- Samples coming back clears the warning (`resumed` in the event log). A stall that is still on at Stop becomes the card note: "Frames stopped at 0:42", "Microphone stopped at 0:42".
- Live counting: one `SCStreamOutput` per recorded type on a utility queue counts every buffer, including frames with an idle status, and drops it at once; `SCRecordingOutput` still writes the file. Unverified on hardware: whether a still screen or silent system audio still delivers buffers. If they do not, the warning shows during long still stretches; the threshold or the counted signal then changes, not the design.

**Audio check (D81).** After a recording finishes, the probe also measures the audio (`AudioLevelProbe`: `AVAssetReader` decoding to float PCM, stopping at the first sample above -60 dBFS, so only a silent file is read to the end). `AudioCheck.evaluate` turns the asked-for sources, the track count and the peak into `captured`, `noTrack`, `microphoneSilent` or `systemSilent`; nothing when no audio was asked for (a silent screen demo is normal). The result is stored in `item.json` (`audioCheck`) and shown on the video card for as long as the card is up, because it is about the file the user is about to share, not about a moment:
- `captured`: a speaker glyph inside the duration pill (`▶ 0:42 🔈`, drawn with `speaker.wave.2.fill`).
- the others: a second pill beside the duration pill in the same chip style, `speaker.slash.fill` in `warningDot` and "No audio track", "Microphone silent" or "System audio silent". At Small only the glyph shows. The pills hide on hover like the duration pill, since the control bar takes the bottom of the card.
- `snapctl probe` prints the peak (`audioPeakDBFS`, floored at -160 for digital silence); `snapctl record --fake` takes `--tone-dbfs D` and `--no-audio-track` and prints `audioCheck`.

**Editable annotations in history (D82, D83).** `item.json` becomes version 3. An edited capture keeps `annotations.json` next to it (`AnnotationFile`: version 1, crop as `[x, y, w, h]`, the annotation items with their kind, geometry, color, width, text, step order, redaction style and freehand points, and the Background preset applied on top, if any). `item.json` names it in `annotationsName`. Versions 1 and 2 still read; an edit saved before version 3 has no file and opens flattened, as before.
- Annotate always opens on the original capture plus the file, so every item is editable again: select, move, resize, delete, restyle, renumber steps. Copy and Save flatten the items and add the Background around them when one is applied; the edited PNG and the file are written together.
- One-click Background on the card renders around the annotated image, not the bare original, and records its preset in the file. Removing it keeps the annotations.
- While a Background is applied, the annotate toolbar's Background button reads "Background On" with the help text "Copy and Save add the Background. Click to change it."; clicking opens the Background editor with that preset. The canvas shows the capture without the Background, since the annotations are drawn on the capture.

**Screen Recording re-approval badge (D84, D85).** macOS asks again from time to time whether Snap may record the screen; until the user answers, captures fail. `PermissionState` (with a `ScreenRecordingPermissionSource`: `CGPreflightScreenCaptureAccess` only, never a request, and `FakePermissionSource` in tests) now remembers that a capture was refused or failed for permission (a hotkey while denied, -3801 from ScreenCaptureKit). Then:
- the menu bar symbol carries a 6 pt `warningDot` badge at its top-right, sitting in a hole cut out of the template symbol with 1.5 pt of clear space, so the two shapes never touch and the symbol stays a template image;
- the menu's status row reads "Screen Recording needs your OK" (was "Screen Recording permission needed") and opens the Screen Recording pane of System Settings when clicked, and only then.
The badge clears on the next capture that works, or when the preflight says yes and no lapse is pending (checked when the menu or settings open). A lapse with the preflight still saying yes keeps the badge until a capture works, because only a capture proves the re-approval happened.

**Motion.** None of the four adds motion (M29 below). Shots: `scripts/shots.sh m2-polish` renders `recording-stalled`, `quick-access-audio`, `annotate-reopened` and `menu-permission` in light and dark.

| # | Moment | What moves | Duration and curve | Reduce Motion |
|---|---|---|---|---|
| M29 | Timer stalls or recovers, permission badge, audio pill, reopened annotations | Nothing. The capsule color, the badge and the pills change in place. Frequency: rare (a stall or a lapse a month at most). Purpose: state indication, which an instant change in the menu bar serves best; a fade would delay the signal. | 0 ms | Same |

Rejected (motion gate): a pulsing amber timer while stalled (rare, but a looping animation in the menu bar is a nag; the color and glyph already carry the state); a badge that scales in (state indication in peripheral vision; a scale makes it read as a notification count); a slide-in for the audio pill (it appears with the card, which already enters with M1).

### 20.17 Settings and History look

Mode: Operate. Scanability and native behavior outrank expression, so the look lives in ground color, one accent, heading type and counts, and every control stays system-drawn. Mockups: `docs/mockup/settings-history/` (`settings-mockup.png`, `history-mockup.png`, light and dark).

Direction, "Proof sheet": cool blue-gray paper under white screenshots, like a contact sheet on a light table. One signal color, frame blue, marks the selected thing (switches, default button, selected tab, the selection ring). Headings and day counts use Avenir Next Demi Bold (the family Booth and Tidy use for display), body text stays SF Pro.

| Token | Light | Dark | Use |
|---|---|---|---|
| `desk` | #E9ECF1 | #111317 | Settings form and History grid ground |
| `deskBar` | #F8F9FB | #181B20 | Settings tab bar, History toolbar and footer |
| `deskGroup` | #FFFFFF | #1D2026 | Settings groups, selected segment |
| `deskText` / `deskText2` | #14171C / #4F5663 | #F1F3F7 / #A4ACB9 | Text on the three grounds above |
| `brand` | #2457F5 | #3E67F0 | Fills; white on it is 5.6:1 and 4.8:1 |
| `brandText` | #1F4BD8 | #8EA9FF | Blue text and icons |
| `brandWash` | brand at 12% | #7896FF at 16% | Selected tab fill |

Contrast (checked by `ThemeTests.documentedContrastRatiosHold`, all at least 4.5:1): `deskText` on desk 15.2 and 16.7; `deskText2` on desk 6.2 and 8.1, on group 7.4 and 7.1, on bar 7.0 and 7.6; `brandText` on group 6.9 and 7.2, on desk 5.8 and 8.2, on the tab wash 5.4 and 6.0 or more; selection ring on desk 3.9 (non-text, 3:1).

Changes: Settings groups get an Avenir heading (no accent tick: a side stripe reads as decoration) and the tab bar its own tone; the selected tab is a blue-washed capsule. History gets a 17 pt Avenir title, 16 pt day headings with the count in a tabular capsule, a darker desk so white screenshots stand out, a blue selection ring and blue "Show in Quick Access". No setting, shortcut, key command or accessibility label changed. The `settings-general` shot scenario was added.

Motion gate: no new motion. The existing M26 and M28 history transitions are unchanged (occasional, feedback, 120 ms, tokens `historyTileExit` and `reducedMotionFade`).

## Decisions to review

All mine, made while the user was away.

- D1. Name Snap, bundle id `dev.sdusteric.snap`, menu bar only (`LSUIElement`).
- D2. Swift 6.4 + AppKit lifecycle, SwiftUI for card, editor and settings content; SwiftPM only, bundle assembled by script.
- D3. Package split: `SnapCore` (pure, no AppKit), `SnapSystem` (the only target touching ScreenCaptureKit, Carbon and the pasteboard), `SnapUI`, `Snap`, `snapctl` (fakes only, never links ScreenCaptureKit).
- D4. Overlay first, then the frozen capture behind it, instead of capture first.
- D5. macOS 26 `SCScreenshotManager.captureScreenshot` with `.sdr`; Snap writes PNGs itself.
- D6. Keep the display colour space (Display P3) with the ICC profile embedded; DPI 72 x scale.
- D7. Hide desktop icons by excluding Finder's icon window from the filter; no cover window, no system setting change.
- D8. Fullscreen captures only the display under the pointer.
- D9. Window capture is live on click, with transparency and shadow on by default; Option-click flips the shadow.
- D10. Instant capture on mouse-up by default; a click without a drag captures the window under the pointer.
- D11. Quick Access at the bottom-left, Medium (240 pt), 15 s auto close paused on hover, max 5 cards, key focus only on hover.
- D12. Drag-out drags a file URL to the history copy and returns `.copy`; a successful drop closes the card.
- D13. Clipboard: PNG eagerly, TIFF lazily through a data provider.
- D14. Every capture is written to `SNAP_HOME/history` first and kept 3 days (`historyCapacity = 3` read as days); saving to ~/Downloads is a user action, matching `[0, 1]`.
- D15. File name pattern `Snap {yyyy}-{MM}-{dd} at {HH}.{mm}.{ss}` with numeric collision suffixes.
- D16. Background inset defined as room inside the card filled with the screenshot's edge colour, applied only for a uniform border; auto-balance trims to content bounds.
- D17. Padding and inset scaled by `u = clamp(min side in points / 600, 0.5, 3)`.
- D18. Corner radius 0.12 read as a 0...1 slider up to 100 pt (12u pt), capped at half the shorter card side.
- D19. Shadow formula in section 10.2, with a contact shadow and a 1 px edge stroke.
- D20. Original backgrounds only: 12 named gradients, 10 solids, custom colour, own image, none. Default gradient Dusk in place of CleanShot's `bg16`.
- D21. Annotate M1 tools: crop, rectangle, arrow, text, pixelate. Highlight, blur and black-out wait for M2.
- D22. Hotkeys Cmd+Shift+3, 4 and 5 by default (5 is window mode in M1, the HUD in M2); no defaults for Background and Annotate actions.
- D23. Snap does not register conflicting combos while CleanShot runs, and registers them when it quits. It never edits the system shortcut plist.
- D24. One permission request per install, from a button; afterwards only a small non-activating hint.
- D25. Signing by SHA-1 of the one valid Apple Development certificate, no hardened runtime, no entitlements, `--timestamp=none`.
- D26. State in JSON files under `SNAP_HOME`, not `UserDefaults`; a non-default `SNAP_HOME` also moves the default save folder inside it.
- D27. Background screenshots by a shot mode of the app binary, rendered with `cacheDisplay` and `ImageRenderer`, launched by direct exec; the menu shot renders the menu model.
- D28. Image checks by pixel statistics, not golden PNGs.
- D29. Sound off by default.
- D30. `.regularMaterial` instead of Liquid Glass.
- D31. Recording, all-in-one HUD, history window and pin to screen in M2; scrolling capture, OCR and upload not planned.

### Design pass calls (mine, the orchestrator's, for the user to review)

Made on 2026-10-24 while the user was away, after the impeccable, apple-design and find-animation-opportunities pass. Each changes or adds to the planner's calls above.

- D32. Overlay dim is black 0.38, not 0.45, so the screen being captured stays readable. (Changes section 7.)
- D33. The crosshair is shown only before the drag, at white 62%, and is hidden from mouse down. Hint bar at the bottom center ("Drag to capture, Tab Window, Esc Cancel"), shown for the first 10 captures, then off by a setting.
- D34. One magnifier unit: a 120 pt circle of 15 x 15 physical pixels (8 pt per pixel) with a caption that shows `x, y` before the drag and `W × H` during it. It replaces the separate size label and sits away from the selection. With instant capture off a size chip sits under the selection.
- D35. The overlay path uses flat fills only: no blur, no material, no animation. All of it is on screen in the first frame and leaves instantly.
- D36. Window highlight is the accent at 14% with a 2 pt accent border and a label chip above the window (owner name and size). It jumps between windows with no easing.
- D37. Quick Access card radius 16 (thumbnail 8, concentric), not 14.
- D38. The card's primary action is Background, as a split button (the chevron opens the editor, so Option-click is not the only way). Annotate, Save and Copy are icon buttons. A "Copied" chip says the clipboard already has the image. This replaces the centered Copy and Save buttons, because Copy already happened.
- D39. The auto close countdown line is visible only in the last 5 s. Stack height is also capped at 70% of `visibleFrame`.
- D40. Card entry and dismissal use the Haul curves (enter `cubic-bezier(.16,1,.3,1)`, exit `cubic-bezier(.4,0,1,1)`) and one spring (0.30 / 1.0); the overlay never animates (motion table in 17.7). A fly-to-corner animation was rejected.
- D41. Background editor: 920 x 640, controls in a right sidebar of 300 pt, Copy is the default button. Annotate toolbar order and sizes as in 17.6.
- D42. Settings has four tabs (General, Capture, Quick Access, Shortcuts) with group headings, instead of three.
- D43. First run is one non-modal window with two steps and "Skip for now". Snap works without either step.
- D44. All colors, type, radii and sizes in 17.2 to 17.4 are tokens for `Theme` in `SnapUI/Shared`. Controls that AppKit draws (menu, switches, popups, tabs) stay system-drawn.

### M2 calls (mine, the planner's, for the user to review)

Made on 2026-10-24 while the user was away, for section 20, after the impeccable, apple-design and find-animation-opportunities pass that produced mockup sections 8 to 15.

- D45. M2 order follows use: pin, history window, all-in-one HUD, recording, annotate additions, Background additions; each part has its own tests and acceptance checks.
- D46. Pin entry points: a Pin chip top-right on a hovered card (P), "Pin Last Capture" in the menu and as an unset shortcut, and the history window. Pinning closes the card. Recordings cannot be pinned.
- D47. A pin opens at the capture's own screen rect at 100% when that rect is on a current display, else centered on the pointer's display within 60% of its visible frame.
- D48. Pins are borderless nonactivating floating panels on all Spaces, radius 8 with the card elevation for opaque captures, raw alpha for window captures; aspect-locked resize, zoom 10% to 400%.
- D49. Pin opacity 20% to 100% in 5% steps (slider, keys 2 to 9 and 0, scroll); the 20% floor keeps a pin findable.
- D50. Click-through pins show a lock badge and are unlocked from the menu's Pinned Captures submenu; no global monitors, so no Accessibility permission.
- D51. Pins are session only, at most 8; the ninth closes the oldest.
- D52. History is a titled window (760 × 560) with a day-grouped grid, kind filter and word search over app, file name and date words; Return shows the card again without touching the clipboard; delete moves to the Trash without a dialog.
- D53. The history folder stays the database: no index file; `item.json` version 2 adds kind, state, screen rect, pixel size and video fields, and version 1 still reads.
- D54. Retention stays 3 days with no size cap; the sweep skips items in use (cards, pins, editors, recording).
- D55. The menu keeps 3 Recent Captures (recordings included), adds Capture History…, and moves Open History Folder into the window footer.
- D56. Cmd+Shift+5 becomes All-in-One; Capture Window becomes unset, migrated only when it still held the default.
- D57. The HUD is the existing overlay plus a flat chip toolbar (no blur, no animation) with mode, target, Options and the primary action.
- D58. The last area is stored per display with a frame fingerprint and restored editable only on the same layout.
- D59. HUD Screenshot mode uses the frozen capture; Record mode shows the live screen.
- D60. Recording uses SCStream with SCRecordingOutput to mp4: H.264 default, HEVC option, 30 fps default, Retina default, even pixel sizes, sRGB/BT.709, no window shadow.
- D61. A recording is written straight into its history folder, `item.json` first in state recording; leftovers become interrupted at launch and are kept 3 days.
- D62. Countdown 3 s by default (Off, 3, 5), Return skips, Esc cancels; Snap's panels are excluded from the video, pins are included.
- D63. The status item becomes a red timer; a click stops, Option-click shows a menu with Cancel; Cmd+Shift+5 stops; no pause in M2.
- D64. System audio and microphone are off by default; when both are on the file gets one mixed track, with a post-stop mix export if the system writes two.
- D65. The microphone permission is requested once, only from turning the microphone on; denied means recording without it plus a warning row in Settings.
- D66. Cursor and click highlights come from SCStreamConfiguration (`showsCursor`, `showMouseClicks`), both on; Snap draws no click overlay.
- D67. A finished recording shows a video card (poster, duration pill, Copied with the file URL on the clipboard) with Open, Save, Reveal and Copy; drag-out drags the mp4.
- D68. Recording needs 2 GB free to start and stops cleanly below 500 MB.
- D69. Quit and sleep finish the file; a stream that stops early keeps what it has and says why on the card.
- D70. Annotate adds Highlight (own color #FFD60A at 38%), Redact with Pixelate, Blur and Black-out styles (P cycles; Pixelate stays the default), Steps and Freehand.
- D71. Steps are numbered circles sized by stroke width; numbers come from order and renumber on delete.
- D72. Freehand decimates at 1.5 pt and smooths with Catmull-Rom; it moves and deletes but does not resize.
- D73. Background adds a Mesh segment with six original 3 × 3 meshes rendered in code, and a Blurred capture background (6% blur, brightness -0.06, saturation 1.15).
- D74. Out of M2: GIF export, last 15 seconds, self-timer, pause, trimming, card scrubbing and per-app default presets.
- D75. The lint rule that keeps ScreenCaptureKit in SnapSystem also covers SCStream, SCRecordingOutput, SCStreamConfiguration, SCContentFilter and AVCaptureDevice; the plist gate requires the microphone usage string.
- D76. Recording is tested offline with a fake source that writes real mp4 files from synthetic frames through AVAssetWriter, plus `snapctl record`, `probe`, `history` and `annotate`.
- D77. Eleven new shot scenarios in light and dark are compared with solo mockup renders by a coarse luminance grid and named regions.
- D78. M2 motion: nothing on the HUD or recording path, a spring from card to pin, a 120 ms countdown digit cross-fade, no pulsing record indicator, no grid stagger.
- D79. Microphone usage string: "Snap records your microphone only during a screen recording you start with the microphone turned on."

### Reliability and trust calls (2026-10-25, section 20.16)

- D80. A recording heartbeat warns after 3 s without frames, or without audio from a source that is on; it turns the timer amber with a glyph and adds a menu row, and never stops the recording.
- D81. A finished recording that asked for audio is checked for an audio track and for a peak at or above -60 dBFS; the video card shows "No audio track", "Microphone silent" or "System audio silent" for as long as it is up, and a speaker glyph when the sound came through.
- D82. `item.json` version 3 names `annotations.json`, which keeps the annotations, the crop and the applied Background preset; versions 1 and 2 still read.
- D83. Annotate opens on the original plus the annotation file, so every item stays editable; Background is applied around the annotated image and remembered in the file.
- D84. A capture that fails for Screen Recording permission puts a badge on the menu bar symbol until a capture works; detection uses `CGPreflightScreenCaptureAccess` and the capture error only.
- D85. The menu row reads "Screen Recording needs your OK" and opens the Screen Recording pane only when clicked.
