# Snap

A macOS menu bar screenshot app for one person, replacing CleanShot X on this Mac: area, window
and fullscreen screenshots through ScreenCaptureKit with the overlay shown first, a Quick Access
card stack, clipboard and save, the Background beautifier, a minimal annotate editor, settings and
hotkeys. The design doc is the source of truth: `docs/superpowers/specs/2026-10-24-snap-design.md`.
The mockup in `docs/mockup` (`index.html` and `png/`) is the visual target for every UI surface.

## Commands

```sh
swift build --scratch-path "$TMPDIR/snap-<task>"
swift test --scratch-path "$TMPDIR/snap-<task>" --filter <Suite>
swiftlint lint --strict
SNAP_SCRATCH="$TMPDIR/snap-check" scripts/check.sh   # every gate, logs in build/check/
scripts/bundle.sh --release                           # build/bundle/Snap.app, signed, never launched
scripts/release.sh [--notes <file.md>] [--dry-run <dir>]   # check.sh, release bundle, app-updates publish.sh
swift scripts/shot-stats.swift <png> [x y w h]        # size, luminance and mean RGBA of a region
swift scripts/winlist.swift <pid>                     # on-screen windows of one PID (exit 1 if any)
```

- Several agents may build at once. Always pass your own `--scratch-path` outside the repo and
  delete it by its exact path when done.
- Use `caffeinate -i` for long runs.
- Set `SNAP_HOME` to a fresh `mktemp -d` dir for every test, shot or `snapctl` run. With a
  non-default `SNAP_HOME` the default save folder is `$SNAP_HOME/Saved`, never ~/Downloads.
  Also set `SNAP_NO_UPDATES=1` (check.sh and shots.sh export it).
- `scripts/release.sh` publishes a real update for the user. Agents run it only with
  `--dry-run <dir>`, and only when asked.

## Layout

- `SnapCore`: Foundation, CoreGraphics, ImageIO, CoreImage. No AppKit. Shared types in `Model/`
  (`DisplayInfo`, `WindowInfo`, `CapturedImage`, `CaptureMode`, `CaptureItem`, `SnapPaths`,
  `Settings`, `SettingsStore`, `StateStore`, `DocumentStore`, `AtomicFile`, `Log`), protocols in
  `Pipeline/` (`CaptureSource`, `WindowSource`, `OverlayPresenter`, `Clock`) and fakes in `Fakes/`
  (`FakeCaptureSource`, `FakeWindowSource`, `FakeClock`, `SyntheticImages`, `SyntheticFixture`).
  `Clock` shadows `Swift.Clock` in modules that import SnapCore.
- `SnapSystem`: live ScreenCaptureKit, CGWindowList, Carbon hotkeys, pasteboard and permission
  probe. Nonisolated by default. The only target that may mention ScreenCaptureKit,
  `SCShareableContent`, `SCScreenshotManager` or `CGRequestScreenCaptureAccess` (swiftlint).
- `SnapUI`: AppKit and SwiftUI, `@MainActor` by default, depends on `SnapCore` only. Every color,
  type size, spacing, radius and motion value comes from `Shared/Theme.swift`.
- `Snap`: the app executable (`@MainActor` by default). `--shot` runs the headless shot mode.
  The only target that links Sparkle (exact 2.10.0, app-updates `CONTRACT.md`): `Updater`
  wraps `SPUStandardUpdaterController` behind SnapUI's `UpdaterControlling`, and
  `UpdaterPolicy` returns no updater in shot mode, with `SNAP_NO_UPDATES=1` or outside a `.app`.
- `snapctl`: the headless CLI. Depends on `SnapCore` only, so it never links ScreenCaptureKit
  (`check.sh` verifies with `otool -L`). Subcommands live in `<Name>Command.swift` files with
  `static func run(_ arguments: [String]) async -> Int32`.
- `snapbench`: the AC05 latency bench (`snapbench latency --fake ...`). Depends on SnapCore and
  SnapUI so it drives the real overlay and Quick Access controllers without panels; never
  SnapSystem, so it does not link ScreenCaptureKit either (`check.sh` verifies).
- Swift 6 language mode, Swift Testing (`@Suite struct XTests`, `@Test func descriptiveName()`).

## Safety rules (this is the user's real Mac)

1. Never show a window, take focus, capture the screen or trigger a permission dialog. Never run
   `open`, `screencapture` or osascript, and never launch CleanShot X or any GUI app.
2. Never call ScreenCaptureKit, `CGRequestScreenCaptureAccess`, `CGWindowListCreateImage` or
   register a global hotkey from a test, tool or probe. Live system code is compiled, and tested
   only through fakes.
3. The Snap binary runs only in `--shot` mode (no `NSApplication.run`, no on-screen window, no
   status item, no hotkeys, no updater) or as `snapctl`, always with `SNAP_HOME` set to a temp
   dir and `SNAP_NO_UPDATES=1`. Compare `lsappinfo front` before and after any Snap launch.
   Run shot mode only from the bundle (`build/bundle/Snap.app/Contents/MacOS/Snap`): its
   `LSUIElement` keeps the process a UIElement, and a bare `.build` binary refuses with exit 78
   instead of registering as an app.
4. No sound: no afplay, no say, nothing in tests plays audio.
5. Never read the user's private folders (~/Downloads, ~/Desktop, ~/Pictures, ~/Movies,
   ~/Documents outside this repo, /Volumes, ~/Library/Containers, Mail, Messages, Safari, iCloud
   Drive, CleanShot's support folder). Tests never write to ~/Downloads and never touch the real
   pasteboard: use `NSPasteboard(name:)` with a unique name.
6. Never `rm -rf` with wildcards, relative paths or after `cd`. Delete only exact absolute paths
   inside `.build`, `build/` or a dir you created with `mktemp`.
7. Track every process you start by PID and stop it by PID. Never kill or signal anything else,
   and never signal CleanShot X.
8. No network. No `URLSession`, `NWConnection` or `import Network` in `Sources/` (swiftlint
   enforces it). The one exception is Sparkle in the installed app; no test, shot or tool ever
   creates an `Updater` or makes Sparkle fetch the feed. Install nothing, change no system or
   app settings (no `defaults write`, no symbolic hotkey edits, no `tccutil`). Never run
   `scripts/bundle.sh --install`.

## Style

- No em dashes or en dashes anywhere: code, comments, strings, docs, output. Use commas, colons,
  parentheses or separate sentences. Write plainly, without figurative or rhetorical prose.
- Comments only for the non-obvious (a constraint, a gotcha, a why), one or two lines.
- No `try!` in `Sources/`; no `try?` in `Sources/SnapCore/**/*Store*.swift` (swiftlint enforces
  both). State files are written with `AtomicFile` (temp file, then rename).
- `@unchecked Sendable` only at a documented boundary (the Carbon callback box).
