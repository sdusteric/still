# Handoff: redesign Still's menu bar menu and Settings (2026-11-26)

Goal: the owner asked to "optimize and design this menu better" and said "the settings ui needs to
look better". Make both clearly better while staying native macOS. Done means: committed, pushed,
installed (mac-apps rules), with light and dark shots of every changed surface checked.

Read first: `CLAUDE.md` in this repo (safety rules, gate, shots), `../CLAUDE.md` (shared rules),
design doc `docs/superpowers/specs/2026-10-24-snap-design.md` (12.1 menu, 12.2 settings, 17 visual
design, 20.10, 20.17 Settings and History look), mockups `docs/mockup/png/07-menu.png`,
`08-settings.png`, `19-settings-recording.png`, `20-menu-m2.png`.

## Verified facts

- The owner's live menu (screenshot of 2026-11-26, macOS 27) has 21 rows: Capture Area,
  Capture Previous Area, Capture Scrolling Area, Capture Window, Capture Fullscreen, All-in-One…,
  Record Screen…, separator, Apply Background / Open in Annotate / Pin / Copy Text from Last
  Capture, separator, Recent Captures header with 3 entries ("Screenshot 10.51.06" over "Just
  now"), Capture History…, Open Image…, Open Clipboard Image, separator, Check for Updates…,
  Settings…, Quit Still.
- In that live menu the recent captures show no thumbnail, although
  `StatusMenuController.makeItem` sets `menuItem.image = Self.thumbnailImage(...)` (an
  `NSImage(size:flipped:drawingHandler:)`, 32 pt, which draws a neutral tile even with no
  image). The cause is not known. It might be the drawing-handler image or the two-line
  `attributedTitle` on macOS 27. The shot renderer (`MenuPreviewView`) draws thumbnails, so the
  shots do not show the bug. Check it with a bitmap-backed `NSImage` or a custom item view.
- All-in-One showed no ⇧⌘5 in the owner's menu, while Capture Area (⇧⌘4) and Capture
  Fullscreen (⇧⌘3) did. Check `MenuModel.actionItem` and the owner's shortcuts before redesigning.
- Pressing a capture shortcut while the menu was open used to wait until the menu closed (up to
  7 s in the log). That is fixed, but the new code has not been tried on the real Mac yet:
  `StatusMenuController.onTrackingChanged`, `AppDelegate.menuTracking`, `HotkeyPlan.action`.
  The menu's own key equivalents are the fallback, so keep them on the capture items.

## Where things live

- Menu data: `Sources/SnapCore/Logic/MenuModel.swift` (`MenuItemID`, `MenuInput`, `MenuModel`,
  pure and tested in `Tests/SnapCoreTests/MenuModelTests.swift`, including the item order).
- Live menu: `Sources/SnapUI/Menu/StatusMenuController.swift` (builds `NSMenu` from the model).
- Shot renderer of the menu: `Sources/SnapUI/Menu/MenuPreviewView.swift` (`MenuDemo`,
  `MenuM2Demo`, `MenuPermissionDemo`). Keep it in step with the live menu.
- Menu actions: `AppDelegate.menuSelected` and `menuModel()` in `Sources/Snap/AppDelegate.swift`.
- Settings: `Sources/SnapUI/Settings/SettingsView.swift` (897 lines; five tabs General, Capture,
  Quick Access, Recording, Shortcuts, made of `SettingsGroup`, `SwitchRow` and recorder rows),
  tokens in `Sources/SnapUI/Shared/Theme.swift` (`Theme.Settings`, `Theme.Colors.desk*`).
- Shots (headless, safe): `scripts/bundle.sh --release` then
  `OUT=$TMPDIR/x scripts/shots.sh menu menu-m2 menu-permission settings settings-shortcuts settings-general settings-general-full settings-recording`.

## Ideas to weigh (not decided)

- Fewer top-level rows: Option alternates (`NSMenuItem.isAlternate`) for Capture Previous Area
  (under Capture Area) and Open Clipboard Image (under Open Image…); a "Last Capture" submenu
  for Background, Annotate, Pin and Copy Text.
- SF Symbol icons on the action items, as macOS 26 and later menus use, with thumbnails that
  actually render for recent captures and one line per entry ("Screenshot 10.51" and the time).
- Settings: run impeccable critique on the shots first; the owner gave no specifics beyond
  "needs to look better".

## Rules that apply

impeccable (critique, then polish) on both surfaces, unslop on all copy, motion gate
(`../app-updates/docs/motion-gate.md`) for any motion, sizes on a 4 pt grid, American spelling,
no em or en dashes, plain words. Update `MenuModelTests` and the shot size tests if rows change.
Run the full gate once at the end (`SNAP_SCRATCH=$TMPDIR/... scripts/check.sh`).
