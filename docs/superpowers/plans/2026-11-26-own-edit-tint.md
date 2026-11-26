# Tint My Own Edits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An off-by-default setting that tints the user's unsaved edits, in a colour they can pick, in the code editor
and the CSV Table view. It clears on save.

**Architecture:**
- A pure core function diffs the saved text against the current text and returns line ranges or byte ranges.
- The code editor applies the ranges under a new `own` decoration owner. A per-view `OwnEditMarks` follows the
  `GitDocumentMarks` pattern: a pause timer, then an off-main diff.
- `CSVTableModel` computes byte spans once per buffer version and returns a new `CSVTint.own`.
- Ledger `.user` edits stop being drawn.

**Tech Stack:** Swift 6, MetalUI (`CodeDecorations`, `CodeDecorationOwner`, `ColorPicker`), Swift Testing.

**Spec:** docs/superpowers/specs/2026-11-26-own-edit-tint-design.md

## Global Constraints

- The setting defaults to **off**.
- Toggle label: "Tint my own edits". Hint: "Colours what you've changed since your last save, in the editor and in
  tables."
- The colour defaults to the theme slot `userAuthor` (`Color.userAuthor`). A picked colour is stored as `#RRGGBB` or
  `#RRGGBBAA` hex. "Reset to theme colour" clears it.
- The tint clears on save, and with the setting off nothing of the user's is tinted. This includes ledger `.user`
  edits, saved or not.
- Agent and outside tints, and Keep/Revert, are unchanged.
- With the setting off, or while idle, nothing runs.
- The diff runs off the main thread after a 0.3 s typing pause, using the injected clock.
- Above `GitGutterMarks.sizeLimit` there is no tint and no work.
- Run UI tests with `swift test --no-parallel`.
- `swiftlint --strict` must be clean.
- Never weaken an assertion, raise a timeout or raise a frame guard.

## Review Focus

1. Undo back to exactly the saved text: the tint disappears (empty diff). Tasks 1, 2 and 3.
2. Toggling the setting off while edits are tinted clears them at once, in open editors and tables. Tasks 2 and 3.
3. A theme switch with no picked colour follows the new theme's `userAuthor`; with a picked colour, nothing changes.
   Task 4.
4. A file over the size limit gets no tint and spawns no diff. Task 2.
5. An outside change merged into a dirty buffer recomputes the tint against the saved snapshot. Task 2.

---

### Task 1: Setting and diff core

**Files:**
- Modify: `Sources/AlloyCore/Model/AlloySettings.swift`
- Create: `Sources/AlloyCore/Editor/OwnEdits.swift`
- Test: `Tests/AlloyCoreTests/OwnEditsTests.swift`

**Interfaces:**
- Produces:
  - `public struct OwnEditTint: Codable, Equatable, Sendable { public var enabled: Bool; public var colorHex: String? }`.
    The defaults are `false` and `nil`. The decode is tolerant (a missing or wrong-typed key falls back to its default),
    like `GitSettings`.
  - `AlloySettings.ownEditTint: OwnEditTint`, also decoded tolerantly.
  - `public enum OwnEdits`:
    - `static func changedLines(saved: String, current: String) -> [Range<Int>]`: 0-based line ranges in `current`.
      A deletion-only region yields an empty range at the line where it happened.
    - `static func changedBytes(saved: String, current: String) -> [Range<Int>]`: UTF-8 byte ranges in `current`.
      Built from `TextDiff.regions` on `TextDiff.lineUnits`, then narrowed to the differing bytes within each region.

- [ ] **Step 1: Write the failing tests.**
  - `settingDefaultsOffAndDecodesOldFiles`: `AlloySettings()` has `ownEditTint.enabled == false` and
    `colorHex == nil`. Decoding `{}` gives the same. `{"ownEditTint":{"enabled":true,"colorHex":"#FF0000"}}`
    round-trips.
  - `identicalTextHasNoChanges`: both functions return `[]` for `saved == current`.
  - `typedLineIsOneRange`: saved `"a\nb\nc\n"`, current `"a\nbX\nc\n"`. `changedLines` returns `[1..<2]`;
    `changedBytes` covers the `X` and lies inside line 1's bytes.
  - `insertedLinesAndDeletionPoint`: inserting two lines after line 0 gives `[1..<3]`. Deleting line 1 gives
    `[1..<1]`.
  - `undoBackToSavedClears`: the current text equals the saved text after an edit and its reversal, giving `[]`.
- [ ] **Step 2:** Run `swift test --filter OwnEditsTests`. Expect it to FAIL (the symbols are undefined).
- [ ] **Step 3: Implement.** No main-actor isolation: these run off main.
- [ ] **Step 4:** Run `swift test --filter OwnEditsTests`. Expect PASS.
- [ ] **Step 5:** Commit: `feat(own-tint): setting and saved-versus-buffer diff`.

### Task 2: Code editor

**Files:**
- Create: `Sources/AlloyKit/Code/OwnEditMarks.swift`, the per-view owner object, modelled on
  `Sources/AlloyKit/Git/GitDocumentMarks.swift`.
- Modify:
  - `Sources/AlloyKit/Code/DocumentServices.swift:151`: call `entry.view?.ownMarks?.typed()` beside `gitMarks?.typed()`.
  - The view where `gitMarks` is attached (`OpenDocumentView`).
  - The save path that fires `onSaved`, so the view clears.
  - `Sources/AlloyCore/Editor/DiffDecorationModel.swift`: drop `.user`-authored line bars, removed groups and author runs.
- Test: `Tests/AlloyKitTests/OwnEditMarksTests.swift`

**Interfaces:**
- Consumes: `OwnEdits.changedLines`, `AlloySettings.ownEditTint`.
- Produces:
  - `static let owner = CodeDecorationOwner("own", priority: 1)`, so an unsaved edit shows over an agent bar on the
    same line.
  - `Color.ownEditTint(_ settings: AlloySettings) -> Color`: the parsed `colorHex` (via `ThemeRGBA(hex:)`), else
    `.userAuthor`. Task 3 uses it too.
  - `OwnEditMarks`, with `typed()`, `recompute()`, `clear()` and the test counters `recomputeCount` and
    `lastDiffOffMain`.
- Line decorations: `gutterBar` set to the own colour and `background: .addedRowTint`, applied as of the snapshot's
  version so MetalUI maps them through later edits.
- When `typed()` is called with the setting off it returns at once and starts no task.
- `recompute` runs on presentation change, setting change and outside merge. `clear` runs on save and on toggle off.

- [ ] **Step 1: Write the failing tests**, using the existing TestWindow and Rig patterns and the manual clock.
  - `offByDefaultTypingSpawnsNothing`: typing leaves `recomputeCount == 0` and adds no `own` decorations.
  - `onTypingTintsTheEditedLineAfterThePause`: no tint before 0.3 s of clock time, then the edited line has an `own`
    line decoration; `lastDiffOffMain == true`.
  - `saveClearsTheTint`
  - `undoToSavedClearsTheTint`
  - `toggleOffClearsOpenViews`
  - `overSizeLimitNoTintNoWork`
  - `savedUserEditsAreNotTintedEitherWay`: after a save, the ledger `.user` edit produces no line bar, both off and on.
  - `agentEditTintUnchanged`: an agent edit still gets its session bar.
  - `idleTicksRerunNothingWithTintOn`: BodyProbe counts and spawns are unchanged over 20 idle ticks with tinted lines
    showing.
- [ ] **Step 2:** Run `swift test --no-parallel --filter OwnEditMarksTests`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run `swift test --no-parallel --filter 'OwnEditMarksTests|CodeModePerformanceTests|DiffDecoration|SideBySide'`.
  Expect PASS. CodeModePerformanceTests' typing-frame bounds must hold unchanged.
- [ ] **Step 5:** Commit: `feat(own-tint): tint unsaved edits in the code editor; saved user edits no longer marked`.

### Task 3: CSV Table view

**Files:**
- Modify:
  - `Sources/AlloyCore/CSV/CSVTableModel.swift` (the tint at about :458, and the ownership build at about :532).
  - `Sources/AlloyKit/Code/Table/TableCells.swift:28-40`.
- Test: `Tests/AlloyKitTests/CSVOwnTintTests.swift`, or the existing CSV table test file.

**Interfaces:**
- Consumes: `OwnEdits.changedBytes`, `Color.ownEditTint`.
- Produces:
  - `CSVTint.own`. The fill is `Color.ownEditTint(settings).opacity(0.3)` and the token is `"tint-own"`.
  - `CSVTableModel.ownTintEnabled: Bool`, set by the view from settings.
  - The spans are computed off main once per buffer version while the setting is enabled, reusing the existing
    `(ledger, buffer)` keyed build.
- Precedence: `tint(forFileRow:column:)` returns `.own` when the setting is on and the cell's field range intersects an
  own span; otherwise it returns the ledger tint as today (`.user` stays nil). The changed-row lists (`tinted()` and
  `isTinted()`) are unchanged: own edits are not agent changes to review.

- [ ] **Step 1: Write the failing tests.**
  - `ownCellTintedOnlyWhenOn`: editing a cell gives token `tint-own` when on and no token when off.
  - `saveClearsOwnCellTint`
  - `agentCellTintUnchanged`
  - `toggleOffClearsTableTint`
  - `changedRowListExcludesOwnEdits`
- [ ] **Step 2:** Run `swift test --no-parallel --filter CSVOwnTintTests`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run `swift test --no-parallel --filter 'CSVOwnTintTests|CSVTable'`. Expect PASS.
- [ ] **Step 5:** Commit: `feat(own-tint): tint unsaved cell edits in Table view`.

### Task 4: Settings UI

**Files:**
- Modify: `Sources/AlloyKit/SettingsView.swift:60-66` (the Editor section).
- Test: an existing Settings UI test file, for example SettingsViewTests.

**Interfaces:**
- Consumes: `AlloySettings.ownEditTint` and `Color.ownEditTint`, plus the MetalUI
  `ColorPicker(_ title:, selection: Binding<Color>, supportsOpacity: false)`.
- The ids are:
  - `settings-own-tint` for the toggle.
  - `settings-own-tint-color` for the picker, shown only when the toggle is on.
  - `settings-own-tint-reset` for "Reset to theme colour", shown only when `colorHex != nil`.
- Setting a colour writes the hex. Convert with the existing Color↔ThemeRGBA path in the theme applier; don't add a
  second converter.

- [ ] **Step 1: Write the failing tests.**
  - `ownTintToggleDefaultsOffAndHidesPicker`
  - `pickingAColourStoresHexAndTintsWithIt`
  - `resetReturnsToThemeColour`
  - `themeSwitchFollowsThemeOnlyWithoutPickedColour`
- [ ] **Step 2:** Run `swift test --no-parallel --filter <SettingsSuite>`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the suite, then `swift test --no-parallel --filter AlloyCoreTests`, then the AlloyKit suites touched
  in Tasks 2 to 4, then `swiftlint --strict`. Expect all to pass.
- [ ] **Step 5:** Commit: `feat(own-tint): Settings toggle and colour picker`.
