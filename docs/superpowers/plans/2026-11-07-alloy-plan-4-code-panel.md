# Alloy Plan 4: Code panel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Plan 1's read-only stopgap panel with the spec §6.4 code view, built on MetalUI's `CodeView`:
- syntax highlighting
- the author-colored gutter with character-level attribution
- inline and side-by-side diffs
- Keep and Revert in the panel
- tabs and ⌘P quick-open
- find
- the user's own edits as author "You", with about 1 s autosave and the dirty-buffer rule
- an outside-edit watcher, and a baseline reset after a git commit

The panel also gives the benchmark Alloy's first typing and scrolling numbers.

**Architecture:**
- **`AlloyCore`** gets the `EditorDocument` model: one `CodeBuffer` per open file, linked to its `FileLedger`. It also gets save and autosave, the dirty-buffer merge, the file watcher with attribution, and git baseline reset. All of it is testable without a window.
- **New `AlloyHighlight` target:** wraps tree-sitter and implements MetalUI's two seams, `CodeHighlightProvider` for `CodeView` and `MarkdownCodeHighlighter` for chat code fences. MetalUI stays free of C grammars, as agreed with the MetalUI session.
- **`AlloyKit`:** turns ledger `DiffLine`s into `CodeDecorations`: line decorations, annotation runs, and virtual rows for removed lines. It also hosts the tab bar, find bar, quick-open and side-by-side views.

**Tech Stack:** Swift 6.1 (Swift 6 language mode), macOS 14, MetalUI (`CodeView`, `MetalUICodeBuffer`), SwiftTreeSitter and tree-sitter grammar packages, FSEvents (CoreServices), `git` CLI, Swift Testing, `MetalUITesting`.

**Spec:** `docs/superpowers/specs/2026-11-07-alloy-design.md` (§6.1 right panel, §6.4, §6.7). The MetalUI API reference for this plan is `.superpowers/sdd/plan-3-4-research/metalui-apis.md`; copy it to `docs/metalui-code-api.md` in Task 1.

**Depends on:** Plan 3. It needs Task 12's `FileIndex` and `FuzzyMatch`, Task 9's `MarkdownText` (for the fence highlighter), and Task 6's `BlockStyle` and theme tokens.

## Global Constraints

- All of Plan 3's Global Constraints apply: MetalUI only, the gaps rule, no `~/.claude` writes, accessibility identifiers, theme tokens, real fixtures, and the commit trailer.
- **Never parse, diff or read files on the main actor** for files over 64 KB. `CodeBuffer` and `CodeDecorations` are main-actor; build them on main from bytes read off main.
- `CodeView` offsets are **UTF-8 bytes**. Ledger `DiffLine`/`AttributedRun` text is `String`. Convert by summing `utf8.count`, never by `Character` count.
- **The user's text is never lost.** A buffer with unsaved typing is saved, or merged and then saved, before Alloy replaces the buffer contents for any reason.
- Keep the bench contract:
  - the identifiers `file-panel`, `file-panel-path` and `file-panel-message`
  - `alloyFilePanelIdealWidth` (360) and the Bench constant `alloyFilePanelCentreFromRight` (180), which are changed together
- `CodeView` is editable by default. It is read-only only for files over `Workspace.previewLimit`, non-UTF-8 files (`hadInvalidUTF8`), and the left (old) pane of side-by-side.
- The release build has zero warnings. `swift test` passes. Agents kill only their own processes.

## Review Focus

1. **The user is typing in a file when a session edits the same file.** The user's unsaved characters survive. Non-overlapping session hunks land in the buffer. An overlapping hunk keeps the user's text and shows a notice naming the session. Test in Task 3.
2. **Alloy's own writes come back through the file watcher** (autosave, revert, a session tool write). None may create an `.outside` record. Test in Task 4.
3. **A file in a CRLF repo, or a file with emoji and multi-byte text on a changed line.** Gutter bars, removed-row anchors and intra-line author runs land on the right characters. Test in Task 6.
4. **A 100 000-line file open while sessions edit it.** One keystroke shapes at most 2 lines and does not recompute decorations. A session edit recomputes them once. Test in Task 6.
5. **A commit that includes only some of a file's changes, or a `git checkout` that rewrites files.** A partial commit keeps nothing. A checkout records `.outside` edits, or matches the HEAD state and keeps. Nothing crashes on detached HEAD or with no git. Test in Task 5.

---

### Task 1: AlloyHighlight: tree-sitter engine and both highlight seams

**Files:**
- Modify: `Package.swift`. Add the `AlloyHighlight` target, which depends on `SwiftTreeSitter` and the grammar products and `MetalUI`. Add the `AlloyHighlightTests` target. AlloyKit depends on AlloyHighlight.
- Create: `Sources/AlloyHighlight/{Languages.swift,HighlightEngine.swift,CodeViewHighlighter.swift,FenceHighlighter.swift,SyntaxPalette.swift}`, and `Sources/AlloyHighlight/Queries/<lang>/highlights.scm` only for grammars whose package doesn't ship its queries as resources (with license headers).
- Create: `docs/metalui-code-api.md`
- Test: `Tests/AlloyHighlightTests/*`

**Interfaces:**
- Grammars:
  - **Required:** Swift, Python, JavaScript, TypeScript and TSX, JSON, Markdown.
  - **Best effort:** Bash, Rust, Go, C, C++, YAML, HTML, CSS.
  - Pin each package to an exact version or revision. Some grammar repos keep the generated `parser.c` only on a release tag or a `with-generated-files` branch. Pin that revision and note why in `Package.swift`.
  - A grammar that won't build is dropped and listed in the task report. It never blocks the task.
- Produces:
  - `public enum Language: String, CaseIterable { … }` with `static func detect(path: String) -> Language?` (by extension, plus a shebang check of the first line for scripts) and `static func named(_ fenceName: String) -> Language?` (aliases: `js`, `ts`, `py`, `sh`, `zsh`, `yml`, `md`, `c++`, `objc` → nil).
  - `public actor HighlightEngine`. It owns one `Parser` and `Tree` per document id.
    - `func open(id: UUID, language: Language, text: String) async`
    - `func edit(id: UUID, edits: [CodeEdit], newText: String) async`. Feed `InputEdit(startByte: e.range.lowerBound, oldEndByte: e.range.upperBound, newEndByte: e.range.lowerBound + e.newText.utf8.count, startPoint: e.startPoint, oldEndPoint: e.oldEndPoint, newEndPoint: e.newEndPoint)` in order, then reparse incrementally. `CodePoint` columns are UTF-8 bytes, as tree-sitter's are.
    - `func captures(id: UUID, byteRange: Range<Int>) async -> [(Range<Int>, SyntaxToken)]`
    - `func close(id: UUID)`
  - `public enum SyntaxToken { keyword, string, comment, number, type, function, variable, property, constant, builtin, operator_, punctuation, attribute, tag, heading, link, plain }`. Map tree-sitter capture names by first dotted component, for example `function.method` → `.function`.
  - `public struct SyntaxPalette { func style(_ t: SyntaxToken, scheme: ColorScheme) -> CodeStyle }`. Colors are light and dark pairs readable on `.panelFill`; spec §8 leaves the values to the builder.
  - `@MainActor public final class CodeViewHighlighter: CodeHighlightProvider`, initialised with `(engine:, documentID:, decorations:, palette:)`.
    - On `needHighlightsForRows`, it computes the rows' byte range from the snapshot.
    - It awaits `engine.captures`.
    - Then it calls `decorations.setHighlights(runs, in: range, layer: .syntax, asOf: snapshot.version)`.
    - At most one request is in flight per document. A newer request supersedes an older one.
    - The `CodeDecorations` holds it weakly, so the owner must retain it (Task 6).
  - `public final class FenceHighlighter: MarkdownCodeHighlighter`, with a synchronous `highlight(code:language:isClosed:)`. It parses the fence with a throwaway parser. Fences over 2 000 lines return `[]`. The palette is applied for the current scheme.
- Wire `FenceHighlighter` into Plan 3's `MarkdownText` with `.codeHighlighter(…)`.

- [ ] **Step 1: Write the failing tests.**
  - `detectsLanguages`: `.swift`, `.py`, `.tsx`, `Makefile` → nil, and `#!/usr/bin/env python3` → `.python`.
  - `swiftKeywordCaptured`: `let x = 1` yields a `.keyword` run at `0..<3` and `.number` at `8..<9`.
  - `incrementalEditMatchesFullParse`: apply 50 random single-byte edits through `edit` (as `CodeEdit`s built from a `CodeBuffer`). Afterwards the captures equal those of a fresh `open` on the final text.
  - `multiByteColumns`: `let s = "é🙂"; let y = 2` puts the `let` keyword run of `y` at UTF-8 byte offset 17.
  - `providerSetsHighlightsAsOf`: in a headless `CodeView` with a `CodeViewHighlighter`, after `runUntil`, `lastFrameWork.codeHighlightRunsVisited > 0`.
  - `fenceHighlighterSwift`
  - `unknownLanguagePlain`
  - `largeFileParsesOffMain`: open `Bench/Corpus/large.swift` (2.2 MB). The main actor is not blocked: a main-actor ticker task advances at least 10 times during the parse.
- [ ] **Step 2: Run the tests.** Expected: they fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite.** Expected: all pass. The release build has no warnings, including none from the grammar C code. If a grammar warns, use `unsafeFlags` only under `-w` for that C target and note it.
- [ ] **Step 5: Commit** with `feat(highlight): tree-sitter engine for CodeView and chat code fences`.

### Task 2: EditorDocument, open and close, and tabs in the model

**Files:**
- Modify: `Package.swift`. AlloyCore depends on `.product(name: "MetalUICodeBuffer", package: "MetalUI")`, which MetalUI already vends as its own product (it imports only `Observation`; confirmed by the MetalUI session).
- Create: `Sources/AlloyCore/Editor/EditorDocument.swift`
- Modify: `Sources/AlloyCore/Model/Workspace.swift`
- Test: `Tests/AlloyCoreTests/EditorDocumentTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor @Observable public final class EditorDocument: Identifiable`
    - `id: UUID`, `path: String` (relative), `buffer: CodeBuffer`, `language: String?`
    - `state: DocState`, with `public enum DocState: Equatable { case editable, readOnly(reason: String) }`
    - `savedVersion: UInt64`, the buffer version when the buffer equalled disk and ledger
    - `var isDirty: Bool { buffer.version != savedVersion }`
    - `diskStamp: FileStamp`
    - `diffMode: DiffMode`, with `public enum DiffMode { case inline, sideBySide }`
  - Workspace:
    - `private(set) var tabs: [String]`
    - `var activeTab: String?`
    - `var openFilePath: String?`, now a computed alias of `activeTab` that keeps Plan 1 call sites, tests and bench working
    - `func open(_ path: String, revealLine: Int? = nil, mode: DiffMode? = nil) async`. It reuses an existing tab. It reads off main and builds the buffer on main.
      - Over `previewLimit`: `.readOnly("File is larger than 16 MB")`, with the first 16 MB shown and none of the stopgap rows.
      - NUL in the first 8 KB: no document; the tab shows "Binary file".
      - Invalid UTF-8: `.readOnly("File is not valid UTF-8")`.
    - `func close(_ path: String) async`. It saves first if dirty.
    - `func document(_ path: String) -> EditorDocument?`
  - The ledger→buffer invariant: when `!isDirty`, `buffer.snapshot().text == ledger.files[path]?.text.text` for ledger files, and it equals the disk text for others.

- [ ] **Step 1: Write the failing tests.**
  - `openCreatesTabAndBuffer`
  - `openTwiceReusesTab`
  - `closeSavesDirtyFirst`: type into the buffer through `replace`, then close. The disk has the new text.
  - `binaryFileNoDocument`
  - `nonUTF8ReadOnly`
  - `openFilePathAliasStillWorks`: setting `openFilePath = "a.swift"` opens and activates it.
  - `sessionEditUpdatesCleanBuffer`: a `.toolResult` edit from `ScriptedTransport` on an open, clean file makes the buffer text equal the new disk text. The buffer's undo stack does not contain the change (`origin .external`).
- [ ] **Step 2: Implement.** In `Workspace.handle`, after `ledger.record`, if the file is open and clean, call `buffer.applyExternalReplacement(newText, expectingVersion: buffer.version)` and set `savedVersion = buffer.version`. The dirty path is Task 3.
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(editor): open documents and tabs backed by CodeBuffer`.

### Task 3: Save, autosave and the dirty-buffer rule

**Files:**
- Create: `Sources/AlloyCore/Editor/Autosave.swift`, `Sources/AlloyCore/Editor/DirtyMerge.swift`
- Modify: `Workspace.swift`, `Sources/AlloyKit/LauncherView.swift` (save before stop on quit and close)
- Test: `Tests/AlloyCoreTests/AutosaveTests.swift`, `DirtyMergeTests.swift`

**Interfaces:**
- Produces:
  - `func save(_ path: String) async throws`. It writes atomically and keeps POSIX permissions. Then it calls `ledger.files[path].applyFullText(author: .user, newText:, toolUseID: nil, date:)`, creating the `FileLedger` with the old disk text as baseline if there is none. It persists the ledger, sets `savedVersion` and refreshes `diskStamp`.
    - Before writing: if the disk changed since `diskStamp` and the change isn't known to the ledger, record that disk text as `.outside` first, then write.
  - `func saveAll() async`
  - Autosave: 1.0 s after the last `buffer.version` change (debounced, injectable clock), on tab switch, when focus leaves the code view (Task 6 calls `workspace.focusLeft(path)`), and in `LauncherModel.shutdownRequested` before `stopAll`.
  - The dirty-buffer rule, `DirtyMerge.merge(buffer:savedVersion:oldDisk:newDisk:) -> MergeOutcome`:
    1. The session already wrote `newDisk`. Compute the session's line hunks with `Patch.diff(oldDisk, newDisk, context: 0)`.
    2. Map each hunk's byte range from `savedVersion` to now with `buffer.map(_:from:bias:)`, using `.before` for the start and `.after` for the end.
    3. A hunk whose mapped range intersects any user edit since `savedVersion` is a **conflict**: skip it. User edit ranges come from a `CodeEditCursor` opened at the last save.
    4. Apply the non-conflicting hunks with `buffer.applyExternalEdits(_:expectingVersion:)`.
    5. Save immediately.

    The ledger therefore records the session edit (already recorded from the tool result) and then a "You" edit holding the user's typing, plus the reversal of any conflicting session hunk. For each conflict, add a transcript notice to the session's chat and a workspace notice: "Your unsaved edit in <path> overlaps <session name>'s edit at lines a–b; your text was kept."
    - `MergeOutcome { applied: Int; conflicts: [ClosedRange<Int>] }`.

- [ ] **Step 1: Write the failing tests.**
  - `autosaveAfterOneSecond`: an injected clock advances 0.9 s and the file is not yet written; at 1.1 s it is.
  - `saveRecordsYouEdit`: the ledger's last record is `.user` and `lineOwners()` attributes the typed line to it.
  - `dirtyMergeKeepsUserText`: the user types on line 2 (unsaved), and a session tool result changes line 10. The buffer then has both. The disk equals the buffer after the immediate save. Line 10 is owned by the session and line 2 by "You".
  - `overlapKeepsUserVersion`: the user edits line 5, and the session edits line 5. The user's text stays, the conflict notice appears, and disk equals buffer.
  - `quitSavesBeforeStop`: `shutdownRequested` writes the dirty buffer before `stopAndWait` is called; check the call order in a recording transport.
  - `outsideChangeBeforeSaveRecorded`
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(editor): autosave, You edits, and the dirty-buffer merge`.

### Task 4: Outside-edit watcher with attribution

**Files:**
- Create: `Sources/AlloyCore/Editor/FileWatcher.swift` (protocol plus FSEvents adapter), `Sources/AlloyCore/Editor/OutsideEdits.swift`
- Modify: `Workspace.swift`
- Test: `Tests/AlloyCoreTests/OutsideEditTests.swift`, `FileWatcherTests.swift`

**Interfaces:**
- Produces:
  - `public protocol FileChangeSource: Sendable { func changes() -> AsyncStream<[String]> }` (absolute paths). `FSEventsSource(root:latency: 0.1)` uses file-level events and ignores paths under `.build/`, `node_modules/` and `.swiftpm/`. `.git/` paths are forwarded only to Task 5.
  - `Workspace.init` gains `changes: (URL) -> any FileChangeSource`, defaulting to FSEvents. Tests inject a scripted source.
  - Handling, coalesced over 150 ms: for each changed path inside the root, read it off main.
    - Same as the ledger text and the open buffer: **ignore**. This covers Alloy's own writes and edits already recorded.
    - A session has a running Edit or Write tool block whose `input.file_path` resolves to this path: wait up to 2 s for its tool result, then re-check.
    - Exactly one session has a running shell tool: author `.session(that id)`. Otherwise the author is `.outside`. Record with `applyFullText`.
    - A file not yet in the ledger: if exactly one shell is running and the file is tracked by git, the baseline is `git show HEAD:<path>` and the edit is attributed to that session. Otherwise ignore it.
    - An open buffer: clean means `applyExternalReplacement`; dirty means Task 3's merge. Mark the change as an outside one, not a session one.
    - A deleted file: an open tab shows "File was deleted outside Alloy" and becomes read-only. The ledger is unchanged.

- [ ] **Step 1: Write the failing tests**, with a scripted change source and a temp dir.
  - `ownSaveIgnored`
  - `sessionToolWriteIgnoredByWatcher`: only one record, the session's.
  - `externalEditRecordedOutside`
  - `bashEditAttributedToSession`: one session has a running Bash block; change the file on disk; the record's author is that session.
  - `twoBashesFallBackToOutside`
  - `untrackedNewFileIgnored`
  - `deletedOpenFileReadOnly`
  - `fsEventsIntegration`: the real `FSEventsSource` on a temp dir sees a write within 2 s. Mark it `.timeLimit(.minutes(1))`.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(editor): outside-edit watcher with Bash attribution`.

### Task 5: Git commit resets the baseline

**Files:**
- Create: `Sources/AlloyCore/Editor/GitBaseline.swift`
- Modify: `Workspace.swift`
- Test: `Tests/AlloyCoreTests/GitBaselineTests.swift` (real `git` in temp repos)

**Interfaces:**
- Produces: `enum GitBaseline { static func headText(root: URL, path: String) async -> String?; static func isRepo(_ root: URL) async -> Bool }`. Both run `git -C <root> …` off main with a 5 s timeout. Detached HEAD works; no repo returns nil.
  - When the watcher reports `.git/HEAD`, `.git/refs/heads/*`, `.git/logs/HEAD` or `.git/index` (debounced 500 ms), and once on `restore()`: for every ledger file with live edits, if `headText == ledger text`, call `keepAll` for that file (spec §6.7) and persist.
  - **Ruling:** a partial commit, where HEAD differs from the current text, keeps nothing.

- [ ] **Step 1: Write the failing tests.**
  - `commitKeepsMatchingFile`: a session edit is recorded, then `git commit -am` in the temp repo. After the scripted `.git` event, the file has no live edits and leaves `changedFiles`.
  - `partialCommitKeepsNothing`
  - `noRepoNoop`
  - `detachedHeadWorks`
  - `checkoutRewritesRecordedOutside`: `git checkout` of another branch changes the file. The watcher records `.outside`, and if the result equals HEAD it is kept.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(editor): git commit resets the review baseline`.

### Task 6: The code panel: CodeView, author gutter and inline diff

**Files:**
- Create: `Sources/AlloyKit/Code/{CodePanel.swift,DiffDecorations.swift,PanelEditBar.swift}`
- Delete: the stopgap rows in `Sources/AlloyKit/FilePanelView.swift`. Keep `FilePanelView` as the container with the same identifiers.
- Modify: `Theme.swift` (tokens `authorRunAlpha`, `removedRowTint`, `addedRowTint`, reusing the edit tints), `docs/metalui-gaps.md` (G1 adopted, stopgap removed)
- Test: `Tests/AlloyKitTests/CodePanelTests.swift`, `Tests/AlloyCoreTests/DiffDecorationTests.swift` (pure mapping)

**Interfaces:**
- Produces:
  - `struct DiffDecorationModel` (pure, in AlloyCore, `Sources/AlloyCore/Editor/DiffDecorationModel.swift`): `static func build(_ lines: [DiffLine], authorOf: (UUID) -> Author, lineEnding: String) -> DiffDecorationModel`. It holds:
    - `lineBars: [(rows: Range<Int>, author: Author, edit: UUID)]` for added lines. Rows are 0-based buffer rows; consecutive rows of the same edit merge.
    - `removedGroups: [(beforeRow: Int, lines: [String], edit: UUID, author: Author)]`. `beforeRow == lineCount` means after the last line.
    - `authorRuns: [(byteRange: Range<Int>, author: Author)]` for added lines with more than one author. Absolute UTF-8 offsets come from the cumulative line byte lengths, including terminators.
    - `tags: [UInt64: UUID]`
  - The `CodePanel` view puts these into `CodeDecorations`:
    - `setLineDecorations(gutterBar: authorColor, background: addedRowTint, tag:)`
    - `setVirtualRows(removedGroups → CodeVirtualRow(anchor: .before(line:), lines:, gutterBar: authorColor, background: removedRowTint, gutterMarker: "-", tag:))`
    - `setHighlights(authorRuns as background runs at authorRunAlpha, layer: .annotations)`

    All of these are `asOf: document.savedVersion`. They are recomputed only when the file's `FileLedger.version` changes. Count recomputes in a test counter `Workspace.decorationBuilds`.
  - Retain the `CodeViewHighlighter` on the panel's per-document holder: `@MainActor final class OpenDocumentView { decorations; highlighter }`, kept in a dictionary keyed by path.
  - `CodeView(buffer:decorations:).font(family: "Menlo", size: 12).codeViewEditable(document.state == .editable)`, plus:
    - `.onGutterBarClick { hit in selectedEdit = tags[hit.tag] }`
    - `.gutterBarContextMenu { hit in Keep / Revert / Show in chat / Side by side }`
  - `PanelEditBar` (id `panel-edit-bar`) shows when an edit is selected: "<author> · <time> · Keep · Revert · Show in chat". Button ids are `panel-keep-<uuid>`, `panel-revert-<uuid>` and `panel-show-in-chat-<uuid>`. Revert of an open document saves first if dirty, then calls `workspace.revert` and reloads the buffer with `applyExternalReplacement`.
  - Header (id `file-panel-path`): the path, a dirty dot, the read-only reason, and an inline/side-by-side toggle (id `diff-mode-toggle`).
  - Find bar: ⌘F shows a `TextField` (id `find-field`) with a match count (id `find-count`), ↑ and ↓ buttons, and Esc to close. The search runs `snapshot.ranges(of:)` off main and assigns `findMatches` only if `snapshot.version == buffer.version`. ⌘G is MetalUI's.
  - Focus leaving the code view calls `workspace.focusLeft(path)` (Task 3).

- [ ] **Step 1: Write the failing tests.**
  - The pure mapping, in `DiffDecorationTests`:
    - `addedRowsBecomeBars`
    - `removedGroupAnchorsBeforeNextRow`
    - `removedAtEndAnchorsAfterLast`
    - `crlfOffsets`: a `\r\n` file's second-line runs start at byte `len(line1)+2`.
    - `emojiLineRuns`: two sessions edit one line containing `🙂`, and the run byte ranges match `utf8` offsets.
  - `CodePanelTests`, headless:
    - `panelShowsCodeViewTextArea`: `elements(role: .textArea)` has a value containing the file's first line.
    - `gutterClickSelectsEdit`: use `window.click` at the bar position, found with `scene.rects` matching the author color.
    - `panelKeepRemovesBar`
    - `panelRevertRestoresText`
    - `findCountsMatches`
    - `keystrokeDoesNotRebuildDecorations`: `decorationBuilds` is unchanged after `typeText("a")`.
    - `sessionEditRebuildsOnce`
    - `largeFileKeystrokeShapesFewLines`: open `Bench/Corpus/large.swift` and type one character. Then `lastFrameWork.codeLinesShaped <= 2`.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the full suite.** Expected: all pass. Bench's `FilePanel` identifiers still resolve.
- [ ] **Step 4: Commit** with `feat(ui): CodeView panel with author gutter, inline diff, Keep/Revert, find (G1)`.

### Task 7: Side-by-side diff

**Files:**
- Create: `Sources/AlloyKit/Code/SideBySideView.swift`, `Sources/AlloyCore/Editor/SideBySideModel.swift`
- Test: `Tests/AlloyCoreTests/SideBySideModelTests.swift`, `Tests/AlloyKitTests/SideBySideTests.swift`

**Interfaces:**
- Produces:
  - `struct SideBySideModel` (pure): `static func build(_ lines: [DiffLine]) -> SideBySideModel` with:
    - `oldText: String`: the context and removed lines in order. This is the ledger's "old view": baseline plus kept edits.
    - `leftFillers: [(beforeRow: Int, count: Int)]`, where the right side has added lines
    - `rightFillers: [(beforeRow: Int, count: Int)]`, where the left side has removed lines
    - `leftBars` and `rightBars` per author, with tags
  - `SideBySideView`:
    - Left: a read-only `CodeView` over a `CodeBuffer(oldText)`, rebuilt when the ledger version changes, with `.filler` virtual rows and removed-line backgrounds.
    - Right: the live document buffer with added-line decorations and `rightFillers`. It has no removed virtual rows in this mode.
    - Scroll sync: two `CodeScrollState`s. Each view's `onScroll` assigns the other's `position`; MetalUI doesn't echo. Display rows include fillers, so the panes stay aligned.
    - Ids: `sbs-left`, `sbs-right`.
  - The chat's `EditActions` (Plan 1) gains "Open in file" (id `open-in-file-<uuid>`) and "Side by side" (id `side-by-side-<uuid>`). They call `workspace.open(path, revealLine: firstLine(of: edit), mode:)`. `revealLine` calls `buffer.select(lineRange, reveal: true)`.

- [ ] **Step 1: Write the failing tests.**
  - `fillersBalanceRowCounts`: the left rows plus left fillers equal the right rows plus right fillers, over 200 random diffs built from `FileLedger` edits.
  - `oldTextEqualsBaselinePlusKept`
  - `scrollSyncs`: scroll the left view by 10 rows with `window.scroll` at its frame, then the right position's row is about the same (±0.01).
  - `sideBySideButtonOpensMode`
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(ui): side-by-side diff with synced scrolling`.

### Task 8: Tabs, quick-open, and opening from the chat

**Files:**
- Create: `Sources/AlloyKit/Code/TabBar.swift`, `Sources/AlloyKit/QuickOpen.swift`
- Modify: `FilePanelView.swift`, `SidebarView.swift` (changed-file click → `open`), `ChatBlockViews.swift` and `ToolBodies.swift` (paths are clickable), `RootView.swift` (keymap), `docs/metalui-gaps.md` (G4)
- Test: `Tests/AlloyKitTests/TabsTests.swift`, `QuickOpenTests.swift`

**Interfaces:**
- **Gate and stopgap:** use MetalUI's `TabStrip(selection:tabs:)` with `TabStripItem(id:title:icon:accent:isDirty:isClosable)`, `.onCloseTab` and `.onMoveTab` if they are on master. Otherwise use `TabBar`:
  - an `HStack` in a horizontal `ScrollView` of buttons;
  - a leading accent dot in the color of the last session that edited the file, a dirty dot, and a close "×";
  - ids `tab-<path>` and `tab-close-<path>`;
  - logged as a G4 stopgap.
- Keys:
  - ⌘W closes the active tab.
  - ⌃Tab and ⌃⇧Tab cycle tabs.
  - ⌘1 to ⌘9 select a tab.
  - ⌘P opens quick-open.

  These are registered in `AlloyScreen` with `onKeyPress` or `keyboardShortcut`. They must not steal ⌘G or ⌘F from the code view while it is focused.
- Quick-open:
  - It is a panel overlay over the file panel. Use `anchoredOverlay` at the panel's top centre, or `.suggestionOverlay` if it has merged.
  - It has a `TextField` (id `quick-open-field`) and up to 50 rows (ids `quick-open-row-<i>`) from `FuzzyMatch.top(query, in: FileIndex.paths())`. Changed files rank first when the query is empty.
  - ↑, ↓, Return and Esc navigate. Return calls `workspace.open`.
- Chat paths: the tool-block summary path and the paths in read, edit and write headers become buttons (id `open-path-<toolUseID>`). They call `open(path, revealLine:)`, using the edit's first changed line where known.
- Changed-files row click: `open(path)`, replacing Plan 1's `openFilePath` assignment.

- [ ] **Step 1: Write the failing tests.**
  - `tabsOpenAndClose`
  - `cmdWClosesActive`
  - `ctrlTabCycles`
  - `dirtyDotShows`
  - `accentIsLastSessionColor`
  - `quickOpenFiltersAndOpens`
  - `emptyQueryListsChangedFirst`
  - `chatPathOpensFileAtLine`
  - `cmdFStillReachesCodeView` (a regression guard on the keymap order)
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(ui): tabs, quick-open, open files from chat and sidebar`.

### Task 9: Benchmark: Alloy typing and scrolling through CodeView

**Files:**
- Modify: `Bench/Sources/BenchCore/Targets.swift` (Alloy typing becomes supported; the typing target point is the file panel centre, like scrolling), `Bench/Sources/BenchScenarios/*` as needed, `Bench/README.md`
- Test: `Bench/Tests/*`

**Interfaces:**
- Alloy's `typingLatency`: launch `Alloy <dir> <file>` and click once at the file panel's scroll point to focus the `CodeView`. Then run the same keystroke script as Zed. Remove the "n/a until Plan 4" reason.
- No other harness behaviour changes.

- [ ] **Step 1: Write the failing tests.**
  - `alloyTypingSupported`: the target table's Alloy typing support flips.
  - `alloyTypingClickPointIsPanel`
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run** `swift test --package-path Bench`. Expected: all pass. Live tests self-skip.
- [ ] **Step 4: Commit** with `feat(bench): measure Alloy typing in the CodeView panel`.

### Task 10: Live check, docs, parity checkpoint

- [ ] **Step 1: Build.** Run `swift build -c release`. Expected: no warnings. Run `swift test` and `swift test --package-path Bench`. Expected: all pass.
- [ ] **Step 2: Update the docs.**
  - In `docs/metalui-gaps.md`: G1 adopted; the G4 stopgap or adoption; G5 not needed, because CodeView scrolls on both axes itself.
  - README feature list.
- [ ] **Step 3: Live smoke run, by the user** (scratch repo). Checklist:
  - highlighting
  - two sessions edit one file: the gutter colors are right, and a shared line shows both authors
  - typing while a session edits the same file loses nothing
  - Keep and Revert from the gutter
  - side-by-side scrolls in sync
  - an edit in another editor shows as outside
  - `sed` via a session's Bash is attributed to that session
  - `git commit` clears reviewed files
  - ⌘P, tabs, find
- [ ] **Step 4: Parity checkpoint (roadmap Plan 6 input).** Run the full `alloy-bench --apps zed,alloy`. Every Alloy metric at or better than Zed's median goes in the ledger. Each shortfall is triaged: Alloy cause → a fix task; MetalUI cause → message the MetalUI session with numbers and repro.
- [ ] **Step 5: Commit** with `docs: Plan 4 status and first full Alloy-vs-Zed comparison`.
