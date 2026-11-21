# CSV Table view: design

## Intent

The user said they want to work with CSV files in Alloy for "checking and editing values where they're incorrect". In practice an agent produces or changes a CSV, and the user checks it and fixes wrong cells in place. A text view of comma-separated values is poor for checking. A table is the right view, but it must not break what makes Alloy useful: attribution of who changed what, undo, agents editing the same file, and the speed targets.

## Goals

- CSV and TSV files in Code mode get a **Text | Table** switch. Both show the same open document.
- Table shows:
  - a frozen row-number column;
  - the header row as column titles;
  - one cell per field, with RFC 4180 quoting understood (quoted delimiters, doubled quotes, newlines inside quotes, CRLF, BOM).
- **Edit a cell in place.** The edit becomes the smallest text replacement of that one field in the document. It is one undo step, shared with the Text view, and it is saved, marked dirty and attributed to "you" exactly like typing.
- **Checking.**
  - Cells are tinted by who last changed them (the same colours as the Text view's attribution).
  - **Previous/Next change** buttons jump to the cells sessions changed.
  - When an agent rewrites the file, the table updates in place without losing your scroll position.
- **Large files** up to Alloy's 16 MB open limit open quickly and scroll at full speed. Idle costs nothing.

## Non-goals (this version)

- Formulas, types, number formatting, charts.
- xlsx, Numbers, or any non-text format.
- Inserting or deleting rows or columns.
- Copy/paste of cell ranges; fill-down.
- Filtering.
- Find inside the table. ⌘F in Table switches to Text and opens find there.
- Persisting the Text/Table choice across launches. `Presentation` is not persisted today, and Table follows it.
- Variable row heights. A cell with a newline shows its first line plus a ⏎ marker. The editor shows the whole value.

## Anti-goals

- Never rewrite the whole file on save, and never re-serialise rows the user did not touch. Quoting style, spacing, line endings and unknown oddities in untouched cells stay byte-for-byte.
- Never keep a second full copy of the file (the single-copy rule, `ByteCopiesTests`).
- Never let the Table view cost frames when idle, or raise any existing frame guard (chat 46; code 46/62/72; knownPopoverGap 0; steadyCompare 77; terminal 0/0/55; idle 0).
- No workaround for missing MetalUI Table features. Missing features are requested from MetalUI (see Dependencies) and adopted when they land.

## Approaches considered

- **A. A Table view of the same document** (chosen by the user). Cell edits become minimal range replacements on the shared `CodeBuffer`, so undo, save, dirty state, attribution, overlap warnings and agent edits all keep working.
- **B. Separate grid model, whole-file write on save.** Rejected: it loses the original formatting, attributes every line to "you", and fights concurrent agent edits.
- **C. Text editor with aligned and coloured columns (Rainbow CSV style).** Rejected as the main feature because it is not a table for checking. It may come later as a Text-view nicety.

## How it fits Alloy today (from code research)

- **Documents.**
  - One `EditorDocument` per path holds `buffer: CodeBuffer` (a rope).
  - Offsets are UTF-8 bytes.
  - `buffer.transaction { replace(range, with:) }` makes one undo step.
  - `.programmatic` is the origin for non-typing edits (LSP and replace-all use it).
  - Undo lives in the buffer, so it is shared by every view of the document.
- **Change feed.** `buffer.makeEditCursor().drain()` gives `CodeEdit`s with pre-edit UTF-8 ranges and `newText`, or `.resync(snapshot)` if it fell behind. `buffer.map(offset, from: version, bias:)` carries an offset across versions.
- **Agent and outside edits** arrive through `OutsideEdits`, `syncDocument` and `DirtyMerge`. They use `applyExternalEdits` with origin `.external`, which is not undoable.
- **Attribution.** `ProjectLedger` → `FileLedger` → `runs()` and `lineOwners()`. User edits are recorded as `.user` at save. `DiffDecorationModel.authorRuns` gives UTF-8 ranges with owners for the Text view's tints.
- **Per-tab mode.**
  - `Presentation` (`.plain`, `.inline`, `.sideBySide`, `.compareHead`, `.compareIndex`) is stored per pane and path in `Workspace.presentations`, and is not persisted.
  - The segmented picker lives in `FilePanelHeader`.
  - The render branch is `EditorGroupView.fileBody`, which chooses `CodePanel` today.
- **Limits.**
  - Files over 16 MB are truncated and open read-only.
  - Invalid UTF-8 opens read-only.
  - Binary files are refused.
- **Language.** `.csv` and `.tsv` are not known to the highlighter. `EditorDocument.language` is the lowercased extension.

## Design

### 1. Switch and default

- A new case, `Presentation.table`, is offered only when `document.language` is `csv` or `tsv`. It appears in `FilePanelHeader`'s picker as **Table**, next to the existing Text options.
- **Default.** In Code mode groups, a CSV or TSV opens in Table by default **from Phase 3**, when cells become editable. Before then, Table is offered but Text stays the default (orchestrator's call: a read-only default would confuse anyone who tries to type in a cell). The Chat pane's inline review keeps its current default.
- **Opening at a position.** Project search, diagnostics and other "open at line" actions (`Workspace.open(revealLine:)`), when they target a CSV shown in Table, reveal the row in Phases 1–2 and the cell in Phase 3+. The index maps an offset to a (row, column) pair. ⌘F still switches to Text.
- The choice is per pane and path, like the other presentations.
- `EditorGroupView.fileBody` branches to a new `TablePanel` when the presentation is `.table`.
- (Builder's call: whether Table is a peer of Plain/Inline/Side by side in one picker, or a separate Text|Table control beside it. Pick whichever keeps `FilePanelHeader` re-runs unchanged.)

### 2. Parsing and the row index (AlloyCore, no UI)

- **`CSVDialect`.**
  - The delimiter is `,` for `.csv` and tab for `.tsv`. A `.csv` whose first logical row has more `;` than `,` outside quotes uses `;`.
  - Quote is `"`.
  - The header is the first row, with a "First row is header" toggle in the header bar, default on.
  - A leading UTF-8 BOM is skipped and kept.
- **`CSVIndex`** holds one entry per logical row: the UTF-8 start offset of that row in the document. Store it compactly (for example `[UInt32]`, since files are ≤ 16 MB). Rows may span lines when quotes contain newlines.
  - Fields are parsed on demand, per visible row, from `snapshot.utf8(in: rowRange)`, into a small window cache of parsed rows. That cache is bounded and evicted by distance from the viewport.
  - There is no full copy of the file and no array of all cells.
  - The column count is the widest row seen. Ragged rows show the missing cells as empty.
- **Building it.** The first build scans the snapshot off the main actor (`CodeSnapshot` is `Sendable`) and publishes the index when done. Until then the table shows the rows scanned so far.
- **Incremental updates.** Drain a `CodeEditCursor` owned by the Table state on each `buffer.version` change, the way `DocumentServices` already fans out.
  - For each edit, rescan from the start of the row containing the edit start.
  - Stop at the first row boundary after the edit end that lands outside quotes on a shifted old boundary.
  - Shift the remaining offsets by the edit's length delta.
  - `.resync` → full rebuild off-main.
  - A quote inserted or removed can change everything after it. That case must still produce a correct index, falling back to a full rescan when the resync point is not found within a bound the builder chooses.
- **Line endings.** LF, CRLF and mixed are all accepted. The row terminator belongs to the row and is never part of a cell.
- **Lenient quoting** (orchestrator's call; agent-written CSV often has stray quotes). The same rules apply to `.csv` and `.tsv`.
  - A quote opens a quoted field only at the start of a field.
  - A quote anywhere else is a literal character.
  - A quoted field ends at a quote followed by the delimiter, the row terminator, or the end of the file.
  - If a field starts with a quote and the matching closing quote is not found within the rest of the file, or within a bound the builder picks such as 1 MB or 10,000 lines, treat the opening quote as a literal. The field then ends at the next delimiter or terminator. That keeps one stray quote from swallowing the file.
  - Rows parsed through either fallback are **flagged**: a warning glyph in the row-number column, whose hover says "This row's quoting is broken". The cells of a flagged row are read-only in Table. They can still be fixed in Text.
  - "The field was quoted" means the field's bytes start with a well-formed opening quote and end with its closing quote.

### 3. Editing a cell

- **Start.** A cell edit starts through MetalUI's cell edit mode (see Dependencies): Return, double-click or typing a character.
  - On edit begin, Alloy records the cell's UTF-8 field range and `buffer.version`.
  - The editor's initial text is the **unquoted value**.
- **Commit `(row, column, text)`.**
  1. Map the recorded range to the current version with `buffer.map`.
  2. If an edit since the begin touched that field's range, refuse the commit. Show a one-line notice ("This cell changed while you were editing. Your value was not applied.") and keep the user's typed value on the clipboard. (Builder's call: on the clipboard, or in the notice with a Retry.)
  3. Otherwise **encode** the value:
     - Quote it if it contains the delimiter, a quote, CR or LF, or has leading or trailing spaces.
     - Also quote it if the field was quoted before, so the original style is kept.
     - Double any quote characters inside it.
  4. Replace only the field's range inside one `buffer.transaction` with origin `.programmatic`.
     - Editing a missing cell in a ragged row inserts the needed delimiters at the end of that row, before its terminator.
     - A no-op edit (same value) changes nothing.
- **Escape** cancels.
- **Read-only.** If `doc.state != .editable` (over 16 MB, or invalid UTF-8), the table is read-only and the header shows the reason. A read-only buffer would ignore the replace anyway, but the UI must not offer editing.
- **Undo and redo** use the buffer's shared stack. ⌘Z in Table undoes the last cell edit, or any edit made in Text, and the table updates from the change feed.
- **Saving, the dirty dot, autosave, overlap warnings and attribution at save** are unchanged, because the edit is an ordinary buffer edit.

### 4. Checking: tints, deletions, keep and revert, and change navigation

These are the user's decisions from 2026-11-20.

- **Which changes are tinted.**
  - Table **always** shows tints, even when the Text view's presentation is Plain. Table is the checking view.
  - Changes made by sessions get that session's colour.
  - Outside changes get the neutral grey used for outside edits.
  - Your own edits are not tinted, whether saved or unsaved. The dirty dot already marks unsaved work, so there is no new "unsaved" tint.
  - A tint clears once that change is kept, which is the same rule as the Text view, where `runs()` treats kept text as settled.
- **Ownership helper.**
  - A new AlloyCore helper over `FileLedger.runs()` answers "who last changed this byte range". Do not build it on `DiffDecorationModel.authorRuns`, which covers only lines with more than one author.
  - The ledger's runs are in saved-text offsets. Map them forward to the current buffer with `buffer.map`, or rebuild them when the mapping returns nil.
  - Index the helper once per (ledger version, buffer version) pair. Answer each visible cell in O(log n).
- **Deletions are marked.**
  - Where a session removed rows, the row-number column shows a small marker on the row just after the gap, or at the end of the table. Hovering it lists the removed rows, using the ledger's removed text (the same data the Text view's `removedGroups` uses).
  - A cell a session emptied shows that session's tint. An empty field is a zero-width range, so the helper treats a deletion that touches the field's boundaries as a change to that field.
  - Removed columns produce a marker on the header.
  - Previous/Next stops at deletion markers as well as at changed cells.
- **Keep or revert one cell.**
  - When a tinted cell or a deletion marker is selected, **Keep** and **Revert** buttons appear in the header bar, with key equivalents chosen to match the Text view's keep and revert. A context menu offers the same actions once MetalUI PR C ships it.
  - **Keep** marks that cell's range as settled, so its tint clears.
  - **Revert** restores the cell's previous value from the ledger, or the removed rows for a deletion marker. It is a normal undoable buffer edit (`.programmatic`, one transaction), applied through the same encoder as a typed edit.
  - If the Text view's keep and revert act per edit record and not per range, add range-scoped variants to `FileLedger`. Keeping or reverting one cell must not settle or undo the rest of a larger agent edit.
- **Previous/Next change.** Header buttons walk changed cells and deletion markers in file order. Each one is selected and revealed with `scrollTo(TableCell)`, and by row before PR F lands. Hovering a tinted cell names who changed it, using `FileLedger.describe`.
- **Live updates.** When an agent rewrites the file, the index updates incrementally and the tints update when the ledger's version changes. The scroll position stays on the same row ordinal where that row still exists.

### 5. Display

- The row-number column is frozen with `tableFrozenColumns(1)`. Rows use the default height of 24.
- Column titles come from the header row, or `A, B, C…` when there is no header.
- Initial column widths are measured from the header and a sample of rows, clamped to a minimum and maximum (builder picks, e.g. 60–320 pt). Drag-resize arrives with MetalUI PR D.
- **Sorting** is view-only: it orders the displayed rows and never the file. It uses Finder-style, numeric-aware comparison. Rows are identified by their file ordinal. (Orchestrator's calls follow.)
  - A header click sorts or flips the order, using MetalUI PR C's ascending/descending click.
  - A **File order** button in the header bar, shown only while the table is sorted, returns to file order. This is Alloy UI and not a workaround; MetalUI's sort binding stays untouched.
  - Sorting may run one background pass that parses the sort column for every row into a temporary array of the column's values, and then builds the display permutation. This is the one allowed O(rows) pass. It runs off the main thread, and the temporary array is freed when the sort completes.
  - The order **freezes** until the next header click:
    - A row you edit stays where it is.
    - Rows an agent adds go to the end.
    - Rows an agent removes drop out.
    - While the sorted order is stale, the header shows "Sorted before changes. Click to re-sort".
- Cells are `.equatable()` and read O(1) from the window cache, following MetalUI's Table guidance. No cell overflows its box.

### 6. Performance and memory

- Cost is bounded by the viewport, never by row or column count. Idle ticks re-run nothing.
- Add a guard test in the style of `CodeModePerformanceTests`:
  - `BodyProbe` hits on the new components;
  - a steady per-frame cost for scrolling and for committing a cell edit;
  - idle costs 0;
  - opening Table adds no `GroupBar` or `FilePanelHeader` re-runs beyond the existing ones.
- Memory: a 16 MB CSV must hold the index plus the window cache only. Extend the byte-copy and memory checks.
- **Targets** (builder confirms on this Mac; release-build Bench row):
  - the first rows are visible in under 100 ms on a 16 MB file;
  - a full index in under 500 ms off the main thread;
  - a cell commit to the redrawn frame in under one frame.

### 7. Accessibility

Cell navigation and editing get MetalUI's cell accessibility when PR E lands. Until then, Table has the accessibility the table provides, and the Text view is always one click away.

## Dependencies (MetalUI Table)

Agreed with the MetalUI session on 2026-11-20. The order is C → F → D → E, and each merge commit is reported to Alloy.

- **PR C** (in progress): row selection, keys, double-click/context menu, view-only sort header click, and `ScrollViewReader.scrollTo(rowID)`.
- **PR F, cell mode** (new, for Alloy and Sift):
  - an active cell binding with a focus ring and click to set;
  - ←/→/↑/↓, Tab/⇧Tab, Return/⇧Return, Home/End and ⌘+arrows, with the active cell always revealed;
  - inline edit: start on Return, double-click or a typed character; Escape cancels; Return, Tab or click-away commits through `onCellCommit(row, column, text)`; an edit is committed if its cell scrolls out of view;
  - `scrollTo(row:column:)`;
  - a per-cell background `(row, column) -> Color?` that fills the whole cell box.
  - Alloy asked for three more: an edit-begin hook or `editingCell` binding; caller-supplied initial editor text; programmatic cancel.
  - **The agreed API** (MetalUI spec `docs/superpowers/specs/2026-11-20-table-cell-mode-design.md` on its `feat/table-f` branch):
    - `TableCell<RowID>{row, column}`, where `column` is the `TableColumnForEach` ordinal;
    - `tableActiveCell(Binding<TableCell?>)`;
    - `tableCellEditing(Binding<TableCell?>, text:, isEditable:, onCommit:)`. The binding is set when an edit begins and cleared when it ends; setting it to nil cancels. `onCommit` fires exactly once per edit, including on Return, Tab, a click away, focus loss, table removal and window close. Escape cancels.
    - `tableCellBackground((TableCell) -> Color?)`, which fills the whole cell box;
    - `ScrollViewReader.scrollTo(TableCell, anchor:)`.
  - **The editor** is a vertical field that grows to 6 lines; ⌥Return inserts a line break. It survives its cell scrolling out of view. `isEditable` returns false for read-only documents and for flagged rows.
- **PR D:** column drag-resize and reorder.
- **PR E:** accessibility, including cells.

## Phasing

1. **Phase 1 (today's Table).**
   - `CSVDialect`, `CSVIndex` with incremental updates, and the field encoder, all with thorough unit tests.
   - The `.table` presentation and switch.
   - A read-only `TablePanel` with row numbers, headers, widths and tints (the tints wait on PR F's per-cell background if content backgrounds can't fill the cell).
   - The guard and memory tests.
   - Mergeable on its own as a read-only Table.
2. **Phase 2 (after PR C):**
   - sort header click and the File order button;
   - Previous/Next change by row;
   - deletion markers;
   - row-level Keep and Revert;
   - reveal-row for "open at line".
3. **Phase 3 (after PR F):**
   - cell selection, keyboard navigation and inline editing with the commit pipeline in §3;
   - cell-level change navigation and Keep/Revert;
   - whole-cell tints;
   - Table becomes the default for CSV and TSV.
4. **Later, as MetalUI lands them:** resize (PR D) and cell accessibility (PR E).

Each phase ships when green. The user can check CSVs from Phase 1 and fix values from Phase 3.

## Testing

- **Parser and index.**
  - The RFC 4180 corpus: quotes, doubled quotes, embedded delimiters and newlines, CRLF, mixed endings, BOM, empty fields, ragged rows, a trailing newline or none, `;` detection.
  - Incremental-versus-full-rebuild equivalence over randomised edit sequences: a property test that the index after N random edits equals a fresh build.
- **Encoder.** Round trip: `parse(encode(v)) == v`. Quoting is kept when the field was quoted. Untouched bytes stay identical.
- **Edit pipeline.**
  - A commit replaces only the field range.
  - Undo and redo restore the exact bytes, and are shared with the Text view.
  - A concurrent `.external` edit to the same cell refuses the commit. One elsewhere in the file still commits at the mapped range.
  - Read-only documents refuse edits.
- **Lenient parsing.**
  - A stray mid-field quote stays literal.
  - An unmatched opening quote falls back, and the file is not swallowed.
  - Flagged rows are read-only.
  - TSV follows the same rules.
- **Checking.**
  - Session, outside and you tints follow §4.
  - Kept changes clear their tint.
  - An emptied cell is tinted.
  - Deleted rows and columns produce markers.
  - Keep and Revert of one cell leave the rest of the same agent edit untouched.
  - Revert is undoable.
- **UI and guard tests** as in §6. Use the in-memory test harness and launch no GUI apps.

## Left to the builder

- Exact component names and file layout, beyond the `TablePanel` and AlloyCore split above.
- Width heuristics.
- The cache window size.
- The incremental resync bound.
- Notice wording within Alloy's plain style.
- Where the "First row is header" toggle sits in the header bar.
