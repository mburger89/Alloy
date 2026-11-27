# New File (⌘N): design

## Why

The user asked for a regular "New File" on ⌘N, like every other Mac editor. Decisions they made (2026-11-26):
- ⌘N is New File everywhere. New Session moves to ⇧⌘N.
- New File opens an empty "Untitled" tab right away. The first ⌘S asks where to save it.
- Closing the tab or quitting with text in an Untitled tab asks Save… / Don't Save / Cancel. An empty Untitled tab
  closes without asking.

## Goals

- File › New File (⌘N) opens an empty, editable, active Untitled tab in the focused code group. Further ones are
  "Untitled 2", "Untitled 3", and so on.
- ⌘S (and Save As…) on an Untitled tab opens the save dialog in the project folder, with "Untitled" as the default name.
  Saving inside the project turns the tab into that file in place: same group, same index, same text, still active.
  Cancel leaves the tab as it is.
- Before it is saved, an Untitled tab touches nothing that expects a file: autosave, git, LSP, the edit ledger, the
  outside-edit watcher, search, and the saved tab layout all skip it.

## Non-goals

- Keeping Untitled text across restarts (the user chose the prompt instead).
- "Save changes?" prompts for real files. They keep autosaving as today.
- Picking a language for an Untitled buffer. It is plain text until saved.

## Anti-goals

- Losing typed text without the user choosing Don't Save.
- An Untitled entry in `ui-state.json`, the ledger, git status, or an LSP `didOpen`.
- ⌘N making both a file and a session, or ⇧⌘N clashing with anything (`ShortcutClashes` stays clean).

## Approaches

1. **Reserved key, converted on save. Chosen.** An Untitled document is keyed `untitled:<n>` in `tabs`, `documents`
   and the per-path tables. A single `isUntitled` check (on the key or the document) guards autosave, git, LSP `wants`,
   the ledger, the watcher, search and the layout save. On first save, the text is written to the chosen URL, the real
   file is opened, and its tab replaces the Untitled tab in place. That is the same in-place tab replacement Save As uses
   (feat/menu-bar). Then the Untitled document is dropped. Nothing gets re-keyed.
2. **Mutable `path`, re-keyed on save.** Rejected. Path is the identity in about 15 tables (documents, tabs, layout
   groups, presentations, selections, folds, saving, ledger…). Re-keying all of them is the riskiest change for the
   smallest gain.
3. **Ask for a name first, then create the file.** Rejected because it contradicts the user's choice.

## Decisions (calls I made, for the user to check)

- **Save location outside the project:** the file is written, the Untitled tab closes, and the file opens the way
  Open… opens an outside file.
- **Where it opens:** the focused code group. In Chat mode it switches to the code view, the same as Open… does.
- **The prompt:** Save… runs the save dialog, and cancelling the dialog cancels the close. Quit and window close ask once
  per non-empty Untitled tab, in tab order. Cancel at any point stops the quit or close. If MetalUI has no alert or
  confirmation API that fits, forward the gap to MetalUI. Don't build a workaround.
- **Dirty marker:** a non-empty Untitled tab shows the usual unsaved dot.

## Left to the builder

The exact helper names, where the `isUntitled` check lives, and the order of the guards.
