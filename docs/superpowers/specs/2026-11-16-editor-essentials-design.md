# Alloy: Editor essentials (multiple cursors, code folding, keyboard shortcut settings)

Date: 2026-11-15. Status: draft for the user's review, revised after a builder check. Builds on Code mode
(`2026-11-15-alloy-code-mode-design.md`), LSP v1 (`2026-11-12-alloy-lsp-design.md`) and the per-view
`CodeSelectionState` work.

## Intent and why

Code mode exists so the user can make "minor edits I like to make by myself". Three things every editor they would
compare Alloy with already has are missing: **multiple cursors** (option-click, ⌘D, ⌃⇧↑/↓, option-drag box
selection, Escape to collapse), **code folding** (by indentation, tree-sitter and LSP folding ranges, gutter chevrons,
fold all / unfold all, folds kept per view), and **keyboard shortcut settings** (see and rebind every command's
shortcut in Settings, with conflicts flagged, stored in Alloy's own settings and shared with the command palette's
registry). The bar is the standing goal: "MetalUI and Alloy run as lite and fast as possible without giving up
quality". None of the three may make typing, hovering or idle frames cost more.

## What exists today (checked against the source)

- `CodeBuffer.replaceSelections(with:)` already edits **every** selection in one transaction, and `CodeSelectionState`
  keeps a normalized `[CodeSelection]`. So typing, delete and paste with many selections work in the model.
- The view does not support multiple carets yet. `CodeEditSession` sets `selectionState.selections = [one]` on every
  click, drag and arrow-key motion, so any motion collapses to one caret. `CodeViewPlan.caretPosition()` returns one
  caret, so only one is drawn. `onTextClick(modifiers:)` (default `.primary`) consumes the press ("no caret move, no
  selection change"); a press with extra modifiers behaves as it does without the handler.
- `CodeEditing.command(for:platform:)` (MetalUI) decides which keys the code view claims. It **declines** ⌥⌘ + arrow
  on macOS, ⌃ + ↑/↓ (any non-shift modifier on up/down), ⌘D, ⇧⌘L and ⌥⌘D, and it does not handle Escape. So every
  chord this spec adds as a default reaches the command stage today; none collides with built-in motion. It claims
  ⌘A/C/X/V/Z/⇧Z/G/⇧G, arrows, Home/End, PageUp/Down, Delete variants, Return and Tab.
- Pane identity: `PaneID` is `.chat` or `.group(UUID)`, and the UUID is the same id `CodeLayoutState.groups[].id`
  (`GroupState.id`) saves in `ui-state.json`. `Workspace.paneSelections[PaneID][path]` holds one
  `CodeSelectionState` per pane and path; it lives while the pane's tab list holds the path
  (`makeSelectionState`, `dropSelectionState`, `dropSelectionStates(of:)`).
- Shortcuts live in **three** places today:
  - `alloyCommands(model:settings:themes:)` in `AppCommands.swift` (a free `@CommandsBuilder` function): Settings… (⌘,),
    Go to Definition (F12), and the View menu (⌃⌘1/2, ⌘\, ⌥⌘\, ⌃⌘←/→/↑/↓, ⌥⌘L, ⇧⌘C).
  - Hidden buttons in `GlobalKeys` (`RootView.swift`): Quick Open ⌘P, Close Tab ⌘W, Next/Previous Tab ⌃Tab / ⌃⇧Tab,
    Tab 1-9 ⌘1-9, and New Session ⌘N in Code mode. These are not menu items. Chat mode's sidebar button owns ⌘N
    (`SidebarView`). Settings has a hidden `.cancelAction` (Escape) button that closes the window.
  - In-place handlers: the find field's `.onKeyPress(.escape)` and the panel's ⌘F `onKeyPress` in `CodePanel`, and the
    composer's Return.
- MetalUI's `CommandMenu`/`CommandGroup` content is "evaluated afresh whenever the bar is shown or a key reaches the
  command stage" (`Commands.swift`, `MN-J`). An item's shortcut fires only when no element in the key window claimed
  the key. So a menu item that reads a value at evaluation time picks up a changed shortcut with no menu rebuild.
- `KeyEquivalent(Character)` and `KeyboardShortcut(_:modifiers:)` are public, so a shortcut chosen at runtime works,
  including named keys (arrows, Home/End, F-keys as their private-use characters, as `goToDefinitionShortcut` does for
  F12) and `Button.keyboardShortcut(_: KeyboardShortcut?)` takes nil for "no shortcut".
- `UIState` has explicit `CodingKeys`, a tolerant hand-written `init(from:)`, a memberwise init and `version`
  (currently 1). A file with a higher version is read as defaults and never overwritten (`uiStateWritable = false`).
- `AlloySettings` has explicit `CodingKeys` and a hand-written `init(from:)` that reads each field with
  `decodeIfPresent` and a default. `Workspace.updateSettings(_:persist:)` saves first and applies only when the save
  succeeded; the settings sections catch the error and show "Could not save: …".
- Settings is one scrolling page of sections in `SettingsView` (Theme, Appearance, claude path, Editor, Shared
  knowledge, Language servers, then "Saved"), not tabs.
- `Workspace.notices: [Notice]` (path, kind, text) is what an editor group shows in its notice slot
  (`FilePanelNotice`).

## Approaches

1. **Three independent features.** Each one adds its own key handling: editor keys in `CodePanel`, menu keys in
   `AppCommands`, and a settings page that lists only the menu items. This is quick, but the settings page can't
   see the in-editor keys (⌘D, fold) or `GlobalKeys`, and conflicts can't be checked across the lists. The command
   palette would then have to build yet another list later.
2. **A single `CommandRegistry` first, then all three features use it (recommended, our call).** Every rebindable
   command has an id, a title, a group, a default chord, a scope, and (in AlloyKit) an enabled check and an action.
   The menu bar, `GlobalKeys`, the settings page and the future palette all read the registry. Multi-cursor and fold
   commands are registry entries from the start. Built-in keys that MetalUI views own are listed read-only so
   conflicts against them can be shown. This costs one small task up front.
3. **Push everything into MetalUI.** Multi-caret and folding are generic editor features that belong in `CodeView`,
   so they go there anyway (see the gaps). A keymap with Alloy's command ids is app policy, and a user-rebindable
   keymap is not something SwiftUI has. Rejected for shortcuts; adopted for the editor mechanics.

## Goals

1. **Multiple cursors** (one `CodeSelectionState` per view, as now).
   - ⌥-click adds a caret, and ⌥-click on an existing caret removes it (never the last one). ⌥-drag makes a column
     (box) selection: one selection per **visible** row, by x, clamped to each line's length; rows hidden in a fold
     are skipped **(our call)**. ⌘-click stays go-to-definition: `onTextClick(modifiers: .primary)` keeps consuming a
     ⌘ press; ⌥⌘-click has extra modifiers so it is not consumed and acts as ⌥-click **(our call)**.
   - ⌘D: with an empty primary selection, select the word under the primary caret; further presses add the next
     whole-word, case-sensitive match. With a non-empty primary selection (including multi-line), add the next
     case-sensitive match of its exact text, not whole-word. The search wraps at the end of the file. A match inside
     a fold is added and its fold opens, as find does **(our calls)**. ⌥⌘D skips: it drops the most recently added
     selection and adds the next match **(our call: VS Code's ⌘K ⌘D is a two-chord sequence, out of scope)**. ⇧⌘L
     selects all matches by the same rule.
   - ⌃⇧↑ / ⌃⇧↓ add a caret on the visible line above or below at the primary caret's goal column (Sublime's chords;
     VS Code's ⌥⌘↑/↓ would also work, but every chord is rebindable) **(our call)**.
   - Arrow keys, Home/End, word motion, shift-extend, typing, delete, paste and undo/redo act on all selections. A
     paste whose line count equals the number of selections puts one line at each; any other count pastes the whole
     text at each **(our call)**. Each keystroke is one undo step, and undo/redo restore every selection as it was
     before/after that step **(our call; G3)**.
   - Escape with more than one selection collapses to the primary and is claimed by the code view. With one selection
     the code view declines Escape, so it reaches whatever owns it today (find field when focused, Quick Open,
     Settings' cancel action, Chat) **(our call: focus decides, as it does today)**.
   - Every caret blinks in phase on the existing single blink epoch.
   - At most 10,000 selections. A command that would pass the cap stops at 10,000 and posts a `Notice(path:,
     kind: .warning, text: "Stopped at 10,000 cursors")` into `Workspace.notices`, shown in that editor group's
     notice slot and removed on the next selection change in that pane **(our call)**.
2. **Code folding**.
   ```
   ┌─ gutter ─────┬───────────────────────────────────────────┐
   │  12  ▾       │ func render(frame: Frame) {               │
   │  13          │     let plan = build()                    │
   │  14  ▸       │     for row in plan.rows { ⋯ }            │  folded 15-21
   │  22          │     commit(plan)                          │
   │  23          │ }                                         │
   └──────────────┴───────────────────────────────────────────┘
   ```
   - Chevrons sit in a fixed-width lane next to the line numbers. They show while the pointer is over the gutter, and
     on folded lines always **(our call: no chevrons at rest, so the gutter stays quiet)**.
   - Fold ranges come from one source per document, never merged: LSP `textDocument/foldingRange` when the server
     supports it; tree-sitter `folds.scm` for languages with a grammar and a whole-file tree; indentation otherwise.
     Tree-sitter (or indentation) is used until the LSP answer arrives **(our call)**.
   - A folded range shows `⋯` at the end of its first line; pressing `⋯` unfolds it. No caret can sit inside a fold:
     folding moves every caret inside the range to the end of its first line, then selections are normalized (merged).
     Vertical motion and ⌃⇧↑/↓ skip hidden rows. Find, ⌘D/⇧⌘L matches, go-to-definition, diagnostics navigation and
     diff review unfold the range their target is in. A folded line's gutter marker shows the most severe diagnostic
     among its hidden rows **(our calls; G5)**.
   - Commands: Fold (⌥⌘←), Unfold (⌥⌘→), Fold All (⌥⇧⌘←), Unfold All (⌥⇧⌘→), in a Folding submenu of the View menu.
     All four are declined by `CodeEditing` today. Fold-to-level commands are left out **(our call)**.
   - Folds are per view (pane, path), like selections, and are saved in the per-project `ui-state.json`.
3. **Keyboard shortcut settings**.
   ```
   Settings ▸ Keyboard
   [ ⌕ filter commands           ]                  [Reset all]
   Command                         Shortcut      Source
   Go to Definition                [ F12      ]  default
   Add Next Occurrence             [ ⌘D       ]  default
   Toggle Chat Column              [ ⇧⌘C   ⚠ ]  custom   ← conflicts with "Copy Path"  [Reset]
   Undo                              ⌘Z          built-in
   ```
   - A **Keyboard** section at the end of the Settings page, after Language servers and before "Saved", in the same
     column as the other sections **(our call)**. It lists every registry command grouped by `CommandGroup` (App, File,
     Edit, Selection, View, Folding, Go, Tabs), then a read-only "Built-in" group (editor keys and Escape) so a rebind
     onto one is visible.
   - Clicking a shortcut cell starts recording. The next chord with a non-modifier key is taken; Escape cancels;
     Delete/Backspace with no modifiers clears (the command becomes unbound). Recording ends on focus loss.
   - Conflict policy follows Decision 2. Whatever is chosen, a rebind and the reassignment it causes are one
     `AlloySettings` value written once, so they land together or not at all **(our call)**.
   - A chord that matches a reserved chord (MetalUI's default menu items such as ⌘Q/⌘H/⌘C/⌘V, the system list, or a
     built-in editor key) is saved but its row stays flagged, and the built-in still wins at runtime because the
     focused view or system claims it first **(our call)**.
   - Changes apply on the next key press and next menu open, with no restart.

### Calls settled (our calls)

1. **The registry lives in AlloyCore as pure data** (`CommandID`, `CommandSpec`, `KeyChord`, conflict detection), and
   AlloyKit binds the actions and converts chords to MetalUI's `KeyboardShortcut`. AlloyCore does not import MetalUI.
   Ids are stable strings (`editor.addNextOccurrence`, `view.toggleChatColumn`, `tabs.select3`); settings store them.
2. **Chords are stored platform-neutral, mirroring `EventModifiers`.** Tokens are `primary`, `cmd`, `ctrl`, `alt`,
   `shift`, then the key (`primary+shift+d`, `ctrl+tab`, `alt+primary+left`, `f12`). Conversion maps them to
   `.primary`, `.command`, `.control`, `.option`, `.shift`, the same values the code uses today, so each default
   behaves exactly as now on every platform. Defaults are written with `primary` where today's code says `.primary` or
   leaves modifiers out, and with `cmd`/`ctrl` where it names them. Conflict checks compare chords after resolving
   them for the running platform (`primary` = ⌘ on macOS, Ctrl elsewhere), so `ctrl+x` and `primary+x` conflict on
   Linux and Windows but not on macOS. Linux and Windows get the same registry, defaults, page and rules.
3. **⌥-click's current meaning is replaced.** Nothing in Alloy uses ⌥-click today.
4. **Folds are kept as line ranges in `ui-state.json`**, validated against the active source on restore (see
   Persistence).
5. **Default chords** for the multi-cursor family: ⌘D, ⇧⌘L, ⌥⌘D, ⌃⇧↑/↓; for folding ⌥⌘←/→ and ⌥⇧⌘←/→. All are
   rebindable, and all are free in Alloy today.
6. **Fold source precedence:** LSP over tree-sitter over indentation; tree-sitter/indentation is shown until LSP
   answers (formerly a user decision; both options build the same code, only the order differs).

## Non-goals

- Multi-chord sequences (⌘K ⌘0), vim/emacs keymaps, and importing VS Code keybindings.
- Folding imports or comments as separate kinds, and auto-folding on open.
- The command palette UI itself. This spec builds the registry it will use.
- Multi-caret across views or files, and multi-caret IME composition (marked text stays primary-caret only).
- Rebinding built-in editor keys (⌘Z, ⌘C, arrows, Tab, Return, Escape) or MetalUI's default menu items.

## Anti-goals

- **Slower typing, hovering or heavier idle.** Steady keystroke-frame guards stay put: Chat 88, Code 91/107/117 element
  requests per frame, idle frames cost 0. This holds with 1 caret, 3 and 50 carets, with folds present, and with a
  non-empty keybindings map.
- **Reimplementing editor mechanics in Alloy.** No Alloy-drawn carets, no shadow line map for folds, no catching keys
  ahead of `CodeView` to fake motions.
- **A dead settings page.** Every rebindable command reachable by a menu item or a global key appears there, and
  nothing appears there that does not work. Built-in keys appear read-only.

## Constraints

- Use MetalUI only. MetalUI is read-only from this project, and every missing piece is listed below as a gap for the
  MetalUI session. Nothing is worked around.
- Theme values only (warning colour from the theme). An accessibility id on every interactive view.
- Zero warnings. `swift test --no-parallel`. Never write `~/.claude` or a project's `.claude`.
- Linux and Windows mirror the macOS design, with no platform-specific substitutes.

## Design

### Command registry

`AlloyCore/Commands/CommandRegistry.swift`:

- `struct CommandSpec { id: CommandID; title: String; group: CommandGroup; defaultChord: KeyChord?; scope: Scope }`
  with `enum Scope { case menu, global, editor }`:
  - `menu`: a menu item (Settings…, Go to Definition, the View items, the Folding submenu).
  - `editor`: a menu item in Selection or View ▸ Folding that acts on the focused code view; it reaches the command
    stage only when `CodeView` declined the key.
  - `global`: a hidden button in `GlobalKeys` (Quick Open, Close Tab, Next/Previous Tab, Tab 1-9, New Session). These
    stay out of the menu bar, as today.
- `struct KeyChord: Hashable, Codable { modifiers: ChordModifiers (OptionSet: primary, cmd, ctrl, alt, shift); key:
  ChordKey }`, `enum ChordKey { case character(Character) /* lowercased */, named(NamedKey) }`, `NamedKey`: up, down,
  left, right, home, end, pageUp, pageDown, tab, return, escape, delete, forwardDelete, space, f1…f20. Canonical
  `description` (modifier order primary, cmd, ctrl, alt, shift) and `static func parse(_:) -> KeyChord?`. Parse fails
  on an empty key, a modifier-only chord, an unknown token or a duplicate token.
- `static let builtIn: [BuiltInKey]`: read-only rows (title + chord) for the keys `CodeEditing` claims, Escape, ⌘F and
  ⌘G. It is a mirror of MetalUI's list (G7 `CodeView.builtInKeyBindings`), checked against it by an AlloyKit test so
  the two can't drift.
- `func resolve(defaults:overrides:) -> [CommandID: KeyChord]` (absent = unbound) and
  `func conflicts(_ map:, reserved: [ReservedChord], platform: ChordPlatform) -> [CommandID: Conflict]`. Two
  commands on one resolved chord: both flagged; at runtime the first in registry order gets the chord and the other is
  given no shortcut, so behaviour is deterministic.

`AlloyCore/Commands/Keymap.swift`: a tiny `@Observable final class Keymap` whose only stored value is the resolved
map plus its conflicts. `Workspace` owns one and refreshes it inside `updateSettings` only when
`keybindings` changed (an equality check). Nothing else lives on it, so unrelated workspace or settings mutations never
touch the readers **(our call)**. With no workspace (the project chooser) the menu reads `Keymap.defaults`.

`AlloyKit/Commands/CommandActions.swift` maps each id to `(enabled: () -> Bool, perform: () -> Void)` against
`LauncherModel`/`Workspace`. `KeyChord.shortcut: KeyboardShortcut` converts to MetalUI (named keys to the
`KeyEquivalent` constants or their private-use characters). Then:

- `alloyCommands(...)` builds every `menu` and `editor` item from the registry, each with
  `.keyboardShortcut(keymap.shortcut(for: id))` (nil when unbound) and `.accessibilityIdentifier("cmd-<id>")`. Item
  count is fixed: an unbound command is still an item, just without a shortcut. The existing identifiers
  (`app-settings`, `view-mode-chat`, …) are kept as they are, since tests and the bench use them; new items use
  `cmd-<id>` **(our call)**.
- `GlobalKeys` builds its hidden buttons from the `global` entries the same way (one button per command, always
  present; nil shortcut when unbound), keeping their `global-key-*` ids. `SidebarView`'s ⌘N reads the same
  `session.new` id.
- Settings' `.cancelAction` and the in-place handlers (find Escape, panel ⌘F, composer Return) stay where they are and
  are listed under Built-in.

Editor commands act on the focused view's state, found through `Workspace.selectionState(for:in:)` and
`Workspace.foldState(for:in:)` with `defaultPane` and its active tab. When no code view is focused they are disabled.

### Multiple cursors

Alloy owns the commands, MetalUI the mechanics. ⌘D, ⇧⌘L, ⌥⌘D and ⌃⇧↑/↓ are registry actions calling
`CodeSelectionState` helpers (G2). ⌥-click, ⌥-drag, motion over all selections, Escape-collapse, multi-caret paste and
undo restoring selections, and drawing every caret are `CodeView` behaviour (G1, G3, G4). Escape-collapse is not a
registry command: the code view owns it and claims Escape only with more than one selection.

### Folding

- **Sources (Alloy).**
  - `AlloyCore/Folding/IndentFolds.swift` is pure. It keeps a per-document `[Int16]` indent-per-line cache; on rebuild
    it re-measures only the lines in the edited ranges since the last build, then derives ranges with one integer stack
    pass (no string work). Blank lines take the next non-blank line's indent. Tabs count as the document's tab width.
  - `AlloyHighlight` gains `foldRanges(documentID:) async -> [FoldRange]?`, running `folds.scm` on the whole-file tree
    it already keeps, cached per tree and re-run only when the tree changed. It returns nil for a windowed (large)
    document, which has no whole-file tree, and for a language without a query.
  - `AlloyLSP/FoldingRange.swift` follows the `Definition.swift` pattern, advertises `foldingRange` in client
    capabilities, and sends the document version with the request.
  - `AlloyKit/Code/FoldCoordinator.swift` owns, per open document, the current `FoldSource` and its ranges
    (`[path: FoldRanges(version, source, ranges)]`, `@Observable`, one entry per document, shared by every pane on it).
    It builds off the main actor with at most one build per document in flight (a newer version cancels the older
    build), applies a result only if the document version did not move (as `DiffDecorations` does), and rebuilds on
    the version settle (the same `buildTrigger` gate), never per keystroke. Windowed documents: LSP when the server
    answers, otherwise indentation **(our call)**.
- **Source switch.** When a better source answers, each existing fold in every pane on that document is kept if a new
  range starts on the same line (its end becomes the new range's end); otherwise it opens **(our call)**.
- **State (Alloy).** `Workspace+Folds.swift` mirrors `Workspace+Selection.swift`: `paneFolds[PaneID][path] →
  CodeFoldState`, created in `makeSelectionState` and dropped in `dropSelectionState`/`dropSelectionStates(of:)`, so
  folds live and die with the selection state. `foldState(for:in:)` is what the view code that passes
  `selectionState` to `CodeView` today also passes to `.foldState(_:)`. Two panes on one file have independent
  `CodeFoldState`s over the same buffer; each tracks edits itself.
- **Display (MetalUI, G5).** `CodeView.foldState(_:)` hides folded rows, draws the placeholder, keeps carets out of
  folds, and moves folds with edits as the buffer moves selections.
- **Edits.** A ranged edit outside a fold shifts it; an edit inside a fold's first line keeps it; an edit that removes
  the fold's start line or crosses its boundary opens it. Undo does not re-create a fold that an edit opened. A
  whole-buffer replace (reload from disk, a session's edit applied as a replace, format on save) keeps a fold only if
  its start line still opens a range in the next fold build; others open **(our calls; G5)**.
- **Chevrons (G6).** `CodeView.foldGutter(...)` draws the chevron lane from the available ranges and the fold state.

### Persistence and settings

- **Folds.** `UIState` gains `folds: [String: [String: [FoldLines]]]`, keyed by pane (`"chat"` or the group UUID
  string, the same id `GroupState.id` saves) then project-relative path. `FoldLines` encodes as a two-element array
  `[start, end]` (0-based lines) to keep the file small. The change: add `folds` to `CodingKeys`, read it in
  `init(from:)` with `(try? c.decodeIfPresent(...)) ?? [:]`, add `folds: … = [:]` to the memberwise init, and fill it
  in `currentUIState()`. `version` stays 1: the field is additive, and bumping it would make an older Alloy treat the
  file as newer and stop writing layout at all. An older Alloy drops `folds` on its next write; that is accepted
  **(our call)**. At most 2,000 folds per (pane, path) are saved; more are dropped from the end **(our call)**.
- **When folds are written.** Fold/unfold through a command or the gutter calls `workspace.noteFoldsChanged()`, which
  schedules the existing debounced UI-state write. Saving a file also schedules one when any pane holding it has folds,
  so saved lines match the saved text. Edits alone never schedule a write; whatever write comes next (or the flush at
  quit and window close) snapshots the current, edit-shifted ranges by reading each `CodeFoldState.folded` **(our
  call)**.
- **Restore.** Saved folds are applied only for groups `installLayout` kept and paths still in that pane's tabs; a
  renamed or deleted path's folds are gone with its tab. They are held as pending per (pane, path) and applied when
  the coordinator's first ranges for that document arrive: a fold is kept if its end is within the line count and its
  start line opens a range of that source; otherwise dropped quietly. Until ranges arrive nothing is folded. Folds of a
  pane closed while its build is in flight are dropped when the build lands (no state to apply to).
- **Keybindings.** `AlloySettings` gains `keybindings: [String: String]` (command id → canonical chord, or the
  sentinel `"none"` for explicitly unbound; `[String: String?]` would not round-trip nulls). Add it to `CodingKeys`,
  read it with `(try? c.decodeIfPresent([String: String].self, …)) ?? [:]`, and add it to the memberwise init with
  `[:]`. Only overrides are stored, so new defaults reach users who never changed that command; Reset removes the
  key. Unknown ids (from a newer Alloy) are kept on save and not shown. Writes go through
  `Workspace.updateSettings(_:)`, which saves before applying: on failure nothing changes in memory and the Keyboard
  section shows "Could not save: …" like the other sections, so disk and memory never diverge.

### Accessibility ids

- Keyboard settings: `settings-keyboard`, `keyboard-filter`, `keyboard-reset-all`, `keyboard-row-<id>`,
  `keyboard-chord-<id>`, `keyboard-reset-<id>`, `keyboard-conflict-<id>`, `keyboard-builtin-<n>`, `keyboard-error`.
- Folding: `fold-chevron-<line>` and `fold-placeholder-<line>` come through MetalUI's gutter hit ids (G6).
- Menu items: existing ids kept; new items `cmd-<id>`.

### Failure modes

| Case | Behaviour |
|---|---|
| LSP server lacks `foldingRange`, errors, is restarting, or times out after 1 s | Keep the current source (tree-sitter or indentation); ask again on the next settle |
| LSP answers for a stale version | Dropped; the next settle asks again |
| LSP answers an empty list | Treated like no answer: fall back to the next source (an empty answer is indistinguishable from no support in practice) **(our call)** |
| Windowed (large) document | LSP if it answers, otherwise indentation; never tree-sitter |
| A chord string in settings that doesn't parse (modifier-only, empty key, unknown token) | Ignored, default used, logged once per launch |
| A chord whose key doesn't exist on the current keyboard layout | Kept; it simply never fires, like any menu shortcut in MetalUI today (shortcuts match the produced character) |
| Settings file from a newer Alloy with unknown ids | Kept on save, not shown |
| Rebind onto a reserved, MetalUI default menu, or built-in editor chord | Saved and flagged; the built-in or system still wins |
| Recorder sees a chord the system swallows (⌘Tab, ⌘Space) | Never delivered, so nothing is recorded; recording continues |
| Recorder focused while an IME composition is active | The recorder takes no keys while marked text exists (G7) |
| Two commands on one chord (hand-edited settings) | Both rows flagged; the first in registry order gets the chord, the other none |
| Settings write fails (read-only or unwritable file) | Nothing applied; the section shows the error; a reassignment is not half-applied |
| ⌘D with no match left | Silent no-op; selections unchanged |
| Selection command would pass 10,000 selections | Stops at 10,000; warning notice in that group |
| File changed on disk while folded | Whole-buffer replace rule above |
| Escape with one selection | Code view declines; find, Quick Open, Settings or Chat handle it as today |

## Performance plan

- **Typing.** Multi-caret typing is a single `replaceSelections` transaction, as single-caret typing is today. Fold
  state is read only inside MetalUI's plan build. Fold rebuilds run on the version settle, off the main actor. The
  keymap is not read during frames at all: menu content reads it only when the bar opens or a key the focused view
  declined reaches the command stage, and typed characters are claimed by the code view first.
- **Many carets.** Carets and selection highlights are drawn only for selections intersecting visible rows; selections
  are sorted, so the plan finds them with a binary search (O(log n + visible)) and off-screen ones cost 0 in both the
  caret and the highlight path (G1). Budgets at the cap, owned by MetalUI tests (G3) and repeated as an Alloy test: one
  typed character with 10,000 carets on a 10,000-line file ≤ 16 ms main-thread for edit + normalize + plan; one undo
  step's selection snapshot ≤ 2 Ints per selection (≤ 160 KB at the cap).
- **Folds.** Indentation rebuild re-measures only edited lines, then one integer pass. Tree-sitter's query runs only
  when the tree changed. MetalUI keeps folds sorted, so a per-edit shift finds the first affected fold by binary
  search; budget ≤ 50 µs per edit at 1,000 folds (G5). Persisted folds are capped at 2,000 per (pane, path) and encode
  as integer pairs (about 12 KB at 1,000 folds).
- **Hover.** The chevron lane does not add or remove elements on hover: it is one lane whose glyphs are drawn inside
  the existing gutter draw, with visibility as a draw parameter, so a hover transition repaints with the same element
  count and no per-row allocation (G6). Moving within the gutter without crossing in or out costs no frame.
- **Idle.** Multiple carets share the one blink epoch, so blinking stays one scheduled frame at a time. With blink off,
  idle is 0.
- **Shortcuts.** The resolved map changes only on a successful settings write, lives in its own `Keymap` object, and
  never changes element counts (one button or item per command, always present).
- **New guards** in `CodeModePerformanceTests`:
  - `guardTyping` with 3 and with 50 carets: same steady counts (91/107/117).
  - With 5 folds above and inside the viewport: same counts.
  - Idle with folds and 3 carets, blink off: 0 requests.
  - Gutter hover enter/leave: one frame each, element requests ≤ the steady keystroke count; moving within the gutter: 0
    frames.
  - Chat-mode keystroke with a non-empty `keybindings` map: 88; Code-mode keystroke with it: 91/107/117.
  - 10,000-caret keystroke under the time budget above.
  - `MemoryProbeTests` with 1,000 folds stays under the existing budget.

## MetalUI gaps (forward to the MetalUI session)

- **G1. Multi-caret drawing.** `CodeViewPlan` draws a caret and a selection highlight for every selection that
  intersects the visible rows (binary search over the sorted selections; off-screen selections cost nothing), keeps
  the primary on `revealsCaret`, and blinks all carets on the one epoch. Today `caretPosition()` returns one caret.
  SwiftUI has no equivalent (NSTextView's `selectedRanges` is the closest).
- **G2. Selection helpers on `CodeSelectionState`.** `addNextOccurrence()` (word under caret when the primary is empty,
  then whole-word case-sensitive; exact text otherwise), `selectAllOccurrences(limit:) -> Bool` (false when capped),
  `skipToNextOccurrence()`, `addCaret(lineDelta:)` (keeps goal x, skips hidden rows), `collapseToPrimary()`. All
  undo-neutral. A helper whose new selection lands in a fold asks the fold state to open it.
- **G3. Motion and editing over all selections.** `CodeEditSession` arrow, word, Home/End and shift-extend apply to
  every selection and then normalize (today ~line 379 replaces them with one). Escape collapses and is claimed only
  when there is more than one selection; otherwise declined. Paste with N lines onto N selections puts one line at
  each. Each undo step records the selections before and after, and undo/redo restore them. Time budget at 10,000
  carets as in the performance plan.
- **G4. Gestures.** Built in, mirroring Xcode/VS Code: ⌥-press toggles a caret at the hit (never removing the last);
  ⌥-drag makes a column selection, one per visible row, by x, clamped. A press matching `onTextClick`'s modifiers is
  still consumed by that handler first. (Alternative if built-in is refused: `.onTextClick(…, consumes: false)`.)
- **G5. Folding model.** A `CodeFoldState` (`@Observable`, per view like `CodeSelectionState`, over a buffer) with
  `folded: [Range<Int>]` lines kept sorted, `fold/unfold/toggle/unfoldAll`, and edit tracking by the buffer by the
  rules in "Edits" (binary-searched shift, ≤ 50 µs per edit at 1,000 folds). `CodeView.foldState(_:)` covers hidden-row
  layout in `CodeViewPlan`/`CodeRowMap`, a trailing `⋯` placeholder that unfolds on press, moving carets out of a
  newly folded range then normalizing, skipping hidden rows in vertical motion, `select(_:reveal:)` and find matches
  opening the containing range, and the folded line's gutter marker showing the most severe hidden marker.
- **G6. Fold chevron gutter lane.** `CodeView.foldGutter(_ ranges: [Range<Int>], showsOnHover: Bool, onToggle:
  (Int) -> Void)`, a fixed-width lane beside `gutterMarkerLane`, drawn from the fold state, toggle on press, ids
  `fold-chevron-<line>`. Hover visibility is a draw parameter, not added or removed elements, and allocates nothing
  per row; a hover transition is one repaint at an unchanged element count.
- **G7. Shortcut recorder and reserved lists.**
  - `ShortcutRecorder(onRecord: (KeyboardShortcut) -> Void, onClear: () -> Void, onCancel: () -> Void)`, closure-based
    so it uses only MetalUI's own `KeyboardShortcut` (Alloy converts to `KeyChord`). While focused it claims the next
    key press with a non-modifier key, reports Escape as cancel and bare Delete/Backspace as clear, ignores
    modifier-only presses, takes nothing while IME marked text exists, and ends on focus loss. No SwiftUI equivalent;
    mirror the macOS shortcut fields.
  - `systemReservedShortcuts() -> [KeyboardShortcut]` per platform (macOS: ⌘Tab, ⌘Space, ⌃↑/↓ and similar; Windows
    and Linux: their window-manager chords such as Alt+Tab and Alt+F4), the same API on every platform.
  - `defaultMenuShortcuts() -> [(title: String, shortcut: KeyboardShortcut)]` for MetalUI's built-in menu items
    (Quit, Hide, Close Window, Undo, Copy, Paste, …).
  - `CodeView.builtInKeyBindings(platform:) -> [(title: String, shortcut: KeyboardShortcut)]`, the keys
    `CodeEditing.command(for:platform:)` claims, so Alloy can list and check them.
  - Already confirmed, no gap: menu content is re-evaluated on bar show and at the command stage, and
    `KeyboardShortcut`/`KeyEquivalent` take runtime values including named keys.

## Testing strategy

- **AlloyCore unit:** `KeyChord` parse/print round-trip (all named keys, F-keys, rejects modifier-only and unknown
  tokens); platform resolution (`ctrl+x` vs `primary+x` conflict off macOS only); `resolve` and `conflicts`, including
  the registry-order winner; `IndentFolds` on Swift, Python, YAML and mixed tabs, and incremental re-measure equals a
  full scan; `UIState` and `AlloySettings` decode old files without the new keys, and `"none"` round-trips as unbound.
- **AlloyHighlight:** fold queries on fixture files per grammar; nil for windowed documents.
- **AlloyLSP:** `FoldingRange` against `FakeServer`, including no capability, timeout, stale version and an empty list.
- **AlloyKit:**
  - Registry-built menus and `GlobalKeys` contain every command with its id and chord; existing ids unchanged.
  - Rebinding updates the menu item and the global key, persists, and a failed save changes nothing.
  - A reassignment writes both commands in one save. The conflict row shows.
  - The built-in list matches `CodeView.builtInKeyBindings`.
  - ⌘D (empty and multi-line selection), ⇧⌘L (with the cap notice) and ⌃⇧↓ produce the expected selections.
  - Escape with one selection still closes Settings and Quick Open.
  - Folds persist per (pane, path) by group UUID, restore after ranges arrive, drop for a removed path, and are
    dropped with the view. Source switch keeps same-start folds.
  - Find and go-to-definition unfold.
- **Perf guards:** listed above.

## Task breakdown (each reviewable on its own)

1. **Command registry, chords and `Keymap`** (AlloyCore, pure + tests). Can start now.
2. **Menus and `GlobalKeys` from the registry** (AlloyKit; behaviour and ids identical, plus Code-mode guard with a
   custom map). Depends on 1. No MetalUI dependency: dynamic menu content is already supported.
3. **Keyboard settings section and persistence.** Depends on 2 and G7.
4. **Multi-cursor commands** (⌘D, ⇧⌘L, ⌥⌘D, ⌃⇧↑/↓, cap notice) plus perf guards. Depends on 1 and G1-G4.
5. **Fold sources:** incremental indentation (AlloyCore), tree-sitter query (AlloyHighlight), LSP `foldingRange`.
   Independent; can start now.
6. **Fold coordinator, state, persistence and commands** plus perf guards. Depends on 1, 5 and G5-G6.

Tasks 1 and 5 run in parallel right away; 2 follows 1 at once. The MetalUI gaps run in parallel in the MetalUI session.

## Decisions for the user

1. **The registry, before or with the command palette?**
   (a) This feature builds the registry, and the palette feature uses it later. (b) Build the palette first and adopt
   its registry here. (c) No shared registry (approach 1). **Recommended: (a)**, because shortcut settings need it
   regardless and the palette only adds a view.
2. **What happens on a conflict when rebinding?**
   (a) Warn and keep both; the first in registry order wins. (b) Ask "Reassign from X?" and unbind the other on yes.
   (c) Refuse the binding. **Recommended: (b)**. It is what Xcode and VS Code users expect and never leaves a silent
   loser. (a) is the lighter build (no confirmation UI).
3. **Scope of keybindings:** (a) global, in Alloy settings only. (b) Global plus a per-project override.
   **Recommended: (a)**. The brief says "Alloy's own settings", and per-project keymaps are rare.


## Approved decisions (2026-11-16)

The user approved every recommendation above ("Approved build it"). Binding:
- 1(a) adjusted: the registry is built first as a shared feature (see command-palette.md); this feature adds shortcut overrides on top.
- 2(b) conflict asks "Reassign from X?". 3(a) global keymap only.

## MetalUI design answers (2026-11-16)

MetalUI's editor design (code-intel #4 + G1–G6) was accepted with these answers:
- No caret drawn at the head of a non-empty selection (Xcode). The primary selection is the one added last (`primaryIndex`).
- `FoldLines [start, end]` (inclusive) maps to MetalUI's `start..<end+1`. An edit wholly inside a folded body keeps the fold.
- Chevrons come from an edit-tracked `CodeFoldState.foldableRanges`, set with a buffer version, and `foldGutter(showsOnHover:onToggle:)`. Alloy computes the ranges off the main thread.
- `CodeGutterMarker.severity` decides which hidden marker shows. `fold-chevron-<line>` and `fold-placeholder-<line>` are AX identifiers.
- ⌥-click and ⌥-drag work on every platform. ⌥-drag replaces all selections.
- **Changed call:** multi-caret typing coalesces into undo steps like single-caret typing (NSTextView). It is not one step per keystroke.
- Text-anchored presentations chain directly on the `CodeView`.
