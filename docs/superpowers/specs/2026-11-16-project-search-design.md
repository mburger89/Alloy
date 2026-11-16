# Alloy: Project-wide search and replace

Date: 2026-11-15. Status: draft for the user (revised after the builder check). Builds on Code mode
(`2026-11-15-alloy-code-mode-design.md`), which names search as project 2 of 4 and reserves the sidebar's Search tab
slot.

## Intent and why

The user plans "project/repo wide search" as the next step after Code mode. Today Alloy can find inside one file
(CodePanel find) and open files by name (Quick Open), but cannot answer "where is this used?" across the project, and
cannot rename a string everywhere without asking Claude. The brief: search the whole project (literal, case, whole
word, regex, include/exclude globs, respecting `.gitignore`), results grouped by file with line previews, click to jump
into the focused editor group; Replace in selected results or Replace All, reviewed through the same Keep / Revert diff
review used for Claude's edits, as one undoable change. It must stay fast on large repos: off the main thread,
streaming, cancellable.

## Approaches

1. **Swift-only engine in AlloyCore over FileIndex, replace written as ledger edits (recommended).** A UI-free
   `SearchEngine` walks `FileIndex.paths()`, scans bytes per file off the main thread and streams batches; replace
   produces one `EditRecord` per file on the existing ledger, so the gutter bars and Keep / Revert work unchanged. Same
   code on macOS, Linux and Windows. Costs: we own the matcher (memmem fast path plus `Regex`).
2. **Shell out to `rg` / `git grep`.** Fastest to write and very fast, but adds a runtime dependency, behaves
   differently per platform (no `rg` on a stock Mac or Windows), and parsing its output costs about what our own scan
   does. Rejected: breaks "Linux/Windows mirror macOS, no substitutes".
3. **Replace applied straight to buffers with a new cross-file undo stack, no ledger.** Gives literal ⌘Z across files,
   but invents a second review model beside the ledger, and the user asked for the same review Claude's edits get.
   Rejected as the primary model; per-file ⌘Z still works inside approach 1 because open documents take the replace
   as one `CodeBuffer.transaction` (Goal 7).

## Goals

1. **Search tab** (`code-sidebar-tab-search`, beside `code-sidebar-tab-files` in row `code-sidebar-tabs`). The two
   tab icons become buttons; the selected one draws in `.ink`, the other in `.mutedInk` **(our call)**. The tab is
   remembered per project in ui-state. View > "Find in Files" (⌘⇧F; Ctrl+Shift+F on Linux and Windows, since MetalUI
   maps `.command` to Ctrl there) switches to Code mode if needed, shows the tab and focuses the query field, seeded
   with the focused editor's single-line selection **(our call)**. View > "Replace in Files" (⌘⇧H / Ctrl+Shift+H) does
   the same and reveals the replace field. Neither shortcut is used in Alloy's menus today; ⌥⌘H (Hide Others) is a
   different chord.
2. **Query options.** Three toggles at the field's trailing edge using MetalUI's existing `.toggleStyle(.button)`
   (bordered, filled with the accent while on): Match Case (`search-opt-case`), Whole Word (`search-opt-word`), Regex
   (`search-opt-regex`). A disclosure "files to include / exclude" (`search-globs`) reveals two glob fields
   (`search-include`, `search-exclude`), comma separated, `fnmatch` semantics with `**` support and a bare name
   meaning `**/name/**` **(our call)**.
3. **What is searched.** Exactly the paths in `FileIndex`: in a git repo, `git ls-files --cached --others
   --exclude-standard`, so `.gitignore`d files and symlinked directories are excluded by construction and tracked
   vendored files (a committed `node_modules`) are searched; outside git, the directory walk with its
   `skippedDirectories`. The index holds at most `FileIndex.maxPaths` (100,000) paths; past that the summary says
   "partial: index truncated" (same text family as the file tree note). A "search ignored files" option is a non-goal.
4. **Live, streaming results.** Typing re-runs after a 200 ms debounce; Return runs immediately; when the index is
   truncated, typing does not run and only Return does **(our call)**. Results stream in as file groups (disclosure
   row: file name, dimmed folder path, match count), each with line previews (line number, trimmed line with the match
   highlighted). A summary line (`search-summary`) reads "1,204 results in 87 files", with "searching…" while running,
   and notes for the cap ("10,000+ results, refine the query"), truncation, skipped files and stale results. An invalid
   regex shows the error inline under the field (`search-error`) and runs nothing.
5. **Jump.** Clicking a preview opens the file in the focused group through `Workspace.open(_:selecting:in:)`. That
   API takes a closure `(CodeSnapshot) -> Range<Int>` and selects on the main actor after load; Search passes a closure
   that re-checks the stored byte range against the loaded snapshot (in bounds, on scalar boundaries, same bytes as the
   match) and falls back to the start of the stored line when the text moved **(our call)**. ↑/↓ moves through
   results and Return opens; Go > "Next Result" / "Previous Result" (F4 / ⇧F4) step from the editor **(our call)**.
   "Open to the side" (⌥-click into a new split) is a non-goal for v1: no single call opens a file in a new split today.
6. **Open documents first.** Files with an open document are searched from `doc.buffer.snapshot()`, so unsaved edits
   are found and positions match what is on screen; everything else reads disk.
7. **Replace.** A replace field (`search-replace`) with "Replace All" (`search-replace-all`) and per-file / per-line
   replace buttons on hover (`search-replace-file-<n>`, `search-replace-line-<n>-<m>`); no checkboxes, dismissing a
   line or file (×, `search-dismiss-<file>[-<line>]`) removes it from the set instead **(our call, like VS Code)**.
   Regex mode supports `$1` / `${name}` captures; in literal and whole-word mode the replacement is inserted verbatim
   (`$1` is literal text). Replace is enabled only for a finished, non-stale result set (see "Stale results").
   Before writing, each file's matches are re-verified against its current text; changed files are skipped and
   reported ("3 files changed since search; re-run"). Ranges are applied back to front so earlier replacements never
   shift later ones. Applying is described under "Replace pipeline". Every file's edit is tagged with one group id;
   the edits appear as live gutter bars with Keep / Revert, file tree dots and Chat's changed-files list exactly as
   Claude's edits do.
8. **Review the replace as one change.** After a replace the results pane becomes a review list: each file with its
   diff count and outcome, plus "Keep All" (`search-review-keep-all`) and "Revert All" (`search-review-revert-all`)
   that loop `keep(edit:path:)` / `revert(edit:path:)` over the group's edits. Revert All is the cross-file undo.
   Inside an open file, ⌘Z undoes that file's replacement as one step, because the replace runs inside one
   `CodeBuffer.transaction`.
9. **Cancel.** A new query, clearing the field, closing the project or Escape in the field
   (`onKeyPress(.escape)`, as the sidebar's rename field already does) cancels the running search.

## Calls settled without the user (our calls)

1. **Where the model lives.** `SearchModel` is a `@MainActor @Observable` class in AlloyCore (UI-free, like
   `FileTreeModel`), owned by `Workspace` as `@ObservationIgnored public let search`. That keeps `Workspace.track`
   internal, lets `AppCommands` reach it through `model.workspace?.search`, and means no Workspace view observes it.
   Only `SearchView` (AlloyKit) reads its observed properties. The engine is an `actor SearchEngine` returning
   `AsyncStream<SearchBatch>`; the model holds a generation ticket like Quick Open and the LSP coordinator.
2. **Tab state.** `CodeLayout.sidebarTab: SidebarTab` (`files` | `search`) beside `chatCollapsed`, with the same
   `didSet` that schedules a ui-state write. `CodeSidebarView` stays `Equatable` on workspace identity and reads
   `sidebarTab` in its body, so only a tab click re-runs it; no save, watcher or search path writes it. Showing the
   Search tab removes `FileTreeView`, whose `onDisappear` already stops tree scans.
3. **Matching.** Literal and whole-word use the byte path: `memmem` per line, ASCII word-boundary check, and for
   case-insensitive search an ASCII-lowered copy of the current line only, into one reused buffer per worker (never a
   lowered copy of the whole file). Non-ASCII case folding is exact only in regex mode with Match Case off; the Match
   Case tooltip says so. Regex mode runs Swift `Regex` per line on a `Substring` (matches never span a newline in v1).
   Matches are found left to right and never overlap: the next search starts at the previous match's end.
4. **Byte offsets.** Every match is a UTF-8 byte range `Range<Int>` in the file. Regex results map with
   `line.utf8.distance(from: line.startIndex, to: index)` plus the line's byte offset. Lines split on `\n`; a trailing
   `\r` is excluded from the line the matcher sees (so `$` matches before it) and preserved on write.
5. **Empty matches.** Zero-width matches (`^`, `a*` on "b") are not results; after one the scan advances one
   character, so it can never loop. A regex whose every match is empty shows "Regex matches only empty text" and
   replace stays disabled.
6. **Limits and skips.** Skip files over 16 MB (`Workspace.previewLimit`) and files whose first 8 KB contain a NUL
   byte. In regex mode, lines over 64 KB (minified files) are skipped, and each file gets a 250 ms regex budget checked
   between lines; a file over budget stops and is counted. All skips are counted in one note: "N files skipped
   (binary, large or slow)".
7. **Memory and concurrency.** Four workers, dispatched in index order. Files over 4 MB are read one at a time, so
   at most about 4 MB × 3 + 16 MB is resident in the worst case. Previews are capped at 200 characters around the
   match; caps of 10,000 matches and 2,000 files keep the model under about 3 MB.
8. **Ordering and head-of-line.** Results are flushed in index order. Finished files behind a slow head file wait in
   a reorder buffer of at most 256 files; when it is full, workers pause. The per-file regex budget and the 16 MB cap
   bound how long any head file can stall the flush.
9. **Batches** flush every 50 ms or 500 matches, whichever comes first.
10. **Stale index.** A file event that `affectsFileTree` while the tree is inactive sets
    `@ObservationIgnored var fileIndexStale = true` on `Workspace` (one Bool write, no task). A search start that sees
    it awaits `fileIndex.refresh()` once and clears it; otherwise search reads `fileIndex.paths()` as is and never
    starts `git ls-files` itself.
11. **Stale results, no automatic re-run.** Document saves and FileWatcher events call
    `search.noteChanged(path)`, an O(1) check that does nothing unless there are finished results not yet marked
    stale. The first such call per generation sets the observed `isStale` once (one `SearchView` re-run, showing
    "Results may be out of date · Re-run" and disabling Replace). Every later call returns at the guard, so autosave
    during typing costs nothing. Re-runs happen only on a user action: Return, an option or glob change, the Re-run
    link, or showing the tab with stale results.
12. **Ledger attribution.** `Author.user` plus a new optional `group: UUID?` on `EditRecord` (see Decision 1).
13. **Settings.** `searchMaxResults` (default 10,000, clamped to 100…50,000) and `searchExcludes` (default empty,
    appended to every query's exclude), decoded `(try? c.decodeIfPresent(...)) ?? default` like the theme keys, so a
    bad hand edit falls back instead of failing the file. A "Search" group in Settings.
14. **ui-state.** `CodeLayoutState` / `UIState` gain `sidebarTab` and `lastSearch: SearchQuery?` (text, options,
    globs; not results, not the replacement text), each decoded `(try? decodeIfPresent) ?? default` as the file's
    comment prescribes. `currentVersion` stays 1: old files load with defaults, and an older Alloy ignores the new
    keys. `lastSearch` is written when a search runs, not per keystroke.
15. Search runs on the whole project root only; no "search in folder" from the tree in v1.
16. **Results list.** MetalUI `List` + `ForEach` over file groups, with one row component per group (a disclosure
    over its previews), following `FileTreeView` / `FileTreeNodeRow`: everything conditional lives in the row so the
    list stays lazy. `LazyTree` is not used: Alloy has no precedent for it, and `List` already gives selection and
    keyboard movement.
17. **Highlight.** A preview row is one `Text(AttributedString)` with a `backgroundColor` run over the match (already in
    MetalUI's `TextAttributes`). Task 4 measures the per-row cost with 2,000 visible groups.

## Non-goals

- Searching ignored files, symlinked directories outside the root, or binary contents.
- Multi-line queries and multi-line regex matches.
- Search history beyond the last query, saved searches, a search editor tab, structural / LSP-aware rename.
- Replace preview as a separate diff editor before applying (the ledger review is the preview).
- Opening a result in a new split (⌥-click).
- Replacing in files that are not valid UTF-8 (they are searched, but replace skips them; see Failure modes).

## Anti-goals

- No cost when not searching: no timers, no file scans while the Search tab is hidden or the query is empty, no
  observation of search state by editor, chat or tree views, no automatic re-run.
- No main-thread file I/O or matching; the main thread only appends batches.
- Never a silent partial result: caps, truncation, skipped, stale and changed files are always stated.
- Never write a file Alloy cannot attribute: every replace write goes through the workspace and the ledger.

## Constraints

- Steady keystroke-frame guards hold: Chat 88, Code 91 / 107 / 117 element requests per frame, idle frames 0, with
  the Search tab closed, open and idle, open with finished results, open with stale results, and while a search
  streams.
- Cross-platform: one Swift engine; file enumeration is FileIndex. No `rg`, `grep` or platform search APIs. Shortcuts
  use `.command`, which MetalUI maps to Ctrl on Linux and Windows.
- Settings and ui-state stay lenient-decoding with defaults.
- MetalUI is not worked around (see MetalUI gaps).

## Design

### UI sketch

```
┌ [▤|⌕] ─────────────────────────┐
│ ⌕ [ fooBar           ][Aa][ab][.*]│
│ ⇄ [ bazQux           ][Replace All]│
│ ▸ files to include / exclude      │
│ 1,204 results in 87 files · searching… │
│ ▾ Workspace.swift  Sources/…  12  │
│     468  let index = fooBar(root) │
│    1456  open(fooBar, revealLine: │
│ ▸ PanelActions.swift  Sources/… 3 │
└───────────────────────────────────┘
```

### Architecture and data flow

- **AlloyCore/Search/SearchQuery.swift**: `struct SearchQuery: Sendable, Codable` (text, caseSensitive, wholeWord,
  regex, include, exclude) and `compile() throws -> SearchMatcher`.
- **AlloyCore/Search/Glob.swift**: `fnmatch`-backed include/exclude filter, pure and unit tested.
- **AlloyCore/Search/SearchEngine.swift**: `actor SearchEngine`. `run(query, paths, overlays: [String: CodeSnapshot])`
  returns `AsyncStream<SearchBatch>`. Overlays are taken on the main actor at search start, one
  `doc.buffer.snapshot()` per open document: O(open documents), each a copy-on-write rope snapshot, no text copy.
  Work runs in a detached task with the worker, ordering and memory rules in our calls 6 to 9.
  `Task.checkCancellation()` per file and every 4,096 lines (the FuzzyMatch pattern). Test hook `setScanGate`.
- **AlloyCore/Search/ReplacePlan.swift**: given results and replacement, builds per-file `[(Range<Int>, String)]`
  sorted back to front, re-verifies against the current text, returns applied / skipped with reasons.
- **AlloyCore/Search/SearchModel.swift**: `@MainActor @Observable`; observed: query, groups, summary, error,
  `isRunning`, `isStale`, review state. `@ObservationIgnored`: the generation, the running task, the stale guard.
  Started only through `workspace.track {}`; `shutdown()` on project close.
- **AlloyCore/Model/Workspace+Search.swift**: `replace(_ plan:)`, `keepAll(group:)`, `revertAll(group:)`, and the
  `fileIndexStale` hook.
- **AlloyKit/Search/SearchView.swift**: the fields, toggles, summary and results `List`. `CodeSidebarView` switches
  between it and `FileTreeView` on `sidebarTab`.

### Ledger changes

- `EditRecord` gains `public var group: UUID?`, explicit `CodingKeys` and a custom `init(from:)` that decodes every
  existing field as today and `group` with `decodeIfPresent` (old ledgers decode as `nil`). `Author` is unchanged.
- `FileLedger.applyFullText` and `record` gain `group: UUID? = nil`; `appendToLedger(_:saved:baseline:edits:)` gains
  `group: UUID? = nil` and passes it through `applying`. Existing callers compile unchanged.
- **Batched persist.** `ProjectLedger` is one JSON file, so `persistLedger` re-encodes the whole ledger on every
  `appendToLedger`; 2,000 per-file appends would be quadratic. `Workspace.withLedgerBatch(_:)` raises a depth
  counter that makes `persistLedger` only set a dirty flag, and persists once when the outermost batch ends. Replace
  All and Keep All / Revert All run inside one batch.

### Replace pipeline

Files are applied one at a time on the main actor's schedule, with I/O detached, inside `withLedgerBatch`.

- **Skipped up front and listed:** a document in `DocState.readOnly`; a file over 16 MB; a file that is not valid
  UTF-8 (the buffer would repair bytes the user never touched); a file that is gone, renamed or unreadable at
  re-verify (paths compare exactly, so a case-only rename counts as gone).
- **Open document** (searched from its buffer):
  1. If the document is dirty, `try await save(path)` first, so the user's earlier typing lands as its own `.user`
     edit and the replace edit holds only the replace **(our call)**.
  2. Re-verify the plan against `doc.buffer.snapshot()`; skip the file if any match moved.
  3. `buffer.transaction { for each range, back to front: $0.replace(range, with: text, origin: .programmatic) }`:
     one transaction, one undo step (`.programmatic` is undoable), LSP sync, autosave and DirtyMerge see it. The
     transaction records the selections before and after, so ⌘Z restores the caret where it was.
  4. Set `pendingGroup[path] = group` (`@ObservationIgnored`) and `try await save(path)`. `performSave`'s `.wrote`
     branch passes `pendingGroup.removeValue(forKey: path)` to `appendToLedger`; any other branch (the file changed
     on disk and is merged) leaves it for the pass that writes. The review lists the file only once its tagged edit
     exists, so Keep All / Revert All never run before the ledger has the edit.
  5. Accepted edge: `save` starts its write in a new main-actor task, so a keystroke that lands between step 3 and the
     write's snapshot is part of the tagged edit. Reverting that edit then reverts the keystroke too; this is the same
     window autosave has today.
- **Closed file**, inside the path's `saving[path]` slot (the same slot `save` and `performRevert` use, waited for
  first; this also serializes with a running `mergeBusy` merge, which only happens inside a save):
  1. Read the file and its stamp off main; re-verify the plan against those bytes.
  2. `writeKeepingMode(newBytes, to: resolvedURL, abortIf: { stamp(of: target) != readStamp })`, so a session edit
     or another program writing meanwhile aborts the write; the file is reported "changed during replace".
  3. `appendToLedger(path, saved: nil, baseline: oldText (only when the ledger has no entry), edits: [(.user, newText)], group: group)`.
  4. Release the slot and bump `saveEpoch[path]`. The watcher's `readSettled` waits on `saving[path]` and re-reads
     when the epoch moved, so by the time it compares disk with `ledger.files[path]` the ledger already holds the new
     text and nothing is attributed as an outside edit. A file opened afterwards loads the new disk text and
     `reconcileOnOpen` finds it equal to the ledger.
- **Claude editing a file during Replace All:** an open document goes through `save`, whose merge loop already folds
  in a session edit. A closed file is protected by the stamp check in step 2. A live session edit on the same lines
  stays its own ledger edit; the replace edit sits on top of it like any later user edit.
- **Project closed mid-replace:** the file in flight finishes its write and ledger append, then the loop stops; the
  batch persists on exit. The review list shows what was applied.
- **Keep All / Revert All** run inside one ledger batch. Revert goes through `revert(edit:path:)`, so an open dirty
  buffer goes through `performRevert`'s conflict handling. The review list shows a per-file outcome and the summary
  "Reverted 38 of 41 files; 3 kept because they were edited since (see each file)", with each conflict's reason from
  `RevertOutcome.conflict(reason:)` on its row.

### Accessibility ids

`code-sidebar-tab-files`, `code-sidebar-tab-search`, `search-query`, `search-opt-case`, `search-opt-word`,
`search-opt-regex`, `search-globs`, `search-include`, `search-exclude`, `search-replace`, `search-replace-all`,
`search-replace-file-<n>`, `search-replace-line-<n>-<m>`, `search-summary`, `search-error`, `search-rerun`,
`search-file-<index>`, `search-line-<file>-<line>`, `search-dismiss-<file>[-<line>]`, `search-review-keep-all`,
`search-review-revert-all`.

### Failure modes

- Unreadable file during search: skipped and counted. Non-UTF-8 files are byte-searched; previews decode lossily;
  replace skips them.
- File changed between search and replace: skipped and listed. Changed during the write: aborted by the stamp check
  and listed.
- Search cancelled, or results stale, then Replace All: Replace is disabled until a finished, current search exists;
  re-verify still guards any race.
- Regex that matches empty text, catastrophic backtracking, very long lines: our calls 5 and 6.
- Project closed mid-search: the search cancels; mid-replace: see Replace pipeline.
- Huge result sets: capped with the note; previews never load whole files into the UI model.

## Performance plan

- **Idle zero:** nothing is scheduled while the query is empty or the tab is hidden; a finished search holds a value
  array and no tasks. The stale hook is one guarded call per save or file event with no task and, after the first,
  no observed write.
- **Typing zero (editor):** the editor, tree and chat views never read `SearchModel`; it is `@ObservationIgnored` on
  `Workspace`, and `sidebarTab` is written only by tab clicks and menu commands. Autosave during typing reaches
  `noteChanged`, which returns at its guard after the first time, so no `SearchView` re-run follows a keystroke.
- **Typing in the query field:** costs that field; result arrival costs the appended rows (the `List` builds visible
  rows only).
- **Streaming:** at most one main-actor apply per 50 ms batch; a batch appends groups, no full reload.
- **Replace:** one ledger persist per Replace All; ledger observation coalesces per frame.
- **New guards** (extend CodeModePerformanceTests and ViewRerunTests): steady Code guards with the Search tab open and
  idle; with 2,000 finished results visible; with stale results while typing in the editor (autosave firing);
  `idleTicksWithFinishedSearchRerunNothing`; `hiddenSearchTabScansNothing` (file events while hidden start no task);
  `BodyProbe.hit("SearchView")` and `BodyProbe.hit("CodeSidebarView")` stay 0 on editor keystrokes; Chat 88 with a
  finished search in the background; appending a batch does not rebuild existing visible rows.
- **Bench:** a `search` scenario in Bench/BenchScenarios on the large corpus: time to first batch, total time, worst
  main-thread frame during the search, and Replace All of 1,000 matches across 200 files (time and persist count).
  Targets: first batch under 50 ms, full literal search of a 50k-file repo (within the 100k index cap) under 1 s on
  Apple silicon, no frame over 8 ms while searching.

## MetalUI gaps (forward to the MetalUI session)

None is known to be needed. The builder check found the earlier list already covered: `CodeBuffer.transaction` (one
undo step for several edits), `Text(AttributedString)` with `backgroundColor`, `.toggleStyle(.button)` with an
on-state fill, `onSubmit` and `onKeyPress(.escape)` on a text field. One conditional item:

1. **`List` append without re-laying out existing rows.** If the Task 4 guard "appending a batch does not rebuild
   existing visible rows" fails, file it: appending items at the end of a `ForEach` inside a `List` should build only
   the new rows (SwiftUI equivalent: `List` with identifiable data diffs by id). Alloy does not work around it.

## Testing strategy

- AlloyCoreTests: `SearchQueryTests` (case, word boundaries, regex, captures, `$1` verbatim in literal mode, empty
  matches, invalid regex, CRLF lines, UTF-8 offsets of multibyte text), `GlobTests`, `SearchEngineTests` (ordering,
  reorder-buffer cap, caps, binary/large/slow skips, overlay from open snapshot, cancellation via scan gate, truncated
  index note, stale index refresh), `ReplacePlanTests` (back-to-front, re-verify, skipped reasons, multibyte ranges),
  `EditRecord` decode of old ledgers without `group`, `UIStateTests` for `sidebarTab` and `lastSearch`, settings
  lenient decode.
- Workspace tests: replace into an open dirty document (earlier typing saved as its own edit, ⌘Z undoes the replace
  in one step), into a closed file (no outside-edit attribution; stamp abort), read-only and non-UTF-8 skips, Keep All
  / Revert All by group including a revert conflict, one ledger persist per Replace All, all awaiting
  `Workspace.settle()`.
- AlloyKitTests: `SearchViewTests` (tab switch, ⌘⇧F seeding, Escape cancels, click-to-jump selects the range in the
  focused group with the moved-text fallback, landedCount pattern from QuickOpenTests), plus the guards above.
- `swift test --no-parallel`, zero warnings, Linux CI build of AlloyCore search.

## Task breakdown

1. Search core: `SearchQuery`, matcher (byte and regex paths, offsets, CRLF, empty matches), `Glob`, tests (no UI).
2. `SearchEngine` streaming, ordering, caps, skips, budgets, cancellation, overlay snapshots, stale-index refresh;
   tests and bench scenario.
3. `CodeLayout.sidebarTab` + ui-state + settings keys + menus (⌘⇧F / ⌘⇧H, F4 / ⇧F4), tab buttons, Search tab shell
   with no results; perf guards for closed and idle.
4. `SearchModel` + `SearchView` results list, highlight, jump, keyboard navigation, stale handling; finished-results
   and append guards.
5. Ledger `group` field, `withLedgerBatch`, `ReplacePlan`, `Workspace` replace for closed files.
6. Replace into open documents (`transaction` + save with `pendingGroup`), review list with Keep All / Revert All and
   outcomes.
7. Notes and polish; final bench and guard pass.

Tasks 1, 3 and 5 can run in parallel; 2 follows 1; 4 follows 2 and 3; 6 follows 4 and 5.

## Decisions for the user

1. **How a replace is attributed in the ledger.** (a) `Author.user` plus a `group` id on `EditRecord` (no new author,
   lenient decode of one field); (b) a new `Author.replace` case (clear in the UI, but every `Author` switch and the
   ledger format change); (c) plain `.user` with no grouping (no Keep All / Revert All for a replace). **Recommend
   (a).**
2. **What "one undoable change" means.** (a) Revert All in the review list is the cross-file undo, and ⌘Z undoes
   per file in open documents (works with today's `CodeBuffer.transaction`); (b) a project-level ⌘Z that reverts the
   whole last replace from any editor (a new cross-file undo model). **Recommend (a).**
3. **Replace All confirmation.** (a) apply immediately, review afterwards with Keep / Revert; (b) a confirm sheet
   "Replace 312 matches in 41 files?" first; (c) apply immediately below 1,000 matches, confirm above. **Recommend
   (c).**


## Approved decisions (2026-11-16)

The user approved every recommendation above ("Approved build it"). Binding:
- 1(a) `Author.user` plus a group id on `EditRecord` (shared with code intelligence). 2(a) Revert All is the cross-file undo; ⌘Z per file.
- 3(c) apply immediately below 1,000 matches, confirm above.
