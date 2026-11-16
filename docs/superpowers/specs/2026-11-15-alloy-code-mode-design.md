# Alloy: Code mode

Date: 2026-11-15. Status: approved by the user 2026-11-15. Builds on the islands design
(`2026-11-13-alloy-islands-design.md`) and LSP v1 (`2026-11-12-alloy-lsp-design.md`).

## Intent and why

Alloy is chat-first: sessions on the left, the conversation in the middle, the file panel on the right. The user says
"Some times there are minor edits I like to make by myself", and wants a **code editor mode** they switch to "by using
segmented picker in the toolbar". In that mode the editor is the main thing and Claude stays in view: the user chose a
narrow chat column at the side "with the option to collapse the chat window", and session switching "on top of the
chat column".

The user also plans to add "a terminal pane eventually, and git integrations, along with project/repo wide search", and
"being able to do horizontal and vertical splits would be great". They agreed to this order: (1) Code mode itself,
(2) project-wide search, (3) git, (4) terminal. **This document covers (1)** and reserves room for the other three;
each of those gets its own design later.

## Approaches

1. **Rearrange the existing three islands per mode** (file tree | editor | chat). Lightest switch, reuses everything,
   but the three-island frame can't hold a split editor area, a sidebar with several tabs and a bottom terminal
   without being rebuilt later.
2. **Code mode gets its own layout, sharing the open documents with Chat mode (user's pick, after hearing about the
   terminal, git, search and splits).** Room to grow; costs a second layout to maintain.
3. **Code mode as a separate window.** Against a toolbar picker; doubles window memory and drawing. Rejected.

## Goals

1. **Mode switch.** A segmented picker `Chat | Code` in the title island, between the project name and the New Session
   / Quick Open pills (id `mode-switch`, segments `mode-chat`, `mode-code`), styled with the existing pill and
   segmented-picker shapes. ⌃⌘1 switches to Chat and ⌃⌘2 to Code **(my call; see settled call 8)**, also as View
   menu items. Chat mode is
   exactly today's layout.
2. **Code mode layout**, all inside islands with the same gutters, corners, glass and theme as today:
   ```
   ┌──────────────────────────────────────────────────────────┐
   │ ● ● ●  Project        [ Chat | Code ]        + New  ⌘P   │  title island
   ├──────────┬──────────────────────────────────┬────────────┤
   │[▤|⌕|⎇]   │ a.swift  b.swift │ c.swift        │ Session ▾  │
   │ ▾ Src    │                  │                │ …chat…     │
   │   main   │  editor group    │  editor group  │            │
   │ ● Fore   │                  │                │            │
   │          ├──────────────────┴────────────────┤            │
   │          │ (bottom panel: reserved, hidden)  │ [msg]  (↑) │
   └──────────┴───────────────────────────────────┴────────────┘
   ```
   - **Left: sidebar island.** A thin row of icon tabs at its top: Files now; Search and Git are reserved slots, not
     shown until those projects land **(my call: no dead buttons)**.
   - **Middle: editor area island** holding a split tree of editor groups, with a reserved bottom panel below it
     (for the terminal later), hidden and taking no space in this project.
   - **Right: chat column island**, collapsible.
   - Gutters between the three islands drag to resize, as today.
3. **File tree** (Files tab).
   - Shows the project's files and folders, folders first then files, each sorted case-insensitively. Folders expand
     and collapse; the expansion state is remembered per project.
   - Hides what git ignores, plus `.git`; in a folder that is not a git repo, hides FileIndex's skipped directories
     (`.build`, `node_modules` and so on). New untracked files that git does not ignore are shown **(my call)**.
   - A dot marks files changed in the project, in the same colour the changed-files list uses today, and a folder
     shows a dot when anything inside it changed **(my call)**.
   - Click opens the file in the focused editor group (the existing preview rule does not apply: every open is a real
     tab, **my call**). Keyboard: ↑↓ move, → expands, ← collapses or goes to the parent, Return opens.
   - Updates when files are added, removed or renamed on disk, from the existing file-change source (FSEvents).
   - Read-only in this project: no create, rename, delete or drag **(my call; later)**.
   - "Reveal in tree" for the active file: ⌥⌘L **(my call)**, also a View menu item.
4. **Editor groups and splits.**
   - Each group has its own tab strip and active tab, and shows a file with the same code view as today's file panel
     (highlighting, LSP diagnostics and linters, find, go to definition, the diff toggle). In Code mode a file opens as
     plain editable text; the diff toggle in the group's header still switches to the diff **(my call)**.
   - Split right (⌘\) and split down (⌥⌘\) **(my call)** split the focused group,
     opening the same file in the new group. Also "Split Right" / "Split Down" in the group's tab context menu and in
     the View menu.
   - Splits nest to any depth (a tree of horizontal and vertical splits). Dividers drag to resize.
   - Closing a group's last tab closes the group and its space goes to its neighbour; the last group never closes
     (it shows an empty "Open a file with ⌘P or from the tree" state).
   - Focusing a neighbouring group uses ⌃⌘← / ⌃⌘→ / ⌃⌘↑ / ⌃⌘↓ **(my call)**.
   - The same file open in two groups is one document: edits show in both at once, each group keeps its own scroll
     and caret (its own selection state over the shared buffer).
   - Quick Open (⌘P) opens into the focused group.
5. **Shared with Chat mode.** Both modes use the workspace's one set of open documents, so unsaved edits, undo
   history and LSP state carry across a switch. Chat mode's file panel keeps its own tab list; switching to Chat shows
   the file that was active in Code mode's focused group **(my call)**. Switching modes does not save, reload or
   reopen anything.
6. **Chat column.**
   - Shows one session: its transcript and composer (mode, model, effort, Send) as in Chat mode, narrower.
   - At its top, a session menu (`code-session-menu`) listing every session with its status dot and name, plus
     "New Session". Choosing one switches the column (and Chat mode's selected session) to it.
   - A collapse button (`code-chat-collapse`) folds the column to a thin strip at the window edge showing the current
     session's status dot (working, needs approval, idle); clicking the strip (`code-chat-expand`) or ⌘⇧C **(my
     call)** opens it again. When a session needs approval while collapsed, the strip's dot shows it; nothing pops open
     on its own **(my call)**.
7. **Remembered per project:** the mode, the sidebar and chat column widths, whether the chat column is collapsed,
   the split tree with each group's tabs and active tab, and the file tree's expanded folders. Restored on the next
   open, skipping files that no longer exist.

## Calls settled after the builder check (my calls)

1. **Remembered layout lives in a new per-project file.** Nothing persists tabs or layout today. Code mode adds
   `ui-state.json` in the project's existing Alloy data directory (next to the ledger), with a `version` field;
   unknown or newer versions are ignored and the defaults used. It holds goal 7's items only. Chat mode's tabs stay
   unpersisted, as today. A project with no saved state opens in **Chat** mode.
2. **Tab lists and document lifetime.**
   - Chat mode's file panel keeps `Workspace.tabs` / `activeTab` as they are. Each Code-mode editor group has its own
     tab list and active tab.
   - Open documents stay one shared set, kept alive while any tab list (Chat's or any group's) holds the path; closing
     a tab only closes the document (autosave watch, LSP state) when no list holds it any more.
   - Switching to Chat makes the Code-mode focused group's active file Chat's active tab, adding it to Chat's tabs if it
     isn't there. Files opened only in other Code groups don't appear in Chat's tabs.
   - Leaving a tab within a group saves it, like today's rule. Moving focus between groups doesn't save.
3. **Per-group caret, scroll, find and diff toggle.** Each group's view of a document has its own scroll position,
   find state and diff/plain toggle (`diffMode` moves from the document to the view). Caret and selection are per view:
   the workspace keeps a MetalUI `CodeSelectionState` per (pane, path), created when a pane starts holding the path
   and dropped when it releases it; each pane's `CodeView` runs on its own state (`.selectionState(_:)`), and edits
   in any view move every other view's caret. A new pane seeds its caret from the most recently focused pane showing
   the file, a split copies the source group's caret, and jumps (go to definition, quick open lines, follow edits)
   move only the target pane's caret. `OpenDocumentView` splits into a per-document part
   (highlighter, LSP, diagnostics) and a per-view part (scroll, find, diff toggle).
4. **File tree data.** The tree is built from FileIndex's cached paths (`git ls-files --cached --others
   --exclude-standard`, or the walk outside git), so it shows no empty folders. File-change events trigger a
   debounced `FileIndex.refresh()` (300 ms after the last event). "Changed" dots mean files Claude's sessions changed
   (the ledger's changed files, as the Chat sidebar shows today); git's working-tree status arrives with the git
   project.
5. **The tree waits for MetalUI's hierarchical list.** Building our own flat expand/collapse list would be a
   workaround, so the work is ordered: mode switch, layout, editor groups and splits, chat column and persistence
   first; the tree last, once MetalUI ships `OutlineGroup` / `List(children:)` / `DisclosureGroup(isExpanded:)`. Rows
   open on Return and double-click (SwiftUI's `contextMenu(forSelectionType:primaryAction:)`), single selection,
   expansion state owned by Alloy through `DisclosureGroup(isExpanded:)`.
6. **Split sizes** are persisted through MetalUI's split-view autosave, with names derived from each split node's
   stable id (`code-split-<id>`). If nested splits don't work in MetalUI, that is a gap, not a custom divider.
7. **Chat column reuses Chat mode's components.** The same `ChatView` / `ComposerView`, with state in
   `SessionUIStore` as today, so the draft and attachments survive a switch. Rebuilding the chat view on a mode
   switch is acceptable; the transcript's scroll follows today's rule (bottom while streaming). The coordination
   warnings show at the top of the chat column. The changed-files list isn't shown in Code mode; the tree's dots
   replace it.
8. **Shortcuts.**
   - ⌘1–9 keep selecting tabs: Chat's tabs in Chat mode, and the focused group's tabs in Code mode. The mode switch
     moves to ⌃⌘1 (Chat) and ⌃⌘2 (Code), replacing goal 1's ⌘1/⌘2, and group focus uses ⌃⌘←/→/↑/↓ instead of ⌘⌥ arrows.
   - ⌘W closes the focused group's tab, and ⌃Tab cycles within the focused group.
   - Opens from Quick Open, from "show in chat" links or from the command line go to the focused group in Code mode.

## Non-goals (this project)

- Search, git and terminal (projects 2 to 4). The layout reserves the sidebar tabs and the bottom panel for them.
- File operations in the tree (create, rename, delete, move), drag and drop between groups, dragging tabs to split.
- A minimap, breadcrumbs, or an outline view.
- Changing Chat mode's layout.

## Anti-goals

- **Slower typing or heavier idle.** Typing latency, memory and idle CPU in Code mode stay within noise of Chat mode
  with the same file open; the ViewRerun steady-frame guard holds in both modes. The view of the mode not shown is
  not kept alive in a way that costs per-frame work.
- **Losing work on a switch.** A mode switch never discards unsaved edits, undo history, scroll or caret.
- **A slow tree in big repos.** The tree builds from FileIndex's cached paths (up to its 100,000 cap) and only lays
  out expanded folders; opening a project never waits on the tree.

## Constraints

All Alloy constraints apply: MetalUI only, MetalUI read-only (missing pieces go to the MetalUI session as gaps with
file:line, never worked around), theme and appearance values only (no inline look values), accessibility ids on every
interactive view, zero warnings, `swift test --no-parallel`, never write `~/.claude` or `.claude/`.

**Known MetalUI gap:** MetalUI has `HSplitView` and `VSplitView` (`Sources/MetalUI/SplitView.swift:403, 449`) and
`List`, but no hierarchical list (`OutlineGroup` / `List(_:children:)` / `DisclosureGroup`). The file tree needs it;
ask MetalUI for SwiftUI's `OutlineGroup` / `List(children:)` with keyboard expand and collapse before building the
tree. Nested split views inside one island are expected to work but should be checked early.

## Left to the builder

- How the window's root switches between the two layouts, and how the Code layout's state (split tree, groups) is
  modelled alongside `Workspace.tabs` / `activeTab`.
- How an editor group reuses today's file panel code view (one component per group).
- Persistence format for the remembered layout (in the existing per-project UI state).
- Test strategy beyond the anti-goals: mode switch keeps documents, split/close rules, tree ordering and ignore rules,
  persistence round-trip, collapse and session menu.
