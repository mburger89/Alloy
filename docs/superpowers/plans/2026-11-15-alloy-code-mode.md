# Code Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `Chat | Code` mode switch in the title island; Code mode is an editor-first layout (sidebar, a split tree of
editor groups, a collapsible chat column) sharing Chat mode's open documents, remembered per project in `ui-state.json`.

**Architecture:** AlloyCore gains `WorkspaceMode`, `UIState` (the per-project file), `EditorGroup` tab lists inside a
`CodeLayout` whose shape is a pure `SplitTree`, and a document lifetime that keeps a document alive while any tab list
(Chat's `tabs` or any group's) holds its path. AlloyKit's `OpenDocumentView` splits into a per-document
`DocumentServices` (highlight feed, LSP, semantic tokens) and the per-view `OpenDocumentView` (decorations, scroll, find,
presentation), keyed by `(pane, path)`. `AlloyScreen` builds either today's `IslandRow` or the new `CodeIslandRow`,
never both. The file tree's model ships now; its view waits for MetalUI's hierarchical list.

**Tech Stack:** Swift 6, Swift Testing, AlloyCore (UI-free), AlloyKit on MetalUI (`HSplitView`/`VSplitView` with a
custom `SplitViewAutosaveStore`, segmented `Picker`, `TabStrip`, `Menu`, `CommandMenu`).

**Spec:** `docs/superpowers/specs/2026-11-15-alloy-code-mode-design.md` (its "Calls settled" section overrides goal
wording). Builds on `2026-11-13-alloy-islands-design.md` and `2026-11-12-alloy-lsp-design.md`.

## Global Constraints

- Branch `feat/code-mode` in worktree `../Alloy-code`. Each implementer works in its own sibling worktree
  (`../Alloy-code-t<N>`, branched from `feat/code-mode`), never Agent `isolation: "worktree"` (it breaks `../MetalUI`).
- MetalUI (`../MetalUI`) only, and read-only. A missing piece is a gap reported to the orchestrator with file:line (it
  goes to the MetalUI session), never worked around in Alloy.
- Theme and appearance values only: colours are `Color` tokens from `Sources/AlloyKit/Theme.swift`, geometry from
  `AppearanceStyle` or a named constant beside the view (as `alloyFilePanelIdealWidth`). No inline colour or look value.
- Accessibility ids on every interactive view; the spec's exact ids: `mode-switch`, `mode-chat`, `mode-code`,
  `code-session-menu`, `code-chat-collapse`, `code-chat-expand`. All other ids are in the table below.
- Shortcuts (settled call 8): ⌃⌘1 Chat, ⌃⌘2 Code, ⌘\ split right, ⌥⌘\ split down, ⌃⌘←/→/↑/↓ focus group, ⌘⇧C chat
  column, ⌥⌘L reveal in tree. ⌘W, ⌃Tab/⌃⇧Tab and ⌘1–9 act on Chat's tabs in Chat mode, the focused group in Code mode.
- A mode switch never saves, reloads or reopens anything; a focus move between groups never saves; leaving a tab within
  a list saves it (today's rule).
- `ui-state.json` lives in `Workspace.storeDirectory` (next to the ledger) with `version` 1; unknown or newer versions
  are ignored and defaults used; no saved state means Chat mode. Chat mode's tabs are never persisted.
- Split autosave names: `code-split-<splitNodeUUID>` for editor splits; `code-main` / `code-main-collapsed` for the
  outer row. Sizes go through MetalUI's `SplitViewAutosaveStore` into `ui-state.json`, never `UserDefaults`.
- Tests only through the lock, one filter at a time:
  `swift test --no-parallel --filter <Name>`.
  Never run `swift test` outside that lock. Known unrelated flakes: `OverlapIndexTests.unsavedTypingCostIsBounded`,
  `ByteCopiesTests.readHoldsOneCopy`.
- Zero warnings (`swift build 2>&1 | grep -c warning:` prints 0). `ViewRerunTests.steadyFrameRequests` stays 90.
- Never write `~/.claude` or any `.claude/`. No GUI app launches (no `swift run Alloy`, no `open`, no xctrace). No secrets
  in code, tests or commits. No bare `git stash`. Kill only PIDs you started.
- Commit trailers on every commit:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  `Claude-Session: <this session's link, from the orchestrator>`

### Accessibility ids (beyond the spec's six)

| Where | Id |
|---|---|
| Code-mode islands | `island-code-sidebar`, `island-code-editor`, `island-code-chat`, `island-code-chat-strip` |
| Sidebar tab row / Files tab / placeholder | `code-sidebar-tabs`, `code-sidebar-tab-files`, `code-sidebar-placeholder` (reserved: `code-sidebar-tab-search`, `code-sidebar-tab-git`) |
| Editor area / split node / group | `code-editor-area`, `code-split-<splitID>`, `code-group-<groupID>` |
| Group tab strip, tab, close | `code-group-tabs-<groupID>`, `group-<groupID>-tab-<path>`, `group-<groupID>-tab-close-<path>` |
| Group header | `code-group-path-<groupID>`, `code-group-presentation-<groupID>`, `code-group-find-<groupID>` |
| Group code view / empty state | `code-view-<groupID>`, `code-group-empty-<groupID>` |
| Session menu items | `code-session-<sessionUUID>`, `code-session-new`; the strip carries no separate status id (its status is part of the `code-chat-expand` label); column dot `code-session-status` |
| View menu | `view-mode-chat`, `view-mode-code`, `view-split-right`, `view-split-down`, `view-focus-left`, `view-focus-right`, `view-focus-up`, `view-focus-down`, `view-toggle-chat-column`, `view-reveal-in-tree` |
| Hidden global key (Code mode only) | `global-key-new-session` |
| Tab context menu (blocked) | `group-<groupID>-split-right-<path>`, `group-<groupID>-split-down-<path>` |
| File tree (blocked) | `file-tree`, `file-tree-row-<path>`, `file-tree-mark-<path>`, `file-tree-truncated` |

## Review Focus

1. Switching modes while an editor holds focus with unsaved typing, or while Chat's previous active tab is dirty: no
   write happens (blur and Chat's `activeTab` didSet must not save). Tests in Tasks 1 and 8.
2. The same file in two groups (or a group and Chat), closed in one with unsaved edits: it is saved, the document,
   undo history and LSP open stay for the other holder; closing the last holder closes it once. Tests in Tasks 3 and 4.
3. A `ui-state.json` written by a newer Alloy (or corrupt): Code-mode defaults used, the newer file is never
   overwritten this run. Test in Task 1.
4. A session edit arriving with "Follow edits" on while in Code mode: no tab opens, no focus or group changes. Test in
   Task 6.
5. Restoring a layout whose files were deleted or renamed: they are skipped, emptied groups collapse, the last group
   survives empty, the focused id is valid. Test in Task 10.

## Parallel waves, dependencies and shared files

| Wave | Tasks (run in parallel) | Needs merged first |
|---|---|---|
| A | 1 Mode + UIState v1 · 3 Document lifetime (core) · 5 SplitTree · 12 FileTreeModel | — |
| B | 2 Code layout shell (needs 1) · 4 Per-view split (needs 3) · 6 Groups core (needs 3, 5) · 8 Mode sync (needs 1, 3) | A |
| C | 7 Group views (needs 2, 4, 6) · 9 Chat column (needs 2) | B |
| D | 10 Full persistence (needs 1, 2, 6, 9) | C |
| E | 11 Performance / anti-goals (needs all of 1–10) | D |
| — | 13 File tree view: **BLOCKED** on MetalUI (needs 12, 7, 10 too) | MetalUI gap |

Merge each wave into `feat/code-mode` in task-number order and re-run the touched suites before starting the next wave.
Files more than one task edits (keep edits there small; put new code in new files):
`Sources/AlloyCore/Model/Workspace.swift` (1, 3, 6, 8, 10 — stored properties only; logic goes in new
`Workspace+*.swift` files), `Sources/AlloyCore/Editor/PanelActions.swift` (3, 6), `Sources/AlloyCore/Editor/OutsideEdits.swift`
(3, 12), `Sources/AlloyKit/RootView.swift` (1, 2, 7, 9), `Sources/AlloyKit/AppCommands.swift` (1, 7, 9, 13),
`Sources/AlloyKit/Code/CodePanel.swift` (1 blur rule, 3 mechanically, 4, 7) and `FilePanelView.swift` (3, 4, 7), `Sources/Alloy/main.swift` (10).

---

### Task 1: Mode switch and `ui-state.json` v1

**Files:**
- Create: `Sources/AlloyCore/Model/UIState.swift`, `Sources/AlloyCore/Model/Workspace+UIState.swift`,
  `Sources/AlloyKit/Code/CodeIslandRow.swift` (placeholder island row, filled by Task 2)
- Modify: `Sources/AlloyCore/Model/Workspace.swift` (stored `mode`, write-debounce state; `stopAll` flushes),
  `Sources/AlloyKit/Islands/TitleIsland.swift`, `Sources/AlloyKit/RootView.swift` (`IslandRow` vs `CodeIslandRow`),
  `Sources/AlloyKit/AppCommands.swift` (View menu), `Sources/AlloyKit/Code/CodePanel.swift` (blur save only in Chat mode)
- Test: `Tests/AlloyCoreTests/UIStateTests.swift`, `Tests/AlloyKitTests/ModeSwitchTests.swift`

**Interfaces:**
- Produces:
  - `public enum WorkspaceMode: String, Codable, Sendable { case chat, code }`
  - `public struct UIState: Codable, Equatable, Sendable { public static let currentVersion = 1; public var version: Int;
    public var mode: WorkspaceMode }` with a hand-written `init(from:)` that requires `version` and reads every other
    field with `decodeIfPresent` and a default (later tasks add fields the same way). `UIState.defaults`.
  - `public enum UIStateFile { public enum Loaded: Equatable { case missing, corrupt, newer(Int), state(UIState) };
    static func load(_ url: URL) -> Loaded; static func save(_ state: UIState, to url: URL) throws }` (atomic write;
    version 0 or missing reads as `.corrupt`).
  - `Workspace.mode: WorkspaceMode` (`public private(set)`, default `.chat`), `public func setMode(_ mode: WorkspaceMode)`,
    `var uiStateURL: URL` (`storeDirectory/ui-state.json`), `public func restoreUIState() async`,
    `func scheduleUIStateWrite()` (0.5 s after the last call, on `autosaveClock`), `func flushUIState() async`,
    `@ObservationIgnored var uiStateWriteCount`, `@ObservationIgnored var uiStateWritable` (false after `.newer`).
  - `func currentUIState() -> UIState` (later tasks extend it), `func apply(_ state: UIState)`.
  - `struct CodeIslandRow: Component` (same init as `IslandRow`), container id `code-screen` until Task 2.
- [ ] **Step 1: Failing core tests** (`UIStateTests`, `Env`/`Rig`-style workspace with `ManualClock`):
  `noFileMeansChatMode` (`restoreUIState()` with no file → `mode == .chat`, no file written);
  `modeRoundTrips` (`setMode(.code)`, advance clock 0.5 s → file has `"version":1,"mode":"code"`; a new workspace on the
  same `appSupport` restores `.code`);
  `newerVersionIsIgnoredAndKept` (file `{"version":2,"mode":"code","future":1}` → `.chat`, then `setMode(.code)` + 1 s →
  file bytes unchanged);
  `unknownKeysAreIgnored` (`{"version":1,"mode":"code","extra":{}}` → `.code`);
  `corruptFileFallsBackAndIsReplaced` (`"{"` → `.chat`; a later write produces valid v1);
  `writesAreDebounced` (`setMode` at t=0, 0.3, 0.6 → `uiStateWriteCount == 0` at t=1.0, `== 1` at t=1.1);
  `stopAllFlushesPendingWrite`.
- [ ] **Step 2: Failing UI tests** (`ModeSwitchTests`, `Rig` + `alloyWindow`):
  `pickerSitsBetweenProjectAndPills` (`mode-switch` minX > `title-project` maxX and maxX < `title-new-session` minX);
  `segmentsSwitchMode` (click `mode-code` → `mode == .code`, `code-screen` exists, `island-files` absent; click
  `mode-chat` → today's three islands);
  `menuShortcutsSwitchMode` (`installAlloyMenu`, ⌃⌘2 → `.code`, ⌃⌘1 → `.chat`; items `view-mode-code`, `view-mode-chat`);
  `chatModeIsUnchanged` (islands `island-sidebar`, `island-chat`, `island-files` frames equal before/after a round trip);
  `switchingWithFocusedDirtyEditorDoesNotSave` (focus `code-view`, type, ⌃⌘2 → `workspace.writeCount` unchanged, document
  still dirty and the same instance).
- [ ] **Step 3: Run** `swift test --no-parallel --filter "UIStateTests|ModeSwitchTests"` — FAIL (missing types).
- [ ] **Step 4: Implement.** Picker: `Picker("Mode", selection:)` with `.pickerStyle(.segmented)`, `.labelsHidden()`,
  options `Text("Chat").accessibilityIdentifier("mode-chat").tag(WorkspaceMode.chat)` and `mode-code`, styled through
  the existing `.segmentedPickerShape(style.buttonShape)`, placed after the branch label with `Spacer()`s either side;
  `TitleIsland`'s `==` stays as is (it reads `workspace.mode` through observation). `AlloyScreen` builds
  `IslandRow` or `CodeIslandRow` by `workspace.mode` (only one exists at a time). View menu:
  `CommandMenu("View")` with "Chat Mode" ⌃⌘1 and "Code Mode" ⌃⌘2. `CodePanel`'s blur save runs only when
  `workspace.mode == .chat` at blur time.
- [ ] **Step 5: Run** the filter — PASS; then `--filter "IslandsTests|TabsTests|ViewRerunTests"` — PASS.
- [ ] **Step 6: Commit** `Code mode: Chat | Code switch, View menu, ui-state.json v1`.

### Task 2: Code layout shell

**Files:**
- Create: `Sources/AlloyKit/Code/UIStateSplitStore.swift`, `Sources/AlloyKit/Code/CodeSidebarView.swift`,
  `Sources/AlloyKit/Code/ChatIslandBody.swift`
- Modify: `Sources/AlloyKit/Code/CodeIslandRow.swift`, `Sources/AlloyKit/RootView.swift` (`IslandRow` uses
  `ChatIslandBody`; `GlobalKeys` gains ⌘N in Code mode), `Sources/AlloyCore/Model/UIState.swift` (+`paneSizes`),
  `Sources/AlloyCore/Model/Workspace+UIState.swift`
- Test: `Tests/AlloyKitTests/CodeLayoutTests.swift`

**Interfaces:**
- Consumes: `Workspace.mode`, `UIState`, `scheduleUIStateWrite()` (Task 1).
- Produces:
  - `UIState.paneSizes: [String: [Double]]` (default `[:]`); `Workspace.paneSizes(forName: String) -> [Double]?`,
    `Workspace.setPaneSizes(_: [Double], forName: String)` (schedules a write).
  - `@MainActor final class UIStateSplitStore: SplitViewAutosaveStore` (`init(workspace:)`), owned as `@State` by
    `AlloyScreen` and passed down; `queriedNames: [String]` for tests.
  - `struct ChatIslandBody: Component` (`workspace`, `store`, `themes`): today's `ThemeBar` + `CoordinationNotice` +
    `ChatView`, used by `IslandRow` and Code mode's chat column.
  - `CodeIslandRow`: `HSplitView { sidebar island; editor island; chat island }.splitViewAutosaveName("code-main",
    store:)`, the editor island a `VStack` of the editor area (placeholder `Color.clear` with id `code-editor-area`
    until Task 7) and the reserved bottom panel (`if codeBottomPanelVisible`, a file-level `let codeBottomPanelVisible = false` in
    this project, so no view and no space). Widths as named constants `codeSidebarWidths`/`codeChatWidths`
    (min 180/ideal 240/max 420; min 280/ideal 340/max 560), editor min 320.
  - `CodeSidebarView`: tab row (`code-sidebar-tabs`) with one icon tab `code-sidebar-tab-files`
    (`Image(systemName: "folder")`); content `FilePanelMessage`-style text "Open a file with ⌘P" with id
    `code-sidebar-placeholder` (Task 13 replaces it). No Search or Git tab is built.
- [ ] **Step 1: Failing tests** (`CodeLayoutTests`):
  `codeModeShowsThreeIslands` (`island-code-sidebar`, `island-code-editor`, `island-code-chat` exist, in that x order;
  `island-sidebar`/`island-files` absent);
  `islandsAreInsetByTheGutterInCodeMode` (gaps between islands and window edges equal `style.gutter`, as
  `IslandsTests.islandsAreInsetByTheGutter`);
  `bottomPanelTakesNoSpace` (`code-editor-area` height == `island-code-editor` height);
  `sidebarShowsOnlyTheFilesTab` (`code-sidebar-tab-files` exists; `code-sidebar-tab-search`/`-git` absent);
  `nestedSplitViewsLayOut` (spike, a test-only `HSplitView { A; VSplitView { B; C } }` inside `.island(...)`: three
  non-empty, non-overlapping frames whose union fills the island; if it fails, stop and report the MetalUI gap);
  `paneSizesGoThroughTheWorkspace` (`UIStateSplitStore.setPaneSizes([200, 600, 300], forName: "code-main")` → a fresh
  workspace restoring the file returns them for `paneSizes(forName:)`);
  `cmdNCreatesASessionInCodeMode` (⌘N → `sessions.count` +1; in Chat mode the sidebar's ⌘N still works and fires once).
- [ ] **Step 2: Run** `swift test --no-parallel --filter CodeLayoutTests` — FAIL.
- [ ] **Step 3: Implement** the interfaces above; islands via the existing `.island(style:identifier:)`, divider as
  `IslandRow`'s (`.splitViewDivider(.hidden, thickness:)`, same padding).
- [ ] **Step 4: Run** the filter — PASS; then `--filter "IslandsTests|ChatTests|ModeSwitchTests"` — PASS.
- [ ] **Step 5: Commit** `Code mode: three-island layout shell with per-project split sizes`.

### Task 3: Document lifetime across tab lists (core)

**Files:**
- Create: `Sources/AlloyCore/Model/EditorGroup.swift` (`EditorGroup`, `CodeLayout`, `PaneID`, `Presentation`),
  `Sources/AlloyCore/Model/Workspace+Panes.swift`
- Modify: `Sources/AlloyCore/Model/Workspace.swift:1396-1498` (open/install/close/save-all through holders),
  `Sources/AlloyCore/Editor/EditorDocument.swift` (remove `diffMode`), `Sources/AlloyCore/Editor/PanelActions.swift:44-78`,
  `Sources/AlloyCore/Editor/OutsideEdits.swift:239,389` (`holds(rel)`), and mechanically
  `Sources/AlloyKit/Code/CodePanel.swift`, `Sources/AlloyKit/FilePanelView.swift` plus the tests that set
  `document.diffMode` (`CodePanelTests`, `DiagnosticPanelTests`, `SideBySideTests`) to read/write
  `workspace.presentation(of:in: .chat)`
- Test: `Tests/AlloyCoreTests/DocumentLifetimeTests.swift`

**Interfaces:**
- Produces:
  - `public enum PaneID: Hashable, Codable, Sendable { case chat; case group(UUID) }`
  - `public enum Presentation: String, Codable, Sendable { case plain, inline, sideBySide }`; `DiffMode` stays as the
    request type (`.inline → .inline`, `.sideBySide → .sideBySide`).
  - `@MainActor @Observable public final class EditorGroup: Identifiable { public let id: UUID;
    public internal(set) var tabs: [String]; public internal(set) var activeTab: String? }`
  - `@MainActor @Observable public final class CodeLayout { public internal(set) var groups: [UUID: EditorGroup];
    public internal(set) var focusedGroupID: UUID; public var focusedGroup: EditorGroup; public var chatCollapsed: Bool }`
    (`init()` makes one empty group). `Workspace.codeLayout: CodeLayout` (`let`).
  - `Workspace.defaultPane: PaneID` (`.chat` in Chat mode, `.group(focusedGroupID)` in Code mode);
    `holds(_ path: String) -> Bool`; `tabs(in: PaneID) -> [String]`; `activeTab(in: PaneID) -> String?`;
    `activate(_ path: String, in: PaneID)` (saves the left tab if dirty; loads the document if missing);
    `open(_:revealLine:mode:in pane: PaneID? = nil) async`; `open(_:selecting:in:) async`;
    `close(_ path: String, in pane: PaneID? = nil) async` (saves first as today; drops the document, autosave watch and
    `syncGeneration` only when `!holds(path)`); `requestClose(_:in:)`; `requestOpen(_:edit:line:mode:in:)`;
    `moveTab(from:to:in:)`; `presentation(of: String, in: PaneID) -> Presentation` (default `.inline` for `.chat`,
    `.plain` for a group); `setPresentation(_:of:in:)`; presentations dropped when the tab closes in that pane.
  - `saveAll()` saves every document in `documents`.
- [ ] **Step 1: Failing tests** (`DocumentLifetimeTests`, `Env` from `SaveSupport.swift`; `g` = `codeLayout.focusedGroupID`):
  `oneDocumentForAllHolders` (open `a.swift` in `.chat` and `.group(g)` → same `EditorDocument` instance);
  `documentLivesWhileAnyListHoldsIt` (close in `.chat` → `document("a.swift") != nil`; close in `.group(g)` → nil);
  `closingOneHolderSavesButKeepsTheDocument` (type in the buffer, close in `.chat` → disk has the text, document is the same
  instance and clean, `buffer.canUndo == true`);
  `groupOpenLeavesChatTabsAlone` (`open("b", in: .group(g))` → `workspace.tabs == []`, group tabs `["b"]`);
  `leavingAGroupTabSaves` (open a, b in group; dirty a; `activate("b", in: .group(g))` → disk a saved);
  `presentationIsPerPane` (`setPresentation(.sideBySide, of: "a", in: .chat)` → group's is `.plain`, chat's `.sideBySide`;
  `open("a", mode: .sideBySide, in: .group(g))` changes only the group's);
  `outsideChangeReachesAGroupOnlyDocument` (file held only by a group, changed on disk via `changes` → buffer refreshed);
  `saveAllCoversGroupOnlyDocuments`;
  `readFinishingAfterLastHolderClosedInstallsNothing` (open in group, close in group before the read returns → no document).
- [ ] **Step 2: Run** `swift test --no-parallel --filter DocumentLifetimeTests` — FAIL.
- [ ] **Step 3: Implement** the members above. `Workspace.tabs`/`activeTab` keep their declarations and didSet; the
  group path mirrors them. `followEdit` returns at once when `mode == .code` (Review Focus 4; Task 6 tests it).
- [ ] **Step 4: Run** the filter — PASS; then `--filter "WorkspaceTests|TabStateTests|AutosaveTests|OutsideEditTests|FollowEditsTests|CodePanelTests|SideBySideTests|DiagnosticPanelTests|TabsTests"` — PASS.
- [ ] **Step 5: Commit** `Documents live while any tab list holds them; presentation per pane`.

### Task 4: Per-document services and per-view state (kit)

**Files:**
- Create: `Sources/AlloyKit/Code/DocumentServices.swift`
- Modify: `Sources/AlloyKit/Code/CodePanel.swift` (`OpenDocumentView`, `CodePanelStore`, `CodePanel`),
  `Sources/AlloyKit/Code/SemanticHighlighter.swift` (several decorations), `Sources/AlloyKit/FilePanelView.swift`
  (Chat pane keys; extract `codeKeyHandlers`)
- Test: `Tests/AlloyKitTests/DocumentViewSplitTests.swift`

**Interfaces:**
- Consumes: `PaneID`, `Presentation`, `presentation(of:in:)`, `holds(_:)` (Task 3).
- Produces:
  - `@MainActor final class DocumentServices` (one per open document path): the highlight-engine feed, edit-cursor
    drain, LSP open/change/close/saved/settings, semantic tokens; `attach(_ view: OpenDocumentView)`,
    `detach(_:)` (weak list), fans each drained edit batch to every attached view (`view.record(_ edits: [CodeEdit])`
    feeds its `RowDeltaLog`), `close()`.
  - `OpenDocumentView` becomes per view: `init(document:pane:services:engine:lsp:)`, keeps `decorations`, `scroll`,
    `leftScroll`, its own `CodeViewHighlighter` over the shared engine document, diff build, `left`, tags, find,
    `selectedEdit`, `definitionMessage`; `let pane: PaneID`. `BuildKey.mode` becomes `Presentation`; `.plain` builds no
    diff and clears diff layers but still paints diagnostics.
  - `SemanticHighlighter.attach(_ decorations: CodeDecorations)` / `detach(_:)`; `apply` writes every attached
    decorations and replays the last runs to a newly attached one.
  - `struct ViewKey: Hashable { let pane: PaneID; let path: String }`; `CodePanelStore.ensureView(for: EditorDocument,
    in: PaneID)`, `view(for:in:) -> OpenDocumentView?`, `services(for path: String) -> DocumentServices?`,
    `prune(pane: PaneID, keeping: [String])`, `pruneServices(workspace:)` (closes services whose document left the
    workspace), `refreshReplaced(workspace:)`, `goToDefinition(workspace:pane:)`;
    `existingView(for:)` keeps meaning the `.chat` view; add `existingView(for:in:)`.
  - `CodePanel(workspace:store:document:view:topClear:codeViewIdentifier:)` (`"code-view"` for Chat,
    `"code-view-<groupID>"` for groups); `extension ElementGroup { func codeKeyHandlers(workspace:panel:pane:) }`
    carries ⌘F, F8/⇧F8, F12 for a pane.
- [ ] **Step 1: Failing tests** (`DocumentViewSplitTests`, `Rig`; views made through `CodePanelStore` with `.chat` and
  `.group(g)`):
  `twoViewsShareOneServices` (`services(for:)` identical for both; views and their `decorations` differ);
  `findIsPerView` (`showFind`, `setQuery("x")` on chat view → group view `findVisible == false`, its
  `decorations.findMatches.isEmpty`);
  `scrollIsPerView` (`scroll` objects differ);
  `presentationIsPerView` (chat `.sideBySide` → chat view `left != nil` after build; group view `left == nil`);
  `plainBuildsNoDiffButPaintsDiagnostics` (session edit + fake diagnostics: group view `tags.isEmpty`,
  `diagnosticsPaintCount > 0`);
  `oneLanguageServerOpenPerDocument` (fake LSP from `LSPPanelTests`' rig: two views → one `didOpen`; prune the chat view →
  no `didClose`; last holder closes → exactly one `didClose`);
  `editsReachEveryView` (type 3 bytes → both views' highlighters apply the new version).
- [ ] **Step 2: Run** `swift test --no-parallel --filter DocumentViewSplitTests` — FAIL.
- [ ] **Step 3: Implement**; behaviour of the Chat panel is unchanged.
- [ ] **Step 4: Run** the filter — PASS; then `--filter "CodePanelTests|TabsTests|SideBySideTests|LSPPanelTests|DiagnosticPanelTests|SemanticHighlightTests|DefinitionPanelTests|FilePanelTests|ViewRerunTests|MemoryProbeTests"` — PASS, `steadyFrameRequests` still 90.
- [ ] **Step 5: Commit** `Split OpenDocumentView into per-document services and per-view state`.

### Task 5: Split tree model (pure)

**Files:**
- Create: `Sources/AlloyCore/Model/SplitTree.swift`
- Test: `Tests/AlloyCoreTests/SplitTreeTests.swift`

**Interfaces:**
- Produces:
  - `public enum SplitAxis: String, Codable, Sendable { case horizontal, vertical }` (horizontal = side by side).
  - `public enum FocusDirection: Sendable { case left, right, up, down }`
  - `public indirect enum SplitTree: Codable, Equatable, Sendable { case group(UUID); case split(id: UUID, axis: SplitAxis,
    first: SplitTree, second: SplitTree) }` with
    `var groupIDs: [UUID]` (tree order), `var splitIDs: [UUID]`,
    `func splitting(_ group: UUID, axis: SplitAxis, newGroup: UUID, newSplit: UUID) -> SplitTree` (leaf becomes
    `.split(newSplit, axis, .group(group), .group(newGroup))`),
    `func removing(_ group: UUID) -> (tree: SplitTree, focus: UUID)?` (nil for the only group; the parent split is replaced
    by the sibling; focus is the sibling's first leaf if the removed one was `first`, else its last leaf),
    `func neighbour(of: UUID, _ direction: FocusDirection) -> UUID?`,
    `func pruned(keeping: Set<UUID>) -> SplitTree?`.
  - Neighbour rule: lay the tree out in the unit square with every split at 0.5; candidates are groups whose rect
    touches the source's edge on that side and overlaps its perpendicular span; pick the largest overlap, then tree order.
- [ ] **Step 1: Failing tests:** `splitRightPutsNewGroupSecond`; `splitNestsInPlace` (a→right b, b→down c gives
  `h(a, v(b, c))`); `removingCollapsesTheParent` (`h(a,b)` − b → `.group(a)`, focus a);
  `removingFocusesTheAdjacentLeaf` (`h(a, v(b,c))` − a → `v(b,c)`, focus b; − c → `h(a,b)`, focus b);
  `theOnlyGroupCannotBeRemoved`; `neighbourAcrossNesting` (`h(a, v(b,c))`: right of a → b, down of b → c, left of c → a,
  up of a → nil); `neighbourPrefersLargerOverlap` (`v(h(a, h(b,c)), d)`: up of d → a); `groupIDsInTreeOrder`;
  `prunedDropsMissingGroups` (`h(a, v(b,c))` keeping {a,c} → `h(a,c)` with the outer split's id kept);
  `codableRoundTrip`.
- [ ] **Step 2: Run** `swift test --no-parallel --filter SplitTreeTests` — FAIL.
- [ ] **Step 3: Implement** in `SplitTree.swift`.
- [ ] **Step 4: Run** the filter — PASS.
- [ ] **Step 5: Commit** `SplitTree: nested editor splits, collapse on close, directional neighbours`.

### Task 6: Editor groups in the workspace (core)

**Files:**
- Create: `Sources/AlloyCore/Model/Workspace+Groups.swift`
- Modify: `Sources/AlloyCore/Model/EditorGroup.swift` (`CodeLayout.tree`), `Sources/AlloyCore/Editor/PanelActions.swift`
  (`closeActiveTab` by mode), `Sources/AlloyCore/Model/Workspace.swift:1488-1498` (`cycleTab`, `selectTab` by mode)
- Test: `Tests/AlloyCoreTests/EditorGroupsTests.swift`

**Interfaces:**
- Consumes: Task 3's panes and `close(_:in:)`; Task 5's `SplitTree`.
- Produces: `CodeLayout.tree: SplitTree` (starts `.group(initial)`); `Workspace.splitFocused(_ axis: SplitAxis)` (new
  group opening the focused group's active file, focused; no-op when that group has no active tab);
  `focusGroup(_ direction: FocusDirection)`, `focusGroup(id: UUID)` (neither saves); closing a group's last tab removes
  the group (unless it is the only one) and focuses `removing(_:).focus`; `closeActiveTab()`, `cycleTab(_:)`,
  `selectTab(number:)` act on `defaultPane`. Every change calls `scheduleUIStateWrite()` (Task 10 fills the state).
- [ ] **Step 1: Failing tests** (`EditorGroupsTests`, `Env`, `setMode(.code)`):
  `splitRightOpensTheSameDocumentInANewFocusedGroup` (tree `h(g0, g1)`, `focusedGroupID == g1`, both active `a`, one document);
  `splitDownUsesTheVerticalAxis`; `splittingAnEmptyGroupDoesNothing`;
  `closingTheLastTabClosesTheGroupAndFocusesTheNeighbour`; `nestedCloseCollapsesToTheSibling` (`h(a, v(b,c))`, close c's
  only tab → `h(a,b)`, focus b); `theLastGroupStaysEmpty` (`groups.count == 1`, tabs `[]`, `activeTab == nil`);
  `focusMovesDoNotSave` (dirty buffer in g0, `focusGroup(.right)` → `writeCount` unchanged);
  `cmdWClosesTheFocusedGroupsTab` and `ctrlTabCyclesWithinTheFocusedGroup` and `cmdNumberSelectsInTheFocusedGroup`
  (`workspace.tabs`/`activeTab` untouched);
  `requestOpenGoesToTheFocusedGroup` (Quick Open's and chat links' path); `commandLineOpenGoesToTheFocusedGroup`
  (`openFilePath = "b"` in Code mode);
  `followEditsDoesNothingInCodeMode` (`followEdits` on, session edit → no group or Chat tab change, focus unchanged).
- [ ] **Step 2: Run** `swift test --no-parallel --filter EditorGroupsTests` — FAIL.
- [ ] **Step 3: Implement**; `openFilePath`'s setter routes through `open(_:in: defaultPane)`.
- [ ] **Step 4: Run** the filter — PASS; then `--filter "DocumentLifetimeTests|WorkspaceTests|FollowEditsTests|TabsTests"` — PASS.
- [ ] **Step 5: Commit** `Editor groups: split, close-collapse, focus moves, keys follow the focused group`.

### Task 7: Editor group views and split tree view

**Files:**
- Create: `Sources/AlloyKit/Code/EditorAreaView.swift` (`EditorAreaView`, recursive `SplitNodeView`),
  `Sources/AlloyKit/Code/EditorGroupView.swift` (`EditorGroupView`, `GroupTabStrip`, `GroupHeader`)
- Modify: `Sources/AlloyKit/Code/CodeIslandRow.swift` (editor area), `Sources/AlloyKit/AppCommands.swift` (split and
  focus items), `Sources/AlloyKit/FilePanelView.swift` (share `FileTabStrip.titles`, `FilePanelNotice`, message views)
- Test: `Tests/AlloyKitTests/EditorGroupViewTests.swift`

**Interfaces:**
- Consumes: Task 4's `CodePanelStore` pane API, `CodePanel(...codeViewIdentifier:)`, `codeKeyHandlers`; Task 6's
  workspace group API; Task 2's `UIStateSplitStore`.
- Produces: `SplitNodeView(node: SplitTree, ...)` returning `AnyElement`: `.split` →
  `HSplitView`/`VSplitView { first; second }.splitViewAutosaveName("code-split-\(id)", store: splitStore)` with id
  `code-split-<id>`; `.group` → `EditorGroupView`. `EditorGroupView` shows the group's glass bar (tab strip + header, as
  `FilePanelBar`), notices, Quick Open's field at the top of the focused group while showing, `CodePanel` for the active
  document, or "Open a file with ⌘P or from the tree" (`code-group-empty-<id>`). Focus: code view gaining focus or a tab
  click calls `focusGroup(id:)`. The focused group's selected tab uses `.selectedTabFill(.color(Color.glassRim))`, others
  `.clear`. `GroupHeader`'s presentation picker: segmented `Plain | Inline | Side by side`
  (`code-group-presentation-<id>`). View menu: Split Right ⌘\, Split Down ⌥⌘\, Focus Left/Right/Up/Down Group ⌃⌘arrows,
  all `.disabled(workspace?.mode != .code)`.
- [ ] **Step 1: Failing tests** (`EditorGroupViewTests`, `Rig`, `setMode(.code)`, `installAlloyMenu`):
  `cmdBackslashShowsTwoGroupsOnOneFile` (`code-group-<g0>`, `code-group-<g1>`, `code-view-<g0>`, `code-view-<g1>` exist,
  side by side);
  `optionCmdBackslashNestsDown` (three groups, frames non-overlapping inside `island-code-editor`);
  `typingInOneGroupEditsTheSharedBuffer` (type in `code-view-<g1>` → `document(a).buffer` changed; g0's view shows the
  same buffer, its `scroll` object distinct);
  `closingTheLastTabCollapsesTheGroup` (click `group-<g1>-tab-close-a.swift` → `code-group-<g1>` gone, g0 fills the area);
  `focusShortcutsMoveFocus` (⌃⌘← / ⌃⌘→ change `focusedGroupID`);
  `emptyStateShowsInTheLastGroup`;
  `splitNamesFollowNodeIDs` (`splitStore.queriedNames.contains("code-split-\(id)")` for the tree's split id);
  `quickOpenOpensIntoTheFocusedGroup` (⌘P, type, Return → focused group's active tab, Chat tabs empty);
  `presentationPickerIsPerGroup` (pick Side by side in g1 → `presentation(of:in: .group(g1)) == .sideBySide`, g0 `.plain`);
  `f12GoesToDefinitionInTheFocusedGroup` (fake LSP target opens in the focused group).
- [ ] **Step 2: Run** `swift test --no-parallel --filter EditorGroupViewTests` — FAIL.
- [ ] **Step 3: Implement** the views above.
- [ ] **Step 4 (BLOCKED sub-step): tab context menu** "Split Right" / "Split Down" (`group-<id>-split-right-<path>`,
  `group-<id>-split-down-<path>`) waits for a per-tab context menu on MetalUI `TabStrip`
  (`Sources/MetalUI/TabStrip.swift:177-240` has none). Report the gap; do not add a strip-wide menu.
- [ ] **Step 5: Run** the filter — PASS; then `--filter "CodeLayoutTests|TabsTests|FilePanelTests|QuickOpenTests"` — PASS.
- [ ] **Step 6: Commit** `Code mode: editor groups with nested resizable splits`.

### Task 8: Mode-switch sync to Chat's tabs

**Files:**
- Modify: `Sources/AlloyCore/Model/Workspace+UIState.swift` (`setMode`), `Sources/AlloyCore/Model/Workspace.swift`
  (an internal `setChatActive(_:saving:)` that bypasses the didSet save)
- Test: `Tests/AlloyCoreTests/ModeSyncTests.swift`

**Interfaces:**
- Consumes: `setMode` (Task 1), panes and `codeLayout` (Task 3).
- Produces: `setMode(.chat)` makes the focused group's active file Chat's `activeTab`, appending it to `tabs` if absent,
  without saving; nothing when that group is empty. `setMode(.code)` with a layout of one empty group opens Chat's
  active tab in it (ruling: the first switch is not an empty editor). Neither reads disk.
- [ ] **Step 1: Failing tests:** `switchToChatShowsTheFocusedGroupsFile`; `existingChatTabIsNotDuplicatedOrMoved`;
  `otherGroupsFilesStayOutOfChatTabs`; `emptyFocusedGroupLeavesChatAsIs`; `firstSwitchToCodeSeedsTheEmptyGroup`;
  `switchToChatDoesNotSaveChatsPreviousTab` (Chat's active `x` dirty, focused group's `y` → after `.chat`, `writeCount`
  unchanged, `x` still dirty); `switchesDoNotSaveReadOrReopen` (code → chat → code: `writeCount`, `outsideReadCount`,
  document instances, buffer versions and `canUndo` unchanged).
- [ ] **Step 2: Run** `swift test --no-parallel --filter ModeSyncTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter — PASS; then `--filter "UIStateTests|DocumentLifetimeTests|TabStateTests"` — PASS.
- [ ] **Step 5: Commit** `Mode switch shows Code's focused file in Chat without saving`.

### Task 9: Chat column

**Files:**
- Create: `Sources/AlloyKit/Code/CodeChatColumn.swift` (`CodeChatColumn`, `SessionMenuHeader`, `CollapsedChatStrip`,
  `statusDotColor(_:)`)
- Modify: `Sources/AlloyKit/Code/CodeIslandRow.swift` (collapsed: `HSplitView` of sidebar and editor with name
  `code-main-collapsed`, the strip island outside it at the trailing edge), `Sources/AlloyKit/AppCommands.swift`
  (⌘⇧C), `Sources/AlloyCore/Model/EditorGroup.swift` (`chatCollapsed` setter schedules a write)
- Test: `Tests/AlloyKitTests/CodeChatColumnTests.swift`

**Interfaces:**
- Consumes: `ChatIslandBody` (Task 2), `CodeLayout.chatCollapsed` (Task 3), `SessionUIStore` (unchanged).
- Produces: `CodeChatColumn` = `SessionMenuHeader` over `ChatIslandBody` (coordination warnings already at its top).
  `SessionMenuHeader`: a status dot (`code-session-status`) and `Menu { … } label: { name }` (`code-session-menu`) listing
  each session as `Button("<name> — <statusWord>")` (`code-session-<uuid>`) choosing `selectedSessionID`, a `Divider`,
  `Button("New Session")` (`code-session-new`); a collapse button `code-chat-collapse` (`Image(systemName:
  "sidebar.right")`). `CollapsedChatStrip`: island `island-code-chat-strip`, width `style.gutter * 4` (named constant),
  the current session's dot (decoration; its status is part of the `code-chat-expand` label), whole strip a button `code-chat-expand`; it never opens itself.
  `statusDotColor(_ session: Session) -> Color`: `hasPendingPermission` or `.awaitingPermission` → `.warningInk`;
  `.working`/`.starting` → `Color(ColorToken.accent)`; `.exited`/`.failedToLaunch` → `.errorInk`; else `.mutedInk`.
  View menu "Toggle Chat Column" ⌘⇧C (`view-toggle-chat-column`, disabled outside Code mode).
- [ ] **Step 1: Failing tests:** `columnShowsTheSelectedSession` (composer and transcript of A inside `island-code-chat`);
  `sessionMenuSwitchesSessions` (choose `code-session-<B>` → `selectedSessionID == B`, Chat mode shows B too);
  `sessionMenuNewSession` (`code-session-new` → one more session, selected); `draftSurvivesAModeSwitch` (type in the
  composer, ⌃⌘1 then ⌃⌘2 → same draft text and attachments);
  `collapseAndExpand` (`code-chat-collapse` → `island-code-chat` gone, `island-code-chat-strip` at the trailing edge, editor
  island wider; `code-chat-expand` → back; ⌘⇧C toggles both ways);
  `stripDotShowsNeedsApprovalWithoutOpening` (collapsed; scripted transport sends a permission request → strip dot colour
  token is `warningInk`, column still collapsed);
  `coordinationWarningsShowAtTheTop` (a scripted overlap warning appears above the transcript in the column);
  `noChangedFilesListInCodeMode` (no `changed-file-*` ids).
- [ ] **Step 2: Run** `swift test --no-parallel --filter CodeChatColumnTests` — FAIL.
- [ ] **Step 3: Implement.** MetalUI menus cannot show an image item (`Sources/MetalUI/MenuContent.swift:55-64`: no
  `Label`/image items), so items carry the status word; report the gap so the dot can replace it later.
- [ ] **Step 4: Run** the filter — PASS; then `--filter "ChatTests|ComposerTests|CoordinationWarningsTests|CodeLayoutTests"` — PASS.
- [ ] **Step 5: Commit** `Code mode: chat column with session menu and collapse strip`.

### Task 10: Remembered layout in `ui-state.json`

**Files:**
- Modify: `Sources/AlloyCore/Model/UIState.swift`, `Sources/AlloyCore/Model/Workspace+UIState.swift`,
  `Sources/Alloy/main.swift` (`await workspace.restoreUIState()` before `openFilePath`, in the existing `Task`/startup path)
- Test: `Tests/AlloyCoreTests/UIStateTests.swift` (extend), `Tests/AlloyKitTests/CodeLayoutTests.swift` (extend)

**Interfaces:**
- Consumes: Tasks 1, 2 (`paneSizes`), 6 (`CodeLayout.tree`, groups), 9 (`chatCollapsed`).
- Produces: `UIState` fields (all `decodeIfPresent`): `chatCollapsed: Bool`, `layout: CodeLayoutState?`,
  `expandedFolders: [String]`, with `public struct CodeLayoutState: Codable, Equatable, Sendable { var tree: SplitTree;
  var groups: [GroupState]; var focused: UUID }`, `struct GroupState: Codable, Equatable, Sendable { var id: UUID;
  var tabs: [String]; var active: String? }`. Restore: files checked off the main actor; missing paths dropped; a group
  left without tabs is pruned (`SplitTree.pruned`) unless none remain (then one empty group); a missing `active` becomes
  the first tab; a missing `focused` the first group; only each group's active document is loaded, the rest on
  `activate`. `Workspace.expandedFolders: Set<String>` (written by Task 13's tree).
- [ ] **Step 1: Failing tests:** `layoutRoundTrips` (split + tabs + active + focus + collapsed + sizes + expanded, new
  workspace on the same `appSupport` restores equal values); `missingFilesAreSkipped`;
  `groupEmptiedByMissingFilesCollapses`; `allFilesMissingLeavesOneEmptyGroup`; `chatTabsAreNotPersisted`;
  `restoredSplitKeepsItsAutosaveSizes` (sizes under `code-split-<id>` come back for the restored id);
  `commandLineFileOpensInTheRestoredMode` (saved Code mode + `openFilePath = "b"` → focused group has b);
  `restoreLoadsOnlyActiveDocuments` (two tabs per group → `documents.count == groups.count` until `activate`).
- [ ] **Step 2: Run** `swift test --no-parallel --filter "UIStateTests|CodeLayoutTests"` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter — PASS; then `--filter "EditorGroupsTests|ModeSyncTests|EditorGroupViewTests"` — PASS.
- [ ] **Step 5: Commit** `Remember Code mode's layout, groups and widths per project`.

### Task 11: Performance and anti-goal verification

**Files:**
- Modify: `Tests/AlloyKitTests/ViewRerunTests.swift`, `Tests/AlloyKitTests/MemoryProbeTests.swift`
- Create: `Tests/AlloyKitTests/CodeModePerformanceTests.swift`
- Source changes only where a test fails (equatable splits, `BodyProbe.hit` names); never raise the guard.

**Interfaces:**
- Consumes: everything above. Adds `BodyProbe.hit` in `CodeIslandRow`, `EditorAreaView`, `EditorGroupView`,
  `GroupHeader`, `GroupTabStrip`, `CodeChatColumn`, `CodeSidebarView` if Tasks 2–9 did not.
- [ ] **Step 1: Tests:**
  `typingInCodeModeHoldsTheSteadyFrameGuard` (one group, same warm-up as `typingLeavesSidebarScreenAndChatAlone`; every
  counted frame ≤ `steadyFrameRequests + 2`, total ≤ `steadyFrameRequests * 20 * 102 / 100`; `CodeIslandRow`,
  `EditorAreaView`, `CodeChatColumn`, `CodeSidebarView`, `TitleIsland`, `IslandBackdrop` re-run 0; `GroupHeader`,
  `GroupTabStrip` ≤ 1);
  `idleTicksInCodeModeRerunNothing`;
  `theHiddenModeBuildsNothing` (Code mode, 20 ticks: `IslandRow`, `SidebarView`, `FilePanelView` 0 hits; Chat mode:
  `CodeIslandRow`, `EditorGroupView`, `CodeChatColumn` 0 hits);
  `aSwitchKeepsCaretScrollFindAndUndo` (Chat: caret, scroll offset, open find, dirty text; code → chat round trip: all
  equal, `canUndo`, `writeCount` unchanged);
  `twoGroupsOnOneFileCost` (print `FRAMEWORK` for one and two groups; expect two ≤ one + one group's code-view requests,
  printed as the delta);
  `MemoryProbeTests.codeModeFullOpen` (same file as `fullOpen`, Code mode: resident delta ≤ 1.05 × Chat's).
- [ ] **Step 2: Run** `swift test --no-parallel --filter "ViewRerunTests|CodeModePerformanceTests|MemoryProbeTests"` — PASS, or fix the source until it does
  (report each fix and the before/after numbers).
- [ ] **Step 3: Full suite** with the same lock and `--filter "AlloyCoreTests|AlloyKitTests|AlloyLSPTests|AlloyHighlightTests"` — PASS
  except the two known flakes; `swift build` warning count 0.
- [ ] **Step 4: Hand-off:** report the `FRAMEWORK` lines; the orchestrator (not the implementer) runs alloy-bench typing,
  idle CPU and memory in Chat vs Code with the same file open.
- [ ] **Step 5: Commit** `Code mode: steady-frame guard, hidden-mode and switch anti-goal tests`.

### Task 12: File tree model (pure; runs now)

**Files:**
- Create: `Sources/AlloyCore/Model/FileTreeModel.swift`, `Sources/AlloyCore/Model/Workspace+FileTree.swift`
- Modify: `Sources/AlloyCore/Model/FileIndex.swift` (subtract `git ls-files --deleted -z`; `isTruncated`),
  `Sources/AlloyCore/Editor/OutsideEdits.swift:204` (one call into the debounce for non-`.git` paths),
  `Sources/AlloyCore/Model/Workspace.swift` (stored debounce state)
- Test: `Tests/AlloyCoreTests/FileTreeModelTests.swift`, `Tests/AlloyCoreTests/FileIndexTests.swift` (extend)

**Interfaces:**
- Produces:
  - `public struct FileTreeEntry: Hashable, Sendable { public let path: String; public let name: String; public let
    isFolder: Bool }`; `public struct FileTreeRow: Hashable, Sendable { public let entry: FileTreeEntry; public let depth: Int }`
  - `public struct FileTreeSnapshot: Sendable, Equatable { public static func build(paths: [String], truncated: Bool) ->
    FileTreeSnapshot; public func children(of folder: String) -> [FileTreeEntry] /* "" is the root */;
    public func parent(of path: String) -> String?; public let truncated: Bool }` — folders first, then files, each
    ordered by `name.lowercased()` then `name`; folders only from file paths (no empty folders).
  - `public enum ChangeMark: Hashable, Sendable { case author(Author), mixed }`;
    `FileTreeSnapshot.marks(_ changed: [ChangedFile]) -> [String: ChangeMark]`: a file's mark is its last author; a
    folder's is the common author of every marked descendant, else `.mixed` (drawn `.mutedInk`).
  - `@MainActor @Observable public final class FileTreeModel { public private(set) var snapshot: FileTreeSnapshot;
    public var expanded: Set<String>; public func visibleRows() -> [FileTreeRow] /* expanded folders only */;
    public func reveal(_ path: String) -> Int? /* expands ancestors, returns the row */; func update(paths: [String],
    truncated: Bool) async /* builds off main */ }`; `Workspace.fileTree: FileTreeModel`;
    `Workspace.scheduleFileTreeRefresh()` — 0.3 s after the last file event on `autosaveClock`, only in Code mode;
    `setMode(.code)` refreshes at once; `@ObservationIgnored var fileTreeRefreshCount`.
- [ ] **Step 1: Failing tests:** `foldersFirstThenFilesCaseInsensitive` (`["b.txt","A.txt","src/z.swift","Docs/x.md","a/y"]`
  → root `[a, Docs, src, A.txt, b.txt]`); `onlyExpandedFoldersAreLaidOut`; `revealExpandsAncestors`;
  `folderMarkedWhenADescendantChanged` (`src/deep/x.swift` by S → `src`, `src/deep`, the file all `.author(S)`);
  `mixedAuthorsMarkTheFolderMixed`; `refreshIsDebounced300ms` (events at t=0, 0.2, 0.4 → count 0 at 0.69, 1 at 0.71);
  `noRefreshInChatMode`; `aHundredThousandPathsBuildOffMain` (100,000 synthetic paths build < 2 s; nothing expanded →
  `visibleRows().count == root children`); `truncationIsReported`.
  `FileIndexTests`: `deletedTrackedFileIsNotListed`, `untrackedUnignoredFileIsListed`, `ignoredFileIsHidden`,
  `gitDirectoryNeverListed`, `walkSkipsBuildAndNodeModules` (non-git folder).
- [ ] **Step 2: Run** `swift test --no-parallel --filter "FileTreeModelTests|FileIndexTests"` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter — PASS; then `--filter "QuickOpenTests|OutsideEditTests"` — PASS.
- [ ] **Step 5: Commit** `File tree model from FileIndex with change marks and debounced refresh`.

### Task 13: File tree view — BLOCKED

**Task 13 must:**
- call `workspace.fileTreeViewAppeared()` when the tree view is shown and `fileTreeViewDisappeared()` when it goes away (nothing else turns `fileTreeActive` on, so until then no scan runs);
- call `workspace.noteExpandedFoldersChanged()` on each folder toggle, so the open folders are saved;
- add the ⌥⌘L `view-reveal-in-tree` menu item.

> MetalUI notes (2026-11-15, PR #317): use `List(selection: Binding<String?>) { ForEach(roots) { NodeRow(...) } }`; keep every `if`/`Section` inside the `NodeRow` Component (a bare `if` or `Section` directly in the List makes it eager and unselectable). Reveal = expand ancestors + select + `scrollTo` in one transaction; the row is fully in view on the next frame (MetalUI divergence 1085). Open rows with `.contextMenu(forSelectionType: String.self, menu: { _ in … }, primaryAction: { paths in … })` (PR #320): Return opens the selection, double-click opens the row; a different selection type makes it inert.

**BLOCKED until MetalUI ships** `OutlineGroup` / `List(_:children:selection:)` / `DisclosureGroup(isExpanded:)` with
keyboard expand/collapse and `contextMenu(forSelectionType:primaryAction:)` (none exist in `../MetalUI/Sources/MetalUI`
today). Do not build a flat expand/collapse list in the meantime.

**Files:**
- Create: `Sources/AlloyKit/Code/FileTreeView.swift`
- Modify: `Sources/AlloyKit/Code/CodeSidebarView.swift` (replaces `code-sidebar-placeholder`), `Sources/AlloyKit/AppCommands.swift` (⌥⌘L)
- Test: `Tests/AlloyKitTests/FileTreeViewTests.swift`

**Interfaces:**
- Consumes: `FileTreeModel`, `ChangeMark` (Task 12); `open(_:in: defaultPane)` (Task 6); `expandedFolders` (Task 10).
- Produces: `FileTreeView` (`file-tree`): single selection; rows `file-tree-row-<path>` with a mark dot
  `file-tree-mark-<path>` coloured by `authorColor(_:sessions:)` or `.mutedInk` for `.mixed`; expansion owned by
  `FileTreeModel.expanded` through `DisclosureGroup(isExpanded:)`, mirrored to `expandedFolders`; Return and double-click
  open the file in the focused group as a real tab (primary action); ↑↓ move, → expands, ← collapses or goes to the
  parent; a `file-tree-truncated` note when `snapshot.truncated`. View menu "Reveal in Tree" ⌥⌘L
  (`view-reveal-in-tree`): shows the Files tab, `reveal(activePath)`, selects and scrolls to the row.
- [ ] **Step 1: Failing tests:** `treeShowsFoldersFirst`; `expandAndCollapseByKeyboard`; `returnOpensInTheFocusedGroup`;
  `doubleClickOpensAsARealTab`; `marksShowForChangedFilesAndFolders`; `expansionIsRemembered`;
  `revealSelectsTheActiveFile`; `onlyExpandedRowsAreBuilt` (10,000-file fixture, nothing expanded → row count ==
  root children).
- [ ] **Step 2: Run** `swift test --no-parallel --filter FileTreeViewTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter — PASS; then `--filter "ViewRerunTests|CodeModePerformanceTests|CodeLayoutTests"` — PASS.
- [ ] **Step 5: Commit** `Code mode: file tree in the sidebar`.

## MetalUI gaps to forward

1. Hierarchical list: `OutlineGroup` / `List(children:)` / `DisclosureGroup(isExpanded:)` with keyboard and
   `contextMenu(forSelectionType:primaryAction:)` — blocks Task 13.
2. Per-view selection over a shared `CodeBuffer` (`MetalUICodeBuffer/CodeBuffer.swift:153`): two groups on one file share
   a caret until then.
3. Menu items with an image or `Label` (`Sources/MetalUI/MenuContent.swift:55-64`): the session menu's status dots.
4. Per-tab context menu on `TabStrip` (`Sources/MetalUI/TabStrip.swift:177-240`): "Split Right / Split Down" on a tab.
5. Split dividers are not accessibility elements (`Sources/MetalUI/SplitView.swift:275`): no id or keyboard resize for
   `code-split-*` dividers.
6. If Task 2's `nestedSplitViewsLayOut` spike fails: nested `HSplitView`/`VSplitView` in one island.
   Update 2026-11-15: MetalUI verified depth-5 nests and per-level autosave names (branch test/nested-split-views).
   One bug: a bare nested split (no frame) stays at its ideal width; MetalUI is fixing SplitLayout.sizeThatFits.
   Task 7 must not add `.frame(maxWidth: .infinity…)` as a workaround; it waits for that fix to merge.

## Rulings on spec gaps

- Diff toggle (goal 4, call 3): one segmented `Plain | Inline | Side by side` per group; groups start `Plain`, Chat
  starts `Inline` as today. Presentation is not persisted.
- The tree opens rows on Return and double-click (call 5 overrides goal 3's "click opens").
- First switch to Code with one empty group opens Chat's active tab there.
- In Code mode "Follow edits" does nothing (no tab or focus changes while the user edits).
- Splitting an empty group does nothing. Code mode keeps ⌘N through a hidden global key; the chat column keeps
  `ThemeBar` with the coordination warnings.
- Until Task 13, the Files tab shows "Open a file with ⌘P". A newer `ui-state.json` is never overwritten; a corrupt one
  is replaced on the next write.
- File change marks: a file's colour is its last author's; a folder with mixed authors uses `mutedInk`.
