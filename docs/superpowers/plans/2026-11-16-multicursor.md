# Multi-cursor commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Add Next Occurrence, Select All Occurrences, Skip to Next Occurrence and Add Caret Above/Below to the shared command registry, wired to the focused view's `CodeSelectionState`, and make every Alloy path that assumed one selection behave sensibly with several carets.

**Architecture:** MetalUI owns the mechanics (G1 drawing, G2 helpers `addNextOccurrence`, `selectAllOccurrences(limit:)`, `skipToNextOccurrence`, `addCaret(lineDelta:)`, `collapseToPrimary`, G3 motion/editing/undo, Escape). Alloy adds a thin `Workspace` extension in AlloyCore that resolves the focused pane's state and runs a helper (plus the 10,000-cap notice), registers five built-in commands in `BuiltinCommands` (Edit menu), and audits the single-selection assumptions in the scheduler, `CodePanel`, find and save paths. No Alloy-drawn carets, no reimplemented selection logic.

**Tech Stack:** Swift, SwiftPM, Swift Testing, MetalUI (`MetalUICodeBuffer`, `MetalUITesting`).

**Spec:** `docs/superpowers/specs/2026-11-16-editor-essentials-design.md` (task 4 of its breakdown; read "Multiple cursors", "Performance plan", "Failure modes" and "Approved decisions"). Registry contract: `docs/command-registry.md`.

**Out of scope:** option-click and option-drag (MetalUI G4, built into `CodeView`), folding, shortcut settings UI and the "Reassign from X?" prompt (G7), Escape collapse (MetalUI claims Escape only with more than one selection).

## Global Constraints

- Run tests only as: `lockf -k <the swift test lock> swift test --no-parallel [--filter X]` from the worktree root. Plain `swift build` needs no lock. Known flaky alone under load: `OverlapIndexTests.unsavedTypingCostIsBounded`, `ByteCopiesTests.readHoldsOneCopy`, `LSPManagerLinterTests.probeAnswersAreCachedUntilReload`.
- Frame guards must hold exactly (MetalUI master values): chat `ViewRerunTests.steadyFrameRequests` 46; `CodeModePerformanceTests.steadyCode1/2/3` 46/62/72; `knownPopoverGap` 0 in the Hover, Intel and Completion guard tests; idle frames cost 0 element requests. A hidden or closed feature costs nothing per frame.
- Use MetalUI's helpers as-is. If an API is missing, stop and report a MetalUI gap; no workaround, no substitute.
- Cap: 10,000 selections (`CodeSelectionState.selectionLimit`). Past it, a `Notice(path:, kind: .warning, text: "Stopped at 10,000 cursors")` goes into `Workspace.notices`, shown in that editor group's notice slot and removed on the next selection change in that pane.
- Default chords: Add Next Occurrence cmd+d, Select All Occurrences cmd+shift+l, Skip to Next Occurrence alt+cmd+d, Add Caret Above ctrl+shift+up, Add Caret Below ctrl+shift+down. All rebindable later; the keymap is global.
- Clash rule: built-ins register first and win; a built-in whose default chord is held is rejected into `registry.rejections`. None of the five may be rejected.
- Accessibility ids: menu items `cmd-<id>` (spec: new items use `cmd-<id>`); existing ids unchanged.
- Commands act on the focused view's state and are disabled when no code view is focused. `isEnabled` and `run` are actions: never called from a view body.
- Multi-caret typing coalesces into undo steps like single-caret typing (approved); do not change that.
- Committed files contain no local paths or personal data (no home-directory paths, user names, scratch paths, session URLs, bundle prefixes or mail addresses). Commit messages end with the two trailer lines the workflow supplies (Co-Authored-By and Claude-Session), exactly.

## Review Focus

Inputs the spec implies but its listed tests do not exercise; each is pinned by a test in the owning task.

1. Command with no word under the caret (blank line, punctuation, empty file): silent no-op, no crash, no notice (Task 1).
2. Nothing focused (project chooser, no tab, an image or non-code tab): every item disabled and `registry.run` does nothing (Task 2).
3. Cap hit twice in a row: one notice, not two; it clears on the next selection change in that pane and leaves no observer behind (Task 1).
4. Two panes on one file keep independent carets; splitting copies carets; closing the tab drops the state (Task 4).
5. Format on save, Format Document and LSP workspace edits with several carets: carets survive and move with the edits instead of collapsing; Format Selection is disabled rather than formatting only the primary (Tasks 3 and 4).

## File Structure

- Create `Sources/AlloyCore/Editor/MultiCursor.swift`: `MultiCursorCommand`, the `Workspace` extension (resolve state, enabled, run, cap notice and its one-shot clearing).
- Modify `Sources/AlloyCore/Commands/CommandDescriptor.swift`: `CommandCategory.selection`.
- Modify `Sources/AlloyKit/Commands/BuiltinCommands.swift`: five registrations.
- Modify `Sources/AlloyKit/Code/CodePanel.swift` (`intelHooks.isEnabled` for `.formatSelection`), `Sources/AlloyCore/Model/Workspace+Search.swift` (find seed).
- Create tests: `Tests/AlloyCoreTests/MultiCursorTests.swift`, `Tests/AlloyKitTests/MultiCursorCommandTests.swift`, `Tests/AlloyKitTests/MultiCaretIntelTests.swift`, `Tests/AlloyKitTests/MultiCaretPerformanceTests.swift`. Modify `Tests/AlloyKitTests/CodeModePerformanceTests.swift` (helper parameter) and `CommandParityTests.swift`.
- Docs: `docs/command-registry.md` (list the editor commands), `docs/parity.md` if it lists menus.

---

### Task 1: Workspace multi-cursor core (AlloyCore)

**Files:**
- Create: `Sources/AlloyCore/Editor/MultiCursor.swift`
- Test: `Tests/AlloyCoreTests/MultiCursorTests.swift` (use the existing AlloyCore test rig helpers; look at `Tests/AlloyCoreTests` for how a `Workspace` with an open document is built)

**Interfaces:**
- Consumes: `Workspace.defaultPane`, `activeTab(in:)`, `document(_:)`, `selectionState(for:in:)`, `Workspace.notify(path:kind:text:)` (internal, in `OutsideEdits.swift`), `Workspace.notices`, `CodeSelectionState` helpers (MetalUI G2).
- Produces:
  - `public enum MultiCursorCommand: Sendable { case addNextOccurrence, selectAllOccurrences, skipToNextOccurrence, addCaretAbove, addCaretBelow }`
  - `extension Workspace`: `public func canRunMultiCursor() -> Bool` (focused pane has an active tab whose document exists and shows as code: not an image or other non-text tab; read-only documents are allowed since carets and selection do not edit) and `@discardableResult public func runMultiCursor(_ command: MultiCursorCommand, limit: Int = CodeSelectionState.selectionLimit) -> Bool` (false when disabled).

- [ ] **Step 1: Write failing tests** in `MultiCursorTests`, each on a small document, asserting `state.selections` (ranges, primary last-added via `primaryIndex`):
  - `addNextOccurrenceOnCaretSelectsWord`: caret inside `alpha` in `alpha beta alpha` selects `0..<5`; second run adds `11..<16` as primary; third run (wraps, nothing new) leaves two selections.
  - `addNextOccurrenceWithMultilineSelectionMatchesExactText`: select `"a\nb"`, the next exact case-sensitive match is added (not whole-word).
  - `skipReplacesPrimaryWithNextMatch`: after two adds, skip leaves count 2 and moves the primary to the following match.
  - `selectAllOccurrencesSelectsEveryWholeWordMatch`.
  - `addCaretBelowKeepsGoalColumn` / `addCaretAboveOnFirstLineIsNoOp`.
  - Review Focus 1: `commandsOnBlankLineAreNoOps` (caret on an empty line, empty file: selections unchanged, `notices` empty, returns true).
  - `capStopsAtLimitWithNotice`: pass `limit: 3` on a file with 5 matches; selections.count == 3 and `notices.last == Notice(path: "a.txt", kind: .warning, text: "Stopped at 10,000 cursors")`. One more test with the real default limit on a 10,001-line `x\n` file, asserting count 10,000 (guards the constant).
  - `capNoticeIsNotDuplicatedAndClearsOnNextSelectionChange`: run the capped command twice, expect one notice; then `state.selections = [CodeSelection(caret: 0)]` and `await Task.yield()` loops until `notices` has no cap notice.
  - `disabledWithoutAnEditor`: no active tab: `canRunMultiCursor() == false`, `runMultiCursor` returns false and changes nothing.
- [ ] **Step 2: Run to verify failure**: `lockf -k <the swift test lock> swift test --no-parallel --filter MultiCursorTests` fails to compile (symbols missing).
- [ ] **Step 3: Implement** `MultiCursor.swift`. Resolve the state with `selectionState(for: activeTab(in: defaultPane), in: defaultPane)`. Map commands to `addNextOccurrence(limit:)`, `selectAllOccurrences(limit:)`, `skipToNextOccurrence()`, `addCaret(lineDelta: -1/+1, limit:)`. A `false` result posts the cap notice via `notify` after first removing any existing cap notice for that path. The one-shot clearing: store `@ObservationIgnored` per-pane tracking in a small dictionary on `Workspace` (add the stored property next to `paneSelections`), arm `withObservationTracking { _ = state.selections } onChange: { Task { @MainActor in remove the notice and the entry } }` after posting (so the posting change itself is not observed). Nothing is armed unless the cap was hit, so idle cost is 0.
- [ ] **Step 4: Run** the same filter; expect PASS. Also `swift build`.
- [ ] **Step 5: Commit** `feat(multicursor): workspace multi-cursor core with cap notice`.

### Task 2: Register the commands, Edit menu, chords, ids, and UI frame guards

**Files:**
- Modify: `Sources/AlloyCore/Commands/CommandDescriptor.swift` (add `public static let selection = CommandCategory(name: "Selection")`), `Sources/AlloyKit/Commands/BuiltinCommands.swift` (after the `addIntel` block, before `file.save`), `docs/command-registry.md`.
- Modify: `Tests/AlloyKitTests/CommandParityTests.swift` (the Edit-menu assertion currently pins `suffix(6)`; pin the full new tail: the six intel items then the five new titles, plus ids and shortcuts), `Tests/AlloyKitTests/CodeModePerformanceTests.swift`.
- Create: `Tests/AlloyKitTests/MultiCursorCommandTests.swift`, `Tests/AlloyKitTests/MultiCaretPerformanceTests.swift`.

**Interfaces:**
- Consumes: Task 1's `canRunMultiCursor()` and `runMultiCursor(_:)`; the file-local `add(...)` helper in `BuiltinCommands.register`.
- Produces: command ids `editor.addNextOccurrence` ("Add Next Occurrence", cmd+d), `editor.selectAllOccurrences` ("Select All Occurrences", cmd+shift+l), `editor.skipNextOccurrence` ("Skip to Next Occurrence", alt+cmd+d), `editor.addCaretAbove` ("Add Caret Above", ctrl+shift+up), `editor.addCaretBelow` ("Add Caret Below", ctrl+shift+down); category `.selection`, `.menu` binding, `menu: .edit`, `recents: false`, `menuID: "cmd-<id>"`, `enabled: { current()?.canRunMultiCursor() ?? false }`, run `current()?.runMultiCursor(...)`.

- [ ] **Step 1: Write failing tests** in `MultiCursorCommandTests` (rig + `alloyWindow`, a document open in the chat pane and, separately, a Code-mode group, as `IntelCommandsTests` does):
  - `registersAllFiveWithoutRejection`: all five ids present in `registry.commands`; `registry.rejections` has none for these ids; every default chord is unique across `registry.commands` (clash rule against ⌘, ⌘P, ⌥⌘L, ⌃⌘arrows etc.).
  - `editMenuListsThemAfterTheIntelItems`: titles, order, `accessibilityIdentifier == "cmd-<id>"`, shortcuts as `PlatformKeyEquivalent` (`d` command; `l` command+shift; `d` option+command; up/down control+shift).
  - `menuItemsRunAgainstTheFocusedView`: `performMenuBarItem(accessibilityIdentifier:)` for each, asserting the focused pane's `selections` (as in Task 1).
  - `chordsReachTheCommandsFromTheFocusedCodeView`: click the code view, `window.typeKey("d", modifierFlags: .command)` adds the word; `typeKey("l", .command + .shift)`; `typeKey("d", .option + .command)`; `typeKey(.down, .control + .shift)`. This pins that `CodeEditing` declines these keys.
  - `disabledWithNothingFocused` (Review Focus 2): chooser model (see `menuItemsMatchRegistryInTheChooser`), workspace with no tab, and an image tab: items `isEnabled == false`, `registry.run(id:) == false`.
  - `actsOnTheFocusedGroupOnly`: Code mode with two groups on one file; ⌘D in group A leaves group B at one caret.
  - `escapeWithOneSelectionStillClosesSettingsAndQuickOpen` (spec test): carets present then collapsed; Escape handling unchanged.
  - Capped run through the menu shows the notice slot in the editor group (`FilePanelNotice` element present) and a following click removes it.
- [ ] **Step 2: Extend the frame-guard helper.** Add `carets: Int = 1` to `CodeModePerformanceTests.guardTyping` and `typing(...)`: after the existing click on the code view and before warm-up, run the Task 1 command path (`runMultiCursor(.addCaretBelow)` repeatedly, or set `state.selections` to line starts when more lines are needed) until the focused pane's state has `carets` selections. In `MultiCaretPerformanceTests` (new suite reusing the helper) add: `typingWith3CaretsHoldsGuardCode1/2/3` and `typingWith50CaretsHoldsGuardCode1/2/3` asserting the same `steadyCode1/2/3` (46/62/72) per-frame and total bounds and zero re-runs of the watched names; `typingInChatWith3And50CaretsHoldsChatGuard` (46); `idleWithSeveralCaretsCostsNothingExtra`: focused idle, blink on, 1, 3 and 50 carets give equal `elementRequests` over 20 ticks and no re-runs; `idleWithSeveralCaretsBlinkOffCostsZero`: blink off (the code view's blink setting if Alloy exposes it, otherwise unfocused) asserts 0 requests; `menuItemsAddNoFrameCost`: the existing idle and steady guards stay unchanged (no new constants).
- [ ] **Step 3: Run to verify failure**: `--filter MultiCursorCommandTests` and `--filter MultiCaretPerformanceTests` (fail: commands missing).
- [ ] **Step 4: Implement** the category and five `add(...)` registrations in `BuiltinCommands.swift`, using the file's `chord(_:_:)`/`ch(_:)` helpers (`.named(.up)`, `.named(.down)`). Update `docs/command-registry.md` with a short "Editor commands" note (ids, that they act on the focused view and are disabled otherwise).
- [ ] **Step 5: Update `CommandParityTests`** (full Edit tail, `menuItemsMatchRegistry` keeps passing because `menuID` is explicit). Run `--filter CommandParityTests`, `--filter MultiCursorCommandTests`, `--filter MultiCaretPerformanceTests`, `--filter CodeModePerformanceTests`, `--filter ViewRerunTests`: all PASS with unchanged constants.
- [ ] **Step 6: Commit** `feat(multicursor): add-next, all, skip and caret above/below commands`.

### Task 3: Intelligence paths with several carets

Spec rule: completion, signature help and code actions open only with a single selection; hover-at-caret uses the primary caret.

**Files:**
- Modify: `Sources/AlloyKit/Code/CodePanel.swift` (`intelHooks.isEnabled`, `.formatSelection` case, near line 856), `Sources/AlloyKit/Code/FormatService.swift` (`runExplicit` selection-only branch).
- Test: `Tests/AlloyKitTests/MultiCaretIntelTests.swift` (uses `IntelRig`, `IntelSupport.swift`).

**Interfaces:**
- Consumes: `OpenDocumentView.selection(in:)`, `IntelligenceScheduler` single-selection guards (`edited`, `request`, `answered`, `invokeSignature`, `requestSignature`, `scheduleProbe`, `showActions`, `type`, `applyAccept`), `intelHooks.isEnabled(_:)`.
- Produces: `.formatSelection` enabled only with exactly one non-empty selection; no other behaviour change.

- [ ] **Step 1: Write failing/pinning tests** (several pass already; that is the point, they pin the audit):
  - `typingWithThreeCaretsRequestsNoCompletionOrProbe`: fake server with completion and codeAction caps; add three carets, type an identifier character; assert no `textDocument/completion` and no `textDocument/codeAction` in `r.methods()`, no popup, no lightbulb.
  - `triggerCompletionSignatureAndQuickFixDisabledWithSeveralCarets` (menu items `menu-trigger-completion`, `menu-signature-help`, `menu-quick-fix` disabled; enabled again after `collapseToPrimary()`).
  - `openCompletionClosesWhenASecondCaretIsAdded`.
  - `showHoverUsesThePrimaryCaret`: with two carets, `menu-show-hover` requests hover at the primary's offset (`textDocument/hover` params).
  - `goToDefinitionAndReferencesUsePrimaryCaret`.
  - `formatSelectionDisabledWithSeveralSelections` (fails today when the primary alone is non-empty): `menu-format-selection` disabled with two non-empty selections, enabled with one.
  - `formatDocumentWithSeveralCaretsKeepsThem` (Review Focus 5): run `menu-format`; carets map through the edits; count unchanged; one undo restores text and carets.
  - Guard tests: extend `HoverGuardTests`, `IntelGuardTests`, `CompletionGuardTests` setups with a variant that has 3 carets; `knownPopoverGap` stays 0 and counts are unchanged.
- [ ] **Step 2: Run**: `--filter MultiCaretIntelTests`; expected: only the format-selection test fails.
- [ ] **Step 3: Implement** the `.formatSelection` predicate (`selections.count == 1 && !selections[0].isEmpty`) and make `runExplicit` bail when there is not exactly one selection.
- [ ] **Step 4: Run** `--filter MultiCaretIntelTests`, `IntelCommandsTests`, `HoverGuardTests`, `IntelGuardTests`, `CompletionGuardTests`, `CodeActionGuardTests`, `FormatTests`: PASS.
- [ ] **Step 5: Commit** `feat(multicursor): intelligence paths and format selection with several carets`.

### Task 4: Workspace paths: find, save, split, edits

**Files:**
- Modify: `Sources/AlloyCore/Model/Workspace+Search.swift` (`selectedSingleLine`, line 16-23).
- Test: add to `Tests/AlloyKitTests/MultiCaretIntelTests.swift` (save, applier, split) and `Tests/AlloyCoreTests/MultiCursorTests.swift` (find seed, pane state).

**Interfaces:**
- Consumes: `Workspace.showSearch(replace:)`, `search.seed(_:)`, `requestSaveActive`, `WorkspaceEditApplier`, `Workspace+Groups` split (copies selections), `FormatService.formatForSave`, `OpenDocumentView.step`/`stepProblem` (use `primarySelection`).
- Produces: find seeds from the primary selection when it is a non-empty single-line range (our call, spec silent: the primary is what every other Alloy path already uses), regardless of how many selections exist.

- [ ] **Step 1: Write tests**:
  - `findSeedsFromThePrimarySelectionWithSeveralCarets` (fails today: `count == 1` guard); also a multi-line primary seeds nothing.
  - `findNextCollapsesToTheMatchAsBefore` (`search.step` / `OpenDocumentView.step` selects one range).
  - `saveWithFormatOnSaveKeepsAllCarets` (Review Focus 5): three carets, format-on-save server edits a line; carets present afterwards and moved by the edit; file saved once.
  - `lspWorkspaceEditKeepsCarets` through `WorkspaceEditApplier` (rename-style edit on an open file).
  - `splitCopiesCaretsAndPanesStayIndependent`: split right with three carets, add a caret in the new group, the source group still has three (Review Focus 4).
  - `closingTheTabDropsTheState`: `selectionState(for:in:)` is nil after close; reopening starts at one caret.
  - `gitBlameLineUsesThePrimaryCaret`.
- [ ] **Step 2: Run to verify** only the find-seed test fails.
- [ ] **Step 3: Implement** `selectedSingleLine` with `state.primarySelection`.
- [ ] **Step 4: Run** `--filter MultiCursorTests`, `MultiCaretIntelTests`, `SearchTabTests`, `SearchPolishTests`, `SaveKeyTests`, `WorkspaceEditApplierTests`, `EditorGroupViewTests`: PASS.
- [ ] **Step 5: Commit** `feat(multicursor): find seed, save, split and edits with several carets`.

### Task 5: Cap-scale budget, hidden-feature guard, docs

**Files:**
- Test: `Tests/AlloyKitTests/MultiCaretPerformanceTests.swift`.
- Modify: `docs/command-registry.md` (if not finished in Task 2), `docs/parity.md` only if it lists menu items.

**Interfaces:**
- Consumes: Tasks 1-4; `window.typeText`, `window.frameWork`.
- Produces: the spec's cap-scale guard and a final audit.

- [ ] **Step 1: Write tests**:
  - `keystrokeWith10000CaretsOn10000LinesIsUnder16ms`: a 10,000-line document, `selectAllOccurrences` on a token that occurs once per line (10,000 carets; assert count and no notice), then median of 7 `typeText` + `tick` wall times `<= 16 ms`. If it proves load-sensitive under the swift test lock, report the measured median rather than loosening silently.
  - `undoSnapshotStaysSmall`: after one typed character at the cap, one undo restores all 10,000 selections (pins MetalUI G3 from Alloy's side).
  - `capNoticeAt10000ThroughTheCommand`: 10,001 matches, `editor.selectAllOccurrences` leaves 10,000 and posts the notice.
  - `noCommandsRunWhenHidden`: Chat-mode guard unchanged with Code mode never shown; the registry closures are never invoked by a frame (count invocations through a test-registered probe command with the same enabled closure shape).
  - Whole-suite checks: `ViewRerunTests`, `CodeModePerformanceTests`, `HoverGuardTests`, `IntelGuardTests`, `CompletionGuardTests`, `MemoryProbeTests`, `CommandPalette*Tests`.
- [ ] **Step 2: Run** each filter; expect PASS. Run the full `swift test --no-parallel` once through the lock; only the three known-flaky tests may fail, and only when they also fail alone.
- [ ] **Step 3: Run the privacy scan** over the diff: grep the diff against master for the forbidden local-path and personal-data patterns listed in the workflow rules; it must print nothing.
- [ ] **Step 4: Commit** `test(multicursor): cap-scale budget and final guards`.

## Self-review

- Spec coverage: five commands, chords, Edit placement, ids, enabled predicates, cap notice and its clearing (Tasks 1-2); single-selection assumptions in completion, signature, code actions, hover, find, format, save, split (Tasks 3-4); perf guards typing 1/3/50, idle, blink, cap budget (Tasks 2 and 5). Escape and drawing stay MetalUI's; ⌥-click/drag, folding, shortcut settings excluded.
- Types: `MultiCursorCommand`, `canRunMultiCursor()`, `runMultiCursor(_:limit:)` are named identically in Tasks 1, 2 and 5; ids match the registrations and tests.
- Decisions left to the implementer, within the stated rules: the exact fixture text; how the 50 carets are placed; where the blink-off setting is read.
