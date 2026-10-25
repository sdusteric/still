# Snap

Snap is a menu bar screenshot and screen recording app for one Mac. It replaces CleanShot X for
the things its owner does with it: about one and a half screenshots a day, a gradient behind a
window now and then, and a recording every few months. It runs offline. The only network code is
the Sparkle update check in the installed app.

The design doc is the source of truth: `docs/superpowers/specs/2026-10-24-snap-design.md`. The
mockup in `docs/mockup` shows every surface in light and dark.

## What it does

- Area, window and fullscreen screenshots on ⇧⌘4, ⇧⌘3 and ⇧⌘5 (the all-in-one toolbar). The dim
  overlay appears before the capture finishes, and Snap never takes focus from the app you capture.
- A Quick Access card in the corner after each capture. The image is already on the clipboard.
  From the card you can add a Background, annotate, save, copy, pin, or drag the file out.
- Background puts the capture on a gradient, mesh, color, image or a blurred copy of itself, with
  padding, inset, corners and shadow from your preset.
- Annotate has crop, rectangle, arrow, text, highlight, numbered steps, freehand, and redaction by
  pixelate, blur or black-out. Black-out is the only redaction that cannot be reversed.
- History keeps every capture for 3 days. Edited captures keep their annotations in
  `annotations.json`, so reopening one from History gives you every arrow, step and redaction to
  edit again, with the Background still applied on export.
- Pins float a capture above other windows, with opacity and click-through.
- Screen recording to mp4 (H.264 or HEVC), with system audio and microphone when you turn them on.

## Checks that catch a bad recording or a lapsed permission

- While recording, Snap checks once a second that video frames, and audio from each source you
  turned on, keep arriving. After 3 s without them the menu bar timer turns amber with a warning
  sign, and its menu says what stopped ("Recording stalled: no new frames for 5 s"). Snap keeps
  recording; Stop keeps whatever was written.
- After a recording that asked for audio, Snap reads the file. The video card says "No audio
  track" when there is none, and "Microphone silent" or "System audio silent" when the whole file
  stays below -60 dBFS. A speaker in the duration pill means the sound came through.
- macOS asks from time to time to approve Screen Recording again. When a capture fails for that
  reason, the menu bar symbol gets an orange dot and the menu shows "Screen Recording needs your
  OK". Clicking the row opens the Screen Recording pane of System Settings. Snap never asks macOS
  for permission on its own after the first-run button.

## Build and test

Requires macOS 27 on Apple Silicon and Swift 6.4. Use your own scratch path, since several builds
may run at once.

```sh
swift build --scratch-path "$TMPDIR/snap-dev"
SNAP_HOME=$(mktemp -d) swift test --scratch-path "$TMPDIR/snap-dev"
SNAP_HOME=$(mktemp -d) SNAP_NO_UPDATES=1 scripts/check.sh      # every gate, logs in build/check/
SNAP_NO_UPDATES=1 scripts/accept.sh offline                     # milestone 1 acceptance
SNAP_NO_UPDATES=1 scripts/accept.sh m2                          # milestone 2 acceptance
scripts/bundle.sh --release                                     # build/bundle/Snap.app, signed
scripts/shots.sh                                                # headless screenshots, M1
scripts/shots.sh m2                                             # M2 surfaces
scripts/shots.sh m2-polish                                      # stall, audio, reopened annotations, badge
```

`docs/acceptance.md` describes each acceptance criterion and how it is checked.

Tests and tools never touch the screen, the microphone or the real pasteboard. Recording is tested
with a fake recorder that writes real mp4 files from generated frames and tones. Shots render each
surface from demo data in a process with no window, and `scripts/shots.sh` fails if the frontmost
app changes or a window appears.

## Where things are

| Path | What |
|---|---|
| `Sources/SnapCore` | Pure logic, stores, the recording controller and fakes. No AppKit. |
| `Sources/SnapSystem` | ScreenCaptureKit, hotkeys, pasteboard, permission and microphone probes. |
| `Sources/SnapUI` | Every surface, with all colors, sizes and timings in `Shared/Theme.swift`. |
| `Sources/Snap` | The app and its headless shot mode. |
| `Sources/snapctl` | Command line tools: fixtures, beautify, fake recordings, probe, history. |
| `Sources/snapbench` | The hotkey to overlay latency bench. |
| `SNAP_HOME` | All state: settings, presets, history, logs. Defaults to `~/Library/Application Support/Snap`. |
