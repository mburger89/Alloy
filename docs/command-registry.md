# Command registry

One app-wide `CommandRegistry` (in `CommandCenter`) holds every command. The application menu's Settings item, the Go
and View menus, the hidden global keys and the command palette are all generated from it, so a feature registers a
command once and gets all of them. Menus, ids and behaviour are pinned by `CommandParityTests`.

## The descriptor

`CommandDescriptor` (AlloyCore, no closures, Codable):

- `id`: stable, dotted (`view.splitRight`). Never reused; user key overrides and recents refer to it.
- `title`, `category`: the palette shows `Category: Title`.
- `shortcut`: the default `KeyChord` (nil for none). The user's `AlloySettings.keybindings` override it through `Keymap`
  (`"none"` unbinds; an unknown id or a malformed chord is ignored). The palette shows the effective chord (override applied) right-aligned on each row, spelled by MetalUI's
  `KeyboardShortcut.displayText` (⇧⌘P on macOS, Ctrl+Shift+P elsewhere); a command with no chord shows nothing.
- `binding`: how the chord is delivered. `.menu` (the command's menu item carries it), `.global` (a hidden key button
  that is always present), `.globalInCode` (the same, only in Code mode), `.none` (palette only).
- `menu`: `.appSettings`, `.go`, `.view` or `.plugins`; nil means the palette only.
- `recordsRecent`: running it moves it to the front of the project's recents.
- `source`: `.builtin` or `.plugin(id:)`.
- `menuAccessibilityID`, `keyAccessibilityID`: kept ids; otherwise `menu-<id>` and `global-key-<id>`.

## Registering

```swift
center.registry.register(
    CommandDescriptor(id: "git.commit", title: "Commit", category: CommandCategory(name: "Git"),
                      menu: .go, recordsRecent: true),
    isEnabled: { workspace.hasStagedChanges },
    run: { workspace.commit() })
```

`register` returns `.added` or `.rejected(reason)`. `unregister(source:)` removes everything one source registered and
is safe to call from inside one of that source's own commands. Built-ins live in `BuiltinCommands.register`.

## Clash rule

Built-ins register first and win. A repeated id is rejected. A built-in whose default chord another command holds is
rejected. A plugin command is always added but its shortcut is dropped (MetalUI cannot yet show plugin shortcuts).
Every rejection is recorded in `registry.rejections`. At resolve time two commands on one chord (through overrides)
leave the first with it and list both in `keymap.conflicts`.

## The closure contract

`isEnabled` and `run` are actions: they are called when a menu item is built or chosen, when a key arrives, or when a
palette row is chosen, never from a view body. `registry.run(id:)` is the only way to run a command; it does nothing
for a missing or disabled command, so a stale key, menu item or palette row can never run one. Closures resolve the
workspace when they run (`center.workspace`), because the registry outlives workspace switches.

## Editor commands

`editor.addNextOccurrence` (cmd+d), `editor.selectAllOccurrences` (cmd+shift+l), `editor.skipNextOccurrence`
(no default shortcut on macOS: alt+cmd+d is the system's Show or Hide the Dock, so bind one in Settings; alt+cmd+d elsewhere), `editor.addCaretAbove` and `editor.addCaretBelow` (ctrl+shift+up/down) sit in the Edit menu (category
Selection, menu ids `cmd-<id>`). They act on the focused view's selection state through `Workspace.runMultiCursor`
and are disabled when no code view is focused (project chooser, no tab, a non-code tab).

### Rename Symbol

`edit.rename` ("Rename Symbol", F2, category Edit, menu id `menu-rename`) sits in the Edit menu after the pasteboard
items and before Format Document, and is recorded in recents. It runs `IntelCommand.rename`: the focused code view
opens the rename field at its primary caret (any selection count). It is enabled only when that view's server offers
`renameProvider`, the document is open at the server and editable, and the view is not the old-text pane of side by
side; with no server, a read-only document or no focused code view it is disabled and `run(id:)` does nothing. F2 is
a menu shortcut, so a focused handler that claims F2 wins; the code view claims none. A user keymap entry in
`AlloySettings.keybindings` moves or (with `none`) unbinds it like any other command, and it shows in the Keyboard
settings section.

### Terminal focus

While a terminal pane has keyboard focus in Code mode, `tab.close` (cmd+w), `tab.next` and `tab.previous` (ctrl+tab,
ctrl+shift+tab) act on the terminal's tabs instead of the editor's (closing the last one hides the panel and returns
focus to the editor), and `tab.new` (cmd+t, "New Terminal Tab") opens a terminal tab; it is disabled otherwise. The
panel installs `Workspace.terminalFocusActions`; the commands read it inside their closures only.

Terminal commands: `terminal.copy`, `terminal.selectAll`, `terminal.find` ("Find in Terminal") and
`terminal.clearScrollback` (category Terminal, global keys) are enabled only while a terminal pane has focus, so their
chords (cmd+c, cmd+a, cmd+f, cmd+k; primary+shift+c/a/f/k on Linux and Windows, where Ctrl belongs to the
program) never shadow the editor's. Each calls the matching `TerminalFocusActions` member, which acts on the focused
pane's screen; with no session or an exited pane they do nothing. Copy puts the trimmed selection on the clipboard and
leaves it alone when nothing is selected. Find opens a bar (`terminal-find-bar`) above the focused pane: Return selects
the next match in the scrollback, Shift-Return the previous (both wrap), Escape closes it and returns focus to the
terminal; the bar exists only while open and costs nothing otherwise. Paste is not a registry command: the terminal view takes
cmd+v and Edit > Paste itself (bracketed when the program asked, ESC stripped). Clicking a link opens files inside the
project in the focused editor group and URLs in the browser.

### Folding

`editor.fold` (alt+cmd+left), `editor.unfold` (alt+cmd+right), `editor.foldAll` (alt+shift+cmd+left) and
`editor.unfoldAll` (alt+shift+cmd+right) sit in the Folding submenu at the end of the View menu (category Folding,
menu ids `cmd-<id>`). They act on the focused view's fold state through `Workspace.runFold` and are disabled when no
code view is focused. Fold folds the innermost unfolded range around each caret; Unfold opens the fold starting on the
caret line, else the folds hiding it; Fold All and Unfold All act on every range of the displayed source.

## Recents

`run(id:)` calls `workspace.noteCommandRun(id:)` for commands with `recordsRecent`. Recents are per project, newest
first, capped at 10, and unknown ids are kept.

## Key overrides

`Workspace.updateSettings` fires `onKeybindingsChanged` only when `keybindings` changed; `CommandCenter.bind(_:)`
installs the hook and applies the current overrides. A failed save throws before anything is applied.

## Keyboard settings

Settings has a Keyboard section (`settings-keyboard`) after Language servers and before Saved. It lists every registry
command with its effective shortcut, filtered by title, id or chord text (`keyboard-filter`). Ids: `keyboard-row-<id>`,
`keyboard-chord-<id>` (a MetalUI `ShortcutRecorder`), `keyboard-reset-<id>` (only when overridden),
`keyboard-conflict-<id>`, `keyboard-builtin-<n>`, `keyboard-reset-all`, `keyboard-reassign-prompt`,
`keyboard-reassign-confirm`, `keyboard-reassign-cancel`, `keyboard-error`, `keyboard-empty`.

- Only overrides are stored (`settings.keybindings`). Reset removes the key, clear stores `none`, and unknown ids from a
  newer Alloy are kept on save and not shown. An unparseable value is ignored and the default shows.
- Clash kinds. Another command on the chord is a hard clash: recording asks "Reassign from X?" and nothing is written
  until Reassign. A MetalUI standard menu key, a system-reserved key or a hard code view key is saved and flagged; the
  built-in still wins. A code view key with `isConditional` is soft: shown with its condition, never blocking. Two
  commands on one chord (hand-edited settings) flag both rows and the first in registry order keeps the chord.
- One write: a rebind and its reassignment are one `Workspace.updateSettings` call. On failure nothing is applied and
  `keyboard-error` shows "Could not save: ...".
- Closed settings and an idle open section cost no frame work; an armed recorder is idle too.
- macOS: Skip to Next Occurrence has no default shortcut because the system reserves the Option-Command-D chord (Show or
  Hide the Dock). It stays in the menu and palette and can be bound here. A registry test checks that no built-in
  default collides with the platform's system-reserved keys.

## Plugins

A plugin registers through the same `registry.register` with `source: .plugin(id:)` and removes everything with
`registry.unregister(source:)`. There is no plugin loader yet; `CommandPluginTests` drives the seam with a fake source.

- Placement: no `menu` means palette only. `menu: .plugins` adds the item under a "Plugins" menu after View. The menu is
  generated when the bar is evaluated and is absent while no command is placed in it; a plugin that registers after
  launch shows up at the next evaluation, with no observation.
- Clash behaviour: a plugin can never replace or shadow a built-in. A repeated id (a built-in's or another plugin's) is
  rejected with `.duplicateID`. A plugin's shortcut is always dropped (the command is still added and the drop is
  recorded as `.pluginShortcutDropped` in `registry.rejections`), so a plugin cannot take a built-in's chord either.
  The shortcut stays dropped until MetalUI can show plugin shortcuts (gap G4: standard-menu shortcuts).
- Contract: `register`, `unregister` and every closure run on the main actor, and `run` must return promptly (start a
  `Task` for slow work). A command may call `unregister(source:)` for its own source from inside `run`. Registering costs
  one `GlobalKeys` re-run and no `AlloyScreen` re-run; a registered plugin adds nothing to an idle frame.
- Duplicates by title: two plugins with the same "Category: Title" are both listed, in registration order.
- Recents: a plugin command with `recordsRecent` stays in the project's recents after the plugin unloads; the palette
  skips ids that are no longer registered.
