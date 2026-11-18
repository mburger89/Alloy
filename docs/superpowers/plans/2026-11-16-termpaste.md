# Terminal Paste Confirm Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Confirm a multi-line paste into a terminal program that has not enabled bracketed paste (terminal spec section 8), with a persisted "Don't ask again".

**Architecture:** `TerminalView` (MetalUI #381) calls an `onPaste` hook with the raw clipboard text and the pending `TerminalModes`. The pane view forwards it to `TerminalPanelStore.pasteHook`, which returns false (default MetalUI paste) or stores a `PendingPaste` and returns true. A `TerminalPasteConfirm` overlay is mounted in a `ZStack` in `TerminalPaneView` only while that pane's `pendingPaste` is non-nil. Paste sends `TerminalEncoder.encodePaste(text, modes:)` through `sendInput`.

**Tech Stack:** Swift, SwiftPM, MetalUI (read-only), MetalUITerminal, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-16-terminal-design.md` (section 8, section 11, "Approved decisions").

## Global Constraints

- Work only on branch `feat/termpaste`; never touch `../MetalUI`. Missing MetalUI API: stop and report it as a gap, no workaround.
- Tests run only as: `lockf -k <the swift test lock> swift test --no-parallel [--filter X]` (the swift test lock serialises parallel builds). Ignore when failing alone under load: `OverlapIndexTests.unsavedTypingCostIsBounded`, `ByteCopiesTests.readHoldsOneCopy`, `LSPManagerLinterTests.probeAnswersAreCachedUntilReload`.
- Frame guards must hold exactly, never raise a constant: chat 46, code 46/62/72, knownPopoverGap 0, steadyCompare 77, `ViewRerunTests.steadyFrameRequests` 88, `CodeModePerformanceTests.steadyCode1/2/3` 91/107/117, `TerminalGuardTests` (knownVisibleTerminalGap 0, knownTerminalViewExcess 0, visiblePanelBaseline 55), idle frames 0 element requests. A closed confirm costs nothing per frame.
- Confirm copy: `Paste N lines? They may run as commands`; buttons `Paste`, `Cancel`, choice `Don't ask again`. Ids: `terminal-paste-confirm`, `terminal-paste-confirm-paste`, `terminal-paste-confirm-cancel`.
- Setting: reuse the existing `TerminalSettings.confirmMultilinePaste` (default true, already decoded and shown in `TerminalSettingsSection` as `settings-terminal-paste-confirm`). "Don't ask again" sets it false.
- Keep changes in terminal and terminal-settings files (parallel branches: gitlane, rename, snippets). Committed files contain no local paths or personal data.
- Commit messages end with the two trailer lines the orchestrator specified (Co-Authored-By for Claude Opus 5.5, then the Claude-Session line).
- No subagents, no GUI launches, no broad pkill, no bare `git stash`.

## Review Focus

- Text "ls\n" (one trailing break) and "a\r\nb" (CRLF as one break): one line is not confirmed; two lines are. Pinned in Task 1.
- Bracketed paste on (modes from the hook, current before any frame): returns false, never prompts. Task 1.
- A second paste while a confirm is open: replaces nothing, returns true without sending (first stays pending). Task 1.
- The pane exits, restarts or closes with a confirm open: pending paste is dropped, no bytes go to a dead pty. Task 2.
- Esc and both buttons return focus to the terminal (`terminalFocusToken`); Cancel sends nothing. Task 2.

## File Structure

- Create `Sources/AlloyKit/Terminal/TerminalPasteGuard.swift`: pure `lineCount`/`needsConfirm`.
- Create `Sources/AlloyKit/Terminal/TerminalPasteConfirm.swift`: the overlay component.
- Modify `Sources/AlloyKit/Terminal/TerminalPanelStore.swift`: `PendingPaste`, state and methods.
- Modify `Sources/AlloyKit/Terminal/TerminalPaneView.swift`: `onPaste:` hook, ZStack overlay.
- Tests: `Tests/AlloyKitTests/TerminalPasteTests.swift` (new), `Tests/AlloyKitTests/TerminalGuardTests.swift` (guards).

MetalUI `TerminalView` has no `accessibilityLabel:` parameter at this base, so the optional tab-title label is skipped (no workaround).

### Task 1: Paste guard and store logic

**Files:**
- Create: `Sources/AlloyKit/Terminal/TerminalPasteGuard.swift`
- Modify: `Sources/AlloyKit/Terminal/TerminalPanelStore.swift`
- Test: `Tests/AlloyKitTests/TerminalPasteTests.swift`

**Interfaces:**
- Produces: `enum TerminalPasteGuard { static func lineCount(_ text: String) -> Int; static func needsConfirm(_ text: String, modes: TerminalModes, enabled: Bool) -> Bool }`; `struct PendingPaste: Equatable { let pane: UUID; let text: String; let lines: Int; let modes: TerminalModes }` (needs `TerminalModes: Equatable`; if not, compare by pane and text only); on `TerminalPanelStore`: `private(set) var pendingPaste: PendingPaste?`, `func pasteFromClipboard(_ pane: UUID, _ text: String, modes: TerminalModes) -> Bool` (true = handled, nothing sent now), `func confirmPaste(dontAskAgain: Bool)`, `func cancelPaste()`.

- [ ] **Step 1: Write failing tests** in `TerminalPasteTests` (reuse the `Rig`, `ScriptedPtySpawner` setup of `TerminalPaneTests`): `lineCountTreatsCRLFCRAndLFAsOneBreakEach` (`"a"`->1, `"ls\n"`->1, `"a\nb"`->2, `"a\r\nb"`->2, `"a\rb\rc"`->3, `"a\n\n"`->2, `""`->0); `singleLineAndBracketedAndDisabledReturnFalse` (store call returns false, `pendingPaste == nil`); `multiLineWithoutBracketedPromptsAndSendsNothing` (returns true, pendingPaste.lines == 3, `spawner.spawned[0]` received no paste bytes); `confirmSendsEncodedPaste` (bytes written equal `TerminalEncoder.encodePaste(text, modes:)`, pending cleared); `cancelSendsNothing`; `dontAskAgainClearsSettingAndPersists` (`workspace.settings.terminal.confirmMultilinePaste == false`, next multi-line call returns false); `secondPasteWhilePendingKeepsFirst`; `exitOrClosePaneDropsPending`.
- [ ] **Step 2: Run** `--filter TerminalPasteTests`; expect compile failure/FAIL.
- [ ] **Step 3: Implement** the guard (count breaks scanning `\r\n` as one, drop one trailing break; empty -> 0; `needsConfirm` = enabled, `!modes.bracketedPaste` (use the actual `TerminalModes` field name), lineCount > 1) and the store members. Confirm sends via `sendInput`, requires `paneState == .running` and the pane still live; "Don't ask again" persists through `workspace.updateSettings` with a copy of settings (`terminal.confirmMultilinePaste = false`, as `TerminalSettingsSection.update` does) and ignores a save error after still sending. `confirmPaste`/`cancelPaste` bump `terminalFocusToken`. `markExited`, `prune` and `restart` clear `pendingPaste` for their pane.
- [ ] **Step 4: Run** `--filter TerminalPasteTests`; expect PASS.
- [ ] **Step 5: Commit** `feat(terminal): paste guard and pending paste state`.

### Task 2: Confirm overlay, pane wiring and frame guards

**Files:**
- Create: `Sources/AlloyKit/Terminal/TerminalPasteConfirm.swift`
- Modify: `Sources/AlloyKit/Terminal/TerminalPaneView.swift`
- Test: `Tests/AlloyKitTests/TerminalPasteTests.swift`, `Tests/AlloyKitTests/TerminalGuardTests.swift`

**Interfaces:**
- Consumes: Task 1's `pendingPaste`, `pasteFromClipboard`, `confirmPaste(dontAskAgain:)`, `cancelPaste`.
- Produces: `struct TerminalPasteConfirm: Component, Equatable { let paneID: UUID; var store: TerminalPanelStore }` (id `terminal-paste-confirm`, buttons `terminal-paste-confirm-paste` / `-cancel`, a `Don't ask again` Toggle id `terminal-paste-confirm-dont-ask`; Esc via `onKeyPress` cancels, as `TerminalFindBar` does; Paste button takes initial focus through `@FocusState`, with `BodyProbe.hit("TerminalPasteConfirm")`).

- [ ] **Step 1: Write failing tests.** In `TerminalPasteTests`: `confirmAppearsOnlyInTheTargetPane` (call `store.pasteFromClipboard(pane, "a\nb\nc", modes:)`, tick, `terminal-paste-confirm` exists, text contains `Paste 3 lines? They may run as commands`; a split second pane shows none); `pasteButtonSendsAndDismisses`; `cancelButtonSendsNothingAndDismisses`; `dontAskAgainThenPasteSetsSetting`; `escapeCancels` (`window.typeKey(.escape)`); `focusReturnsToTerminalAfterEitherChoice` (`terminalFocusToken` increments). In `TerminalGuardTests`: `pasteConfirmClosedCostsNothing` (idle requests all 0, `BodyProbe.count("TerminalPasteConfirm")` unchanged, no element), `pasteConfirmOpenIdleCostsNothing` (open confirm, `idleRequests` all 0), and an assertion in an open-then-closed round trip that frame counts return to `visiblePanelBaseline` (55) with no constant changed.
- [ ] **Step 2: Run** `--filter TerminalPasteTests` and `--filter TerminalGuardTests`; expect FAIL.
- [ ] **Step 3: Implement.** In `terminal(_:)` pass `onPaste: { text, modes in store?.pasteFromClipboard(paneID, text, modes: modes) ?? false }` as the last `TerminalView` argument. In `content`, wrap the pane body in `ZStack { VStack {...existing...}; if let p = store?.pendingPaste, p.pane == paneID { TerminalPasteConfirm(...) } }` (an `.overlay { if let }` does not compile: OptionalGroup is not a ProposalElementGroup). Read `pendingPaste` only inside the pane view body so no other view reruns. Card style follows `TerminalFindBar` (panelFill, inset padding).
- [ ] **Step 4: Run** `--filter TerminalPasteTests`, `--filter TerminalGuardTests`, `--filter TerminalPaneTests`; expect PASS with unchanged constants.
- [ ] **Step 5: Commit** `feat(terminal): multi-line paste confirm overlay`.

### Task 3: Settings coverage and full guard sweep

**Files:**
- Modify: `Sources/AlloyKit/Terminal/TerminalSettingsSection.swift` (only if the toggle label needs to say it also covers "Don't ask again"; keep id `settings-terminal-paste-confirm`)
- Test: `Tests/AlloyKitTests/TerminalPasteTests.swift`

- [ ] **Step 1: Write failing test** `settingsToggleReflectsDontAskAgain`: after `confirmPaste(dontAskAgain: true)`, the settings window (open as the existing settings tests do) shows `settings-terminal-paste-confirm` off; turning it on again makes multi-line paste prompt again.
- [ ] **Step 2: Run** `--filter TerminalPasteTests`; expect FAIL or PASS-by-design (if already passing, keep the test as coverage).
- [ ] **Step 3: Adjust** the section only if required. Do not add a new setting key (decoding in `TerminalSettings` is unchanged).
- [ ] **Step 4: Run** the full suite once: `swift test --no-parallel` under the lock; expect green except the three known flaky tests, with the guard constants listed in Global Constraints untouched.
- [ ] **Step 5: Commit** `test(terminal): paste confirm settings coverage`.
