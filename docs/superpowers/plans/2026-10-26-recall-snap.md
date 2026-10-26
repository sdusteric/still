# Recall phase 1, Snap part: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Snap reads the text in every screenshot on the Mac, hides likely secrets, and writes one Recall entry file (plus a preview) per screenshot for Shelf to search; it keeps screenshots 30 days by default and opens a result in its history window.

**Architecture:** A `TextRecognizer` protocol in `SnapCore` with a Vision implementation and a fake. A `RecallIndexer` actor in `SnapCore/Recall` owns the queue: OCR (cached as `history/<id>/ocr.json`), `SecretFilter`, then `RecallWriter` writes `<id>.json` and `<id>.jpg` into the recall folder. `AppWiring` feeds it from the existing store, edit, trash and sweep call sites. `ShelfURL` learns `open-item?id=`.

**Tech Stack:** Swift 6, Vision (`RecognizeTextRequest`), Core Text for test images, ImageIO for JPEG, Swift Testing.

**Spec:** `../shelf/docs/superpowers/specs/2026-10-26-recall-design.md` (sections 4, 6, 7, 11, 12, 13). Read it with this plan.

**Sibling plans:** `../shelf/docs/superpowers/plans/2026-10-26-recall-shelf.md` (reads what this plan writes) and `../booth/docs/superpowers/plans/2026-10-26-recall-booth.md`. The contract change is Task 1 of the Shelf plan.

## Global Constraints

- macOS 27, Swift 6, Swift Testing. Build with `swift build --scratch-path "$TMPDIR/snap-<task>"`; delete it by exact path when done.
- Every test, shot and `snapctl` run sets `SNAP_HOME` to a fresh `mktemp -d` and `SNAP_NO_UPDATES=1`. Nothing touches `~/Library/Application Support/Shelf`.
- Recall folder: `~/Library/Application Support/Shelf/recall/snap/` for the default home, `$SNAP_HOME/ShelfRecall/snap/` otherwise. Folder mode 0700, files 0600, written with `ShelfStatusWriter.writeAtomically` (temp, fsync, rename).
- Entry: `schema` 1, `app` "snap", `kind` "screenshot", file at most 4 MB, `title` and `context` values at most 120 characters, snake_case keys exactly as spec section 6.
- Preview: 480 px on the long side, JPEG quality 0.7, lowered by 0.1 until at most 80 KB.
- OCR: `.accurate`, language correction on, `automaticallyDetectsLanguage` on, `recognitionLanguages` `["en-US", "zh-Hans", "zh-Hant"]`; drop lines under 2 characters or with confidence under 0.3. Utility priority, one at a time, never on the capture path.
- Retention: images `3d`, `30d` (default), `1y`; recordings stay 3 days.
- `settings.json` uses camelCase keys (existing style). New fields are under `general`: `screenshotRetention`, `searchInShelf`, `searchPreviews`, `searchExcludedApps`. This supersedes the spec's `screenshot_retention` spelling; the meaning is the same.
- Vision is offline and needs no permission; it may be imported in `SnapCore` (spec section 10). No network (`no_network`), no Accessibility APIs.
- Copy: American spelling, no em or en dashes. Exact strings are in the tasks.
- No `try!` in `Sources/`, no `try?` in `Sources/SnapCore/**/*Store*.swift`.
- Agents never commit; "Commit" steps are for the main session.
- UI work (Task 8): invoke `impeccable`, `design-taste-frontend`, `unslop` and `find-animation-opportunities`, and check motion against `../app-updates/docs/motion-gate.md`.

## Review Focus

1. A capture is trashed or swept while its OCR is still running: no entry may be written afterwards. Test in Task 5: `removeDuringOCRWritesNothing`.
2. The owner edits a screenshot twice quickly: the entry ends up from the second edit, not the first. Test in Task 5: `latestEditWins`.
3. A screenshot with no text at all (a photo, a color swatch): an entry with zero segments is still written so the item is findable by its app name and title in Shelf, and OCR is not retried each launch. Test in Task 5: `textlessScreenshotGetsEmptyEntry`.
4. Snap launches with the recall folder deleted by hand, or with entries left from an older run: reconcile rebuilds missing entries from `ocr.json` without running OCR again, and removes orphans. Test in Task 5: `reconcileUsesCachedOCR`.
5. A 1-year retention with many captures: history listing stays inside its budget. Test in Task 3: `listing1500ItemsWithinBudget`.

---

### Task 1: Paths, entry model and writer

**Files:**
- Modify: `Sources/SnapCore/Model/SnapPaths.swift`
- Create: `Sources/SnapCore/Recall/RecallEntry.swift`, `Sources/SnapCore/Recall/RecallWriter.swift`
- Test: `Tests/SnapCoreTests/RecallWriterTests.swift`

**Interfaces:**
- Produces:
  - `SnapPaths.recallDirectory: URL` (default home: `~/Library/Application Support/Shelf/recall/snap`; else `home/ShelfRecall/snap`)
  - `struct RecallEntry: Codable, Sendable, Equatable { schema = 1; app = "snap"; id; kind = "screenshot"; title; createdAt; updatedAt; language: String?; preview: String?; context: [String: String]; segments: [Segment] }` with `struct Segment: Codable { text: String }`, snake_case `CodingKeys` (`created_at`, `updated_at`)
  - `struct RecallWriter: Sendable { init(directory: URL); func write(_ entry: RecallEntry, previewFrom imageURL: URL?) throws; func remove(id: String) throws; func removeAll() throws; func removePreviews() throws; func storedIDs() throws -> Set<String> }`
  - `static let maxEntryBytes = 4 * 1024 * 1024`, `maxPreviewBytes = 80 * 1024`, `previewLongSide = 480`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func writesEntryWithSnakeCaseKeys()      // JSON has "created_at", "schema": 1, "app": "snap", "kind": "screenshot"
@Test func filesAre0600AndFolder0700()
@Test func previewIsAtMost480And80KB()         // from a 5120 x 2880 noise image: long side 480, bytes <= 81920
@Test func noPreviewWhenImageURLNil()          // entry.preview nil and no .jpg
@Test func cutsTitleAndContextTo120()
@Test func removeDeletesEntryAndPreview()
@Test func removeAllEmptiesFolderOnly()        // other files in the parent ShelfRecall stay
@Test func refusesEntryOver4MB()               // throws, nothing written
@Test func recallDirectoryFollowsHome()        // non-default SNAP_HOME gives home/ShelfRecall/snap
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --scratch-path "$TMPDIR/snap-recall1" --filter RecallWriterTests`
Expected: FAIL, types not found.

- [ ] **Step 3: Implement**

Reuse `ShelfStatusWriter.writeAtomically` and set permissions after the rename. Make the preview with `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceThumbnailMaxPixelSize` 480, transform applied) and `CGImageDestination` JPEG, stepping quality 0.7, 0.6 ... down to 0.3; if still over 80 KB, write no preview. Write the preview before the entry, so an entry never names a missing file.

- [ ] **Step 4: Run them and see them pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit (main session)**

```bash
git add Sources/SnapCore/Model/SnapPaths.swift Sources/SnapCore/Recall Tests/SnapCoreTests/RecallWriterTests.swift
git commit -m "Recall: entry files and previews for Shelf search"
```

### Task 2: SecretFilter

**Files:**
- Create: `Sources/SnapCore/Logic/SecretFilter.swift`
- Test: `Tests/SnapCoreTests/SecretFilterTests.swift`

**Interfaces:**
- Produces: `enum SecretFilter { static let replacement = "[hidden]"; static func redact(_ lines: [String]) -> [String] }` (lines in, lines out, so PEM blocks spanning lines are handled)

- [ ] **Step 1: Write the failing table test**

```swift
@Test(arguments: [
  ("key sk_live_51HxQe2LkS8vA0bC9dEfGh1234", "key [hidden]"),
  ("sk_test_4eC39HqLyjWDarjtT1zdp7dc", "[hidden]"),
  ("rk_live_abcDEF1234567890xyz", "[hidden]"),
  ("pk_live_abcDEF1234567890xyz", "[hidden]"),
  ("token ghp_16C7e42F292c6912E7710c838347Ae178B4a", "token [hidden]"),
  ("gho_16C7e42F292c6912E7710c838347Ae178B4a", "[hidden]"),
  ("github_pat_11ABCDEFG0123456789_abcdefghijklmnop", "[hidden]"),
  ("xoxb-123456789012-1234567890123-AbCdEfGhIjKlMnOp", "[hidden]"),
  ("xoxp-123456789012-1234567890123-AbCdEfGhIjKlMnOp", "[hidden]"),
  ("AKIAIOSFODNN7EXAMPLE", "[hidden]"),
  ("ASIAIOSFODNN7EXAMPLE", "[hidden]"),
  ("AIzaSyA1234567890abcdefghijklmnopqrstu", "[hidden]"),
  ("sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345", "[hidden]"),
  ("sk-proj-abcdefghij0123456789ABCD", "[hidden]"),
  ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "[hidden]"),
  ("Q2FzZSBjbG9zZWQgd2l0aCBubyBhY3Rpb24gbmVlZGVkIGJ5IHVz", "[hidden]"),   // 32+ chars, entropy > 4.0
  ("aB3dE5fG7hJ9kL1mN2pQ4r", "[hidden]")                                   // 22 chars, all three classes, entropy > 3.5
]) func hidesSecret(input: String, expected: String)

@Test(arguments: [
  "commit 9fceb02d0ae598e95dc970b74767f19372d61af8",   // 40 hex: below the 4.0 threshold, survives
  "id 123e4567-e89b-12d3-a456-426614174000",           // UUID survives
  "internationalization",                               // long English word survives
  "HistoryWindowController",                            // identifier with no digits survives
  "Stripe error 4402: card declined",
  "截图里的错误"
]) func keepsOrdinaryText(input: String)                // redact([input]) == [input]

@Test func hidesEveryLineOfPrivateKeyBlock()            // BEGIN line, body lines and END line all become "[hidden]"
```

- [ ] **Step 2: Run, fail, implement, run, pass**

Run: `swift test --scratch-path "$TMPDIR/snap-recall2" --filter SecretFilterTests`. Rules exactly as spec 7.3 (including the 20 to 31 character rule). Tokens are split on whitespace and on `"'`,;:()[]{}<>`; a matched token is replaced in place, keeping the rest of the line. If a row in the table above turns out not to meet the entropy threshold as computed, adjust that test value (not the threshold) so it is a true example of its rule, and say so in the commit message.

- [ ] **Step 3: Commit (main session)**

```bash
git add Sources/SnapCore/Logic/SecretFilter.swift Tests/SnapCoreTests/SecretFilterTests.swift
git commit -m "SecretFilter: hide likely keys and tokens from search text"
```

### Task 3: Settings and retention

**Files:**
- Modify: `Sources/SnapCore/Model/Settings.swift` (`GeneralSettings`)
- Modify: `Sources/SnapCore/Model/HistoryStore.swift` (`sweep`)
- Modify: `Sources/Snap/AppWiring.swift:264` (`sweepHistory` passes the setting)
- Test: `Tests/SnapCoreTests/SettingsTests.swift`, `Tests/SnapCoreTests/HistoryStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum ScreenshotRetention: String, Codable, Sendable, CaseIterable { case threeDays = "3d", thirtyDays = "30d", oneYear = "1y"; var interval: TimeInterval; var label: String }` (labels `3 days`, `30 days`, `1 year`)
  - `GeneralSettings.screenshotRetention: ScreenshotRetention = .thirtyDays`, `searchInShelf: Bool = true`, `searchPreviews: Bool = true`, `searchExcludedApps: [String] = ["Passwords", "Keychain Access", "1Password", "Bitwarden"]`
  - `HistoryStore.sweep(skipping: Set<String> = [], now: Date? = nil, imageRetention: TimeInterval = HistoryStore.retention) throws -> [String]` (videos always use `HistoryStore.retention`)

- [ ] **Step 1: Write the failing tests**

```swift
@Test func missingKeysReadAsNewDefaults()     // a v2 settings.json without the four keys: 30d, true, true, the four apps
@Test func retentionRoundTrips()              // "screenshotRetention": "1y"
@Test func unknownRetentionFallsBackTo30Days() // "screenshotRetention": "5d"
@Test func sweepKeepsImagesFor30Days()        // image 10 days old kept with imageRetention 30d; video 4 days old swept
@Test func sweepHonorsThreeDays()             // image 4 days old swept with 3d
@Test func listing1500ItemsWithinBudget()     // HistoryFixture 1,500 items: allItems() p95 of 20 runs < 50 ms
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --scratch-path "$TMPDIR/snap-recall3" --filter "SettingsTests|HistoryStoreTests"`
Expected: FAIL.

- [ ] **Step 3: Implement the settings and sweep**

Follow the existing `container.value(.key, default: defaults.x)` pattern; `Settings.currentVersion` stays 2. In `AppWiring.sweepHistory`, read `settings.general.screenshotRetention.interval`.

- [ ] **Step 4: If `listing1500ItemsWithinBudget` fails, add the listing cache**

`HistoryStore` keeps `[CaptureItem]` behind its existing lock, updated by its own `add`, `saveEdited`, `remove`, `trash` and `sweep`, and dropped when the history folder's modification date differs from the one recorded at load. `allItems()` returns the cache when valid. Skip this step when `listing1500ItemsWithinBudget` already passes after Step 3.

- [ ] **Step 5: Run the tests and see them pass**

Same command. Expected: PASS.

- [ ] **Step 6: Commit (main session)**

```bash
git add Sources/SnapCore/Model Sources/Snap/AppWiring.swift Tests/SnapCoreTests
git commit -m "Keep screenshots 30 days by default; search settings"
```

### Task 4: Text recognition

**Files:**
- Create: `Sources/SnapCore/Recall/TextRecognizer.swift` (protocol, `OCRResult`, `OCRStore`)
- Create: `Sources/SnapCore/Recall/VisionTextRecognizer.swift`
- Create: `Sources/SnapCore/Fakes/FakeTextRecognizer.swift`
- Create: `Sources/SnapCore/Fakes/SyntheticText.swift`
- Test: `Tests/SnapCoreTests/VisionTextRecognizerTests.swift`, `Tests/SnapCoreTests/OCRStoreTests.swift`

**Interfaces:**
- Produces:
  - `protocol TextRecognizer: Sendable { func recognize(imageAt url: URL) async throws -> OCRResult }`
  - `struct OCRResult: Codable, Sendable, Equatable { version = 1; imageName: String; language: String?; lines: [Line] }`, `struct Line: Codable { text: String; confidence: Float; box: [Double] }` (normalized, top-left origin)
  - `struct OCRStore: Sendable { init(history: HistoryStore); func load(id: String) -> OCRResult?; func save(_ result: OCRResult, id: String) throws; func discard(id: String) throws }` (file `history/<id>/ocr.json`; `load` returns nil when `imageName` is not the item's current image name, so an edit invalidates it)
  - `struct VisionTextRecognizer: TextRecognizer` (settings from Global Constraints)
  - `final class FakeTextRecognizer: TextRecognizer` (`init(results: [String: OCRResult] = [:], delay: Duration = .zero)`, `calls: [URL]`, keyed by file name)
  - `enum SyntheticText { static func png(lines: [String], size: CGSize, fontSize: CGFloat) throws -> Data }` (black text on white, Core Text, PingFang SC for CJK)

- [ ] **Step 1: Write the failing tests**

```swift
@Test func recognizesEnglishLines()     // lines ["Quarterly Stripe error 4402", "card declined"], 1600 x 400 at 36 pt: every word found, case-insensitive
@Test func recognizesChineseLine()      // ["截图里的错误信息"]: the joined text contains "错误"
@Test func dropsShortAndLowConfidence() // through a stubbed observation list: 1-char and 0.2-confidence lines removed (filter is a pure static func `VisionTextRecognizer.keep(_:)`)
@Test func fullDisplayTiming()          // 5120 x 2880 with 40 lines: prints elapsed; fails only above 5 s (spike S2 record)
@Test func ocrStoreRoundTrip()
@Test func ocrStoreIgnoresStaleImageName() // save for original, item later edited: load returns nil
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --scratch-path "$TMPDIR/snap-recall4" --filter "VisionTextRecognizerTests|OCRStoreTests"`
Expected: FAIL.

- [ ] **Step 3: Implement**

Use the Swift Vision API (`RecognizeTextRequest`, `perform(on: URL)`). Add Vision to the `SnapCore` line of `CLAUDE.md`'s Layout section. Record the timing printed by `fullDisplayTiming` and the Chinese result in the spec's section 14 under S2. If automatic detection misses the Chinese line while fixed hints find it, set `automaticallyDetectsLanguage = false` and keep the hints, and note that in S2.

- [ ] **Step 4: Run them and see them pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit (main session)**

```bash
git add Sources/SnapCore/Recall Sources/SnapCore/Fakes Tests/SnapCoreTests
git commit -m "Vision text recognition with a cached ocr.json per capture"
```

### Task 5: RecallIndexer

**Files:**
- Create: `Sources/SnapCore/Recall/RecallIndexer.swift`
- Test: `Tests/SnapCoreTests/RecallIndexerTests.swift`

**Interfaces:**
- Consumes: `RecallWriter` (Task 1), `SecretFilter` (Task 2), `GeneralSettings` search fields (Task 3), `TextRecognizer`, `OCRStore` (Task 4), `HistoryStore.item(id:)`, `allItems()`.
- Produces:
  - `struct RecallOptions: Sendable, Equatable { enabled: Bool; previews: Bool; excludedApps: [String] }` (`init(_ general: GeneralSettings)`)
  - `actor RecallIndexer { init(history: HistoryStore, ocr: OCRStore, recognizer: any TextRecognizer, writer: RecallWriter, options: RecallOptions, log: Log?) }`
  - `func enqueue(_ id: String, force: Bool = false)` (force discards `ocr.json` first: edits)
  - `func remove(_ ids: [String])`
  - `func update(options: RecallOptions)` (off: `writer.removeAll()` and clear the queue; on: `reconcile()`; previews off: `writer.removePreviews()`; new excluded apps: remove their entries)
  - `func reconcile()` (orphans removed; screenshots without an entry queued newest first)
  - `var pending: Int`, `var onPendingChange: @Sendable (Int) -> Void`
  - `func drain() async` (test helper: returns when the queue is empty)

Entry built from an item: `id` = item id; `title` = `sourceApp ?? "Screenshot"`; `created_at` = item `createdAt`; `updated_at` = now; `language` from OCR; `context` = `["source_app": sourceApp]` when known; `segments` = redacted lines, one each; preview from `currentURL` when `previews` is on.

- [ ] **Step 1: Write the failing tests**

Use `HistoryFixture`, `FakeTextRecognizer`, temp `SNAP_HOME`.

```swift
@Test func storedScreenshotGetsEntry()          // AC-R1 at unit level: entry text "Quarterly Stripe error 4402"
@Test func secretIsHiddenInEntry()              // AC-R2: OCR line with sk_live_ + 24 chars: entry contains "[hidden]", no "sk_live_"
@Test func recordingsAreSkipped()
@Test func excludedAppIsSkipped()               // sourceApp "1Password": no entry, recognizer never called
@Test func addingExclusionRemovesEntries()
@Test func editRereadsCurrentImage()            // enqueue(force: true) after saveEdited: recognizer called with the edited file
@Test func latestEditWins()                     // two forced enqueues with a slow fake: final entry from the second result
@Test func removeDuringOCRWritesNothing()       // slow fake, remove([id]) mid-OCR: no file after drain()
@Test func textlessScreenshotGetsEmptyEntry()   // segments == [], ocr.json saved, a second reconcile does not call the recognizer
@Test func reconcileUsesCachedOCR()             // delete the recall folder, reconcile: entries back, recognizer call count unchanged
@Test func reconcileRemovesOrphans()
@Test func turningOffDeletesEverything()        // AC-R9 Snap half: folder empty, ocr.json files kept
@Test func backfillIsNewestFirst()
@Test func pendingCountReported()
```

- [ ] **Step 2: Run, fail, implement, run, pass**

Run: `swift test --scratch-path "$TMPDIR/snap-recall5" --filter RecallIndexerTests`. Keep a per-id generation counter: `remove` and a newer `enqueue` bump it; a finished OCR whose generation is stale writes nothing. Before writing, re-check that `history.item(id:)` still exists.

- [ ] **Step 3: Commit (main session)**

```bash
git add Sources/SnapCore/Recall/RecallIndexer.swift Tests/SnapCoreTests/RecallIndexerTests.swift
git commit -m "RecallIndexer: OCR queue that follows the history"
```

### Task 6: Wiring and status

**Files:**
- Modify: `Sources/Snap/AppWiring.swift` (create the indexer; `captureStored` at 409, edit save at 631, trash at 1119, `sweepHistory` at 264, settings change at 345, launch at 210, `publishShelfStatus` at 314)
- Modify: `Sources/SnapCore/Model/ShelfStatus.swift` (`recall`, `recall_pending`)
- Test: `Tests/SnapCoreTests/ShelfStatusTests.swift`

**Interfaces:**
- Consumes: `RecallIndexer` (Task 5).
- Produces: `ShelfStatusWriter.write(captures: [ShelfCapture], showPreviews: Bool, recall: RecallStatus?, now: Date = Date()) throws`, `struct RecallStatus: Sendable, Equatable { enabled: Bool; pending: Int }`; JSON `"recall": "on" | "off"`, `"recall_pending": <int>` (omitted when 0).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func statusCarriesRecallFields()       // recall on, pending 3: "recall":"on","recall_pending":3
@Test func zeroPendingIsOmitted()
@Test func statusStaysUnder16KB()            // with 3 captures and recall fields
```

- [ ] **Step 2: Run, fail, implement, run, pass**

Run: `swift test --scratch-path "$TMPDIR/snap-recall6" --filter ShelfStatusTests`.

Wiring: `captureStored` calls `indexer.enqueue(item.id)` after `historyChanged()`. Edit save calls `enqueue(id, force: true)` after the store returns. Trash calls `remove([id])`. `sweepHistory` passes the ids returned by `sweep` to `remove`, and at launch calls `reconcile()` after the first sweep. A settings change compares old and new `RecallOptions` and calls `update(options:)`. `onPendingChange` republishes the Shelf status (at most once a second, through the existing `shelfQueue`).

- [ ] **Step 3: Check that capture latency did not move (AC-R4)**

Run the AC05 bench the way `scripts/check.sh` or the Snap acceptance does (`snapbench latency --fake ...`) twice, with recall options on and off (add a `--recall on|off` flag to `snapbench` that builds the indexer with a `FakeTextRecognizer` of 300 ms delay). Expected: p95 with recall on within 5 percent of off.

- [ ] **Step 4: Commit (main session)**

```bash
git add Sources Tests
git commit -m "Feed Recall from capture, edit, trash and sweep"
```

### Task 7: open-item

**Files:**
- Modify: `Sources/SnapCore/Logic/ShelfURL.swift`
- Modify: `Sources/Snap/AppDelegate.swift` (`application(_:open:)` at 56, `perform` at 64, `pendingShelfActions`)
- Modify: `Sources/SnapUI/History/HistoryWindowController.swift` (`HistoryWindowModel.reveal`), `Sources/SnapUI/History/HistoryView.swift` (scroll to `scrollTarget`)
- Modify: `resources/Info.plist.in:35-36`, `scripts/check.sh:114-115` (the literal becomes `'["capture-area","capture-window","open-item","check-for-updates"]'`)
- Test: `Tests/SnapCoreTests/ShelfURLTests.swift`, `Tests/SnapUITests/HistoryWindowModelTests.swift`

**Interfaces:**
- Produces:
  - `enum ShelfRequest: Sendable, Equatable { case action(ShelfAction); case openItem(id: String) }`
  - `ShelfURL.request(_ url: URL) -> ShelfRequest?` (existing `parse` kept for the plain actions)
  - `ShelfActionHandling.openItem(id: String)` (new requirement)
  - `ShelfURL.advertisedActions` = `["capture-area", "capture-window", "open-item", "check-for-updates"]` (order as in the plist)
  - `HistoryWindowModel.reveal(_ id: String)` (clears search and filter, selects the id if it exists, sets `scrollTarget`), `var scrollTarget: String?`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func parsesOpenItem()                    // snap://open-item?id=20261024-140322-3f9a1c2e
@Test func ignoresUnknownParameters()          // &t=4&x=y still parses
@Test func refusesBadOpenItemIDs()             // missing id, "", "../x", 65 chars, a path component
@Test func plainActionsUnchanged()
@Test func revealSelectsAndClearsSearch()      // searchText "x", filter .videos before; after: "", .all, selection [id], scrollTarget id
@Test func revealUnknownIDSelectsNothing()
```

- [ ] **Step 2: Run, fail, implement, run, pass**

Run: `swift test --scratch-path "$TMPDIR/snap-recall7" --filter "ShelfURLTests|HistoryWindowModelTests"`. `AppDelegate.openItem(id:)` calls `wiring.openHistoryWindow()` and then `model.reveal(id)`. `HistoryView` wraps its grid in `ScrollViewReader` and scrolls to `scrollTarget` when it changes, without animation.

- [ ] **Step 3: Commit (main session)**

```bash
git add Sources resources/Info.plist.in scripts/check.sh Tests
git commit -m "snap://open-item opens a capture in History"
```

### Task 8: Settings UI and copy

**Files:**
- Modify: `Sources/SnapUI/Settings/SettingsView.swift` (General tab, near the "Shelf" group at 466 to 474)
- Modify: `Sources/SnapUI/History/` subtitle and empty state strings (they name the retention)
- Test: `Tests/SnapUITests/SettingsCopyTests.swift`, shots

Exact copy:

| Place | String |
|---|---|
| Picker row title | `Keep screenshots for` |
| Picker subtitle | `Recordings are kept for 3 days.` |
| Group title | `Search in Shelf` |
| Toggle 1 | `Make screenshots searchable in Shelf` |
| Toggle 2 | `Show previews in Shelf search` |
| Exclude row title | `Don't read screenshots of` |
| Help | `Snap reads the text in your screenshots on this Mac. It skips likely passwords and keys. Nothing is uploaded.` |
| History subtitle | `Last 3 days` / `Last 30 days` / `Last year` |
| History empty title | `No captures in the last 3 days` / `... 30 days` / `No captures in the last year` |
| History empty body | `Snap keeps every screenshot here for 30 days and recordings for 3 days. Press ⇧⌘4 to take one.` (number from the setting, key cap rule unchanged) |
| History footer | `12 captures · 41 MB · screenshots kept for 30 days` |

- [ ] **Step 1: Invoke the UI skills**

Invoke `impeccable`, `design-taste-frontend` and `unslop` before writing the views. The exclude list is a token field with an add menu listing the names of running regular apps (`NSWorkspace.shared.runningApplications` read in `SnapSystem`, passed to the UI as `[String]`) and a remove button per token.

- [ ] **Step 2: Write the copy test**

```swift
@Test func historyCopyFollowsRetention()  // the three subtitles, empty titles and footer strings above
```

Run: `swift test --scratch-path "$TMPDIR/snap-recall8" --filter SettingsCopyTests`. Fail, implement the strings as pure functions in `SnapCore/Logic/HistoryCopy.swift`, pass.

- [ ] **Step 3: Build the views and take shots**

Run Snap's shot mode for the Settings General tab and the History empty state, light and dark, and look at the PNGs. Run `find-animation-opportunities` and the motion gate: no new motion is expected; record that in the commit message.

- [ ] **Step 4: Commit (main session)**

```bash
git add Sources Tests
git commit -m "Settings: retention and Search in Shelf"
```

### Task 9: snapctl recall and the gate

**Files:**
- Create: `Sources/snapctl/RecallCommand.swift`
- Modify: `Sources/snapctl/main.swift` (usage text, `case "recall":`)

**Interfaces:**
- Produces: `snapctl recall fixture --line <text> [--line <text> ...] [--source-app <name>] [--age-days N]` (renders the lines with `SyntheticText` and adds the PNG to history through `HistoryStore.add`, back-dated by `--age-days`), `snapctl recall build [--fake-ocr <file.json>] [--json]` (runs `RecallIndexer.reconcile()` and `drain()` over `$SNAP_HOME`'s history with the real Vision recognizer, or a fake loaded from a JSON map of file name to lines) and `snapctl recall list [--json]` (ids, titles, segment counts). Both refuse the default `SNAP_HOME` with `refuseDefaultHome`.

- [ ] **Step 1: Acceptance run (AC-R1 to AC-R3 end to end)**

```bash
export SNAP_HOME="$(mktemp -d)" SNAP_NO_UPDATES=1
"$BIN/snapctl" recall fixture --line "Quarterly Stripe error 4402" --line "key sk_live_51HxQe2LkS8vA0bC9dEfGh12" --source-app Notes
"$BIN/snapctl" recall fixture --line "Old screenshot text" --age-days 40
"$BIN/snapctl" recall build --json
"$BIN/snapctl" history sweep
"$BIN/snapctl" recall build --json
"$BIN/snapctl" recall list --json
```
Expected: after the first build, two entries; the first's text has "Quarterly Stripe error 4402" and "[hidden]", no "sk_live_". After the sweep (30-day default) and second build, only the first entry is left. Keep `$SNAP_HOME/ShelfRecall` for the Shelf plan's Task 13 and note its path.

- [ ] **Step 2: Full gate once**

Run: `SNAP_SCRATCH="$TMPDIR/snap-check" scripts/check.sh`
Expected: every gate passes (build, test, lint, snapctl-no-sck, cli-no-sparkle, bundle, codesign, signing, plist, sparkle, requirement, dashes).

- [ ] **Step 3: Commit (main session)**

```bash
git add Sources/snapctl
git commit -m "snapctl recall build and list"
```
