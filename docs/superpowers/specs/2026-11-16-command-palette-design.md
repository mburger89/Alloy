# Alloy: Command palette

Date: 2026-11-15. Status: draft, revised after the builder check, awaiting the user's decisions. Builds on Code mode
(`2026-11-15-alloy-code-mode-design.md`), the islands design (`2026-11-13-alloy-islands-design.md`) and LSP v1
(`2026-11-12-alloy-lsp-design.md`).

## Intent and why

The user asked for a set of editor features, run in parallel, and added "a plugin capability" to the list. Alloy's
commands are scattered today: the menu bar (`alloyCommands` in `AppCommands.swift`), hidden key buttons (`GlobalKeys`
in `RootView.swift`) and local `onKeyPress` handlers each hold a hand-written title, shortcut, enabled rule and
action. Nothing can list them. A command palette (⇧⌘P) gives one searchable place for every command, and the registry
behind it is the seam that search, git, terminal, code intelligence and plugins will add their commands through.
Without a registry, every later feature would have to edit the menu builder and `GlobalKeys` by hand, and plugins could
not add commands at all.

## Approaches

1. **Alloy-side command registry that generates the menus, the hidden shortcuts and the palette rows (recommended).**
   One `CommandRegistry` holds commands. `alloyCommands` builds its menu `Button`s from it, `GlobalKeys` builds its
   hidden buttons from it, and the palette reads the same list. The core needs no new MetalUI API (only the shortcut
   display text, gap 1); plugins register into it. Cost: a one-time migration of the existing menu items and global
   keys.
2. **Read the declared menu bar back out of MetalUI.** The palette asks MetalUI for the evaluated `commands { }` items.
   Menus stay hand-written. It needs a new public MetalUI API with no SwiftUI equivalent, cannot see commands that are
   not in a menu (⌘P, ⌘W, ⌃Tab, ⌘1-9, palette-only plugin commands), and menu items have no stable ids for recents.
3. **Palette with its own hand-written list beside the menus.** Every command is declared twice and drifts. Rejected.

## Goals

1. **Open and close.** ⇧⌘P (Ctrl+Shift+P on Linux and Windows, through `.primary`) opens the palette in Chat and in
   Code mode, centred near the top of the project window, below the title band. Esc or focus loss closes it. ⇧⌘P
   while it is open closes it. A View menu item "Command Palette…" carries the shortcut.
2. **Every command with a workspace-level action is listed**: the current menu items (Settings, Go to Definition, Chat
   and Code mode, splits, group focus moves, Reveal in Tree, Toggle Chat Column), the current global keys (Quick Open,
   Close Tab, Next and Previous Tab, Go to Tab 1-9, New Session), the palette itself, and anything a later module or a
   plugin registers.
3. **Fuzzy match** on "Category: Title" (for example "View: Split Right"), with bonuses at word starts and
   lower-to-upper transitions, so "vsr" finds View: Split Right.
4. **Shortcut shown** right-aligned on each row in the platform's form (⇧⌘P on macOS, Ctrl+Shift+P elsewhere).
5. **Recently used first.** With an empty query, up to 5 recent commands appear under a "Recently used" heading, then
   all others by category and title. With a query, a recent match gets a small rank bonus; a clearly better match wins.
6. **Disabled commands greyed** (muted ink, ↩ does nothing), so the user learns a command exists. See Decision 2.
7. **One registry.** Menus, hidden global shortcuts and palette rows all come from `CommandRegistry`. A parity test
   fails if a menu item or a global key has no registry entry, or the reverse.
8. **Plugin seam.** `register(_:)` and `unregister(source:)` take commands tagged with a source, so a plugin's commands
   appear in the palette and, if it asks, in a "Plugins" menu, and go away when it unloads.

## Non-goals

- Plugin loading, discovery, sandboxing, isolation or a plugin API beyond the command descriptor. Those belong to the
  plugin feature.
- User-editable key bindings.
- Command arguments or prefixed modes (">", ":", "@"). Quick open stays separate.
- Palette rows for files, sessions or settings values.
- Rows for focus-scoped keys that have no workspace-level action today (the file panel's ⌘F, the code view's ⌘G, the
  composer's ↩). Their owners register them when they expose an action; this feature does not move them (our call).

## Anti-goals

- **Never** read the registry or the palette model in `AlloyScreen`'s body. The palette mounts through its own
  component (see Architecture), so opening, closing and typing leave `AlloyScreen` reruns at 0.
- **Never** keep the palette view in the tree while it is closed. No hidden or zero-opacity mount.
- **Never** raise the steady keystroke guards (Chat 88, Code 91/107/117) or make an idle frame cost more than 0.
- **Never** run a disabled command, through a menu, a shortcut or a stale palette row.
- **Never** let a plugin command replace or shadow a built-in id or shortcut.
- **Never** lose user data from a palette action. Commands that discard keep their existing prompt.
- **Never** write UI state to disk from a keystroke. A run writes only when the recents list actually changes, through
  the existing 0.5 s debounce.

## Constraints

- MetalUI is read-only from this project. Anything missing is listed under "MetalUI gaps" and forwarded to the MetalUI
  session. Nothing is worked around.
- Theme tokens only, shared with quick open (`panelFill`, `commandTint`, muted ink, corner radius).
- `accessibilityIdentifier` on every interactive view. Zero warnings. `swift test --no-parallel`.
- Linux and Windows mirror macOS: the same palette and registry, the shortcut in their form, and MetalUI's drawn 25 pt
  menu strip, which renders the same `commands { }` content and so the same registry-built menus.
- Never write `~/.claude` or a project's `.claude`.

## Design

### User-facing behaviour and UI sketch

```
            +------------------------------------------------+
            |  > split                                        |   command-palette-field
            +------------------------------------------------+
            |  Recently used                                  |   command-palette-recent-header (empty query only)
            |  View: Split Right                  ⌘\          |   command-palette-row-0 (selected, commandTint)
            |  View: Split Down                   ⌥⌘\         |   command-palette-row-1
            |  View: Focus Left Group             ⌃⌘←         |   command-palette-row-2 (greyed in Chat mode)
            +------------------------------------------------+
            |  No matching commands                            |   command-palette-empty
```

520 pt wide (quick open is 420; titles plus shortcuts need more room), at most 360 pt tall, quick-open tokens (our
call). ↑/↓ move the selection over every row, disabled ones included; ↩ on a disabled row does nothing. ↩ or a click
runs the selected command. Matched characters are drawn in the accent ink. Each row is "Category: Title" on the left and
the shortcut on the right.

Settled presentation details (our calls): row height matches quick open's rows; the heading reads "Recently used";
fewer than 5 recents show as many as exist, and none shows no heading; a recent id with no registered command is
skipped. Two commands with the same "Category: Title" (only possible between plugins) are both listed, in registration
order.

### Command model

- **AlloyCore/Commands/CommandDescriptor.swift** (UI-free, `Sendable`, `Codable`):
  `struct CommandDescriptor { id: String; title: String; category: CommandCategory; shortcut: CommandShortcut?;
  binding: CommandBinding; menu: MenuPlacement?; recordsRecent: Bool; source: CommandSource;
  menuAccessibilityID: String?; keyAccessibilityID: String? }`.
  - `CommandSource` is `.builtin` or `.plugin(id: String)`.
  - `CommandCategory` has a `name` ("App", "Go", "View", "Tab", "Session", or a plugin's own name) used in the
    "Category: Title" string. It does not decide the menu; `menu` does.
  - `CommandShortcut` is a plain key-plus-modifiers value (`.primary`, `.command`, `.control`, `.option`, `.shift`) so
    AlloyCore stays free of MetalUI. AlloyKit maps it to MetalUI's `KeyboardShortcut`.
  - `CommandBinding` says who owns the key (our call; it replaces the earlier `bindsKey` flag):
    - `.menu`: the menu item's `.keyboardShortcut` owns it. This also covers F12: MetalUI's command stage runs only
      after the focused view declined the key, so the code view's own F12 handler still wins, exactly as today.
    - `.global`: a hidden `GlobalKeys` button owns it, in every mode.
    - `.globalInCode`: a hidden `GlobalKeys` button in Code mode only; in Chat mode the shortcut is display-only
      because another view owns it. Today this is only ⌘N, which the Chat sidebar's button owns.
    - `.none`: no key.
  - `MenuPlacement` is `.appSettings` (MetalUI's `.appSettings` group), `.go`, `.view` or `.plugins`.
  - Ids are stable dotted strings: `app.settings`, `go.definition`, `view.splitRight`, `view.commandPalette` (our call).
- **AlloyKit/Commands/CommandRegistry.swift**, `@MainActor @Observable final class`. Its command storage is
  `@ObservationIgnored`; the only observed property is `revision: Int`, bumped on register and unregister. It pairs
  each descriptor with `isEnabled: @MainActor () -> Bool` and `run: @MainActor () -> Void`, and offers
  `register(_:) -> RegistrationResult`, `register(contentsOf:)`, `unregister(source:)`, `command(id:)`,
  `commands(in: MenuPlacement)`, `commands` (stable registration order) and `run(id:) -> Bool`.
  - `register` does not throw (our call). It returns `.added` or `.rejected(reason)`, and appends the rejection to
    `rejections` (a list the plugin feature can show; Alloy has no logger and this feature adds none).
  - Clash rule (our call): an id already registered is rejected. A shortcut already bound by a registered command is
    rejected, built-in first, then first plugin wins over a later plugin. A plugin command's shortcut is not bound at
    all until MetalUI gap 4 can tell the registry which shortcuts MetalUI's standard menus own (⌘Q, ⌘C, ⌘V and so on);
    until then the command is added with its shortcut dropped and a rejection noted for the shortcut.
  - `run(id:)` looks the command up, returns false if missing or `isEnabled()` is false, copies the closure out and calls
    it, so an `unregister` from inside a running command is safe. It then records the id in the recents when
    `recordsRecent` is true and the workspace exists.
  - Contract for the closures (our call): `isEnabled` and `run` are only ever called from actions (a key, a click, a
    menu evaluation, palette open and submit), never from a component body. MetalUI evaluates the `commands { }` content
    on demand (menu open, a keystroke reaching the command stage) outside any body, so the Observable reads in
    `isEnabled` (for example `workspace.mode`) subscribe nothing, as the hand-written builder does today.
  - Plugin closures run on the main actor in process. A `run` must return promptly and start long work in a `Task`.
    A blocking or trapping closure freezes or crashes the app; isolating untrusted plugin code (for example out of
    process) is the plugin feature's job, and this registry only accepts closures the host hands it (our call).
- **AlloyKit/Commands/CommandCenter.swift**, `@MainActor final class` (not Observable), one per app, created in
  `main.swift`. It holds `registry`, `palette: CommandPaletteModel`, `quickOpen: QuickOpenModel`, and a
  `bringProjectWindowForward` closure. Quick open moves here from `AlloyScreen`'s `@State` (our call) so that the
  registry's Quick Open and Close Tab commands can see it; `AlloyScreen` now reads `center.quickOpen` and passes it down
  the islands as today, so quick open's behaviour and its threading through `FilePanelView`, `EditorGroupView` and
  `TitleIsland` are unchanged.
- **Built-in commands**: `BuiltinCommands.register(into center: CommandCenter, launcher: LauncherModel,
  settings: SettingsWindowController, themes: () -> ThemeController?)`, called once from `main.swift` before
  `app.commands`. The closures resolve `launcher.workspace` at call time, so the registry outlives workspace switches
  and the chooser, where every workspace command reports disabled. Themes are read through a closure because the test
  helper installs the theme controller after the menu.

### Built-in commands

| Id | Row | Shortcut | Binding | Menu | Existing a11y id kept | Recents |
| --- | --- | --- | --- | --- | --- | --- |
| `app.settings` | App: Settings… | ⌘, | menu | appSettings | `app-settings` | yes |
| `go.definition` | Go: Go to Definition | F12 | menu | Go | none today, gets `menu-go.definition` | yes |
| `view.commandPalette` | View: Command Palette… | ⇧⌘P | menu | View | new: `view-command-palette` | no |
| `view.chatMode` / `view.codeMode` | View: Chat Mode / Code Mode | ⌃⌘1 / ⌃⌘2 | menu | View | `view-mode-chat` / `view-mode-code` | yes |
| `view.splitRight` / `view.splitDown` | View: Split Right / Down | ⌘\ / ⌥⌘\ | menu | View | `view-split-right` / `view-split-down` | yes |
| `view.focusLeft` … `view.focusDown` | View: Focus Left Group … | ⌃⌘ arrows | menu | View | `view-focus-left` … | no |
| `view.revealInTree` | View: Reveal in Tree | ⌥⌘L | menu | View | `view-reveal-in-tree` | yes |
| `view.toggleChatColumn` | View: Toggle Chat Column | ⇧⌘C | menu | View | `view-toggle-chat-column` | yes |
| `go.quickOpen` | Go: Quick Open | ⌘P | global | none | `global-key-quick-open` | yes |
| `tab.close` | Tab: Close Tab | ⌘W | global | none | `global-key-close-tab` | no |
| `tab.next` / `tab.previous` | Tab: Next / Previous Tab | ⌃Tab / ⌃⇧Tab | global | none | `global-key-next-tab` / `-previous-tab` | no |
| `tab.select1` … `tab.select9` | Tab: Go to Tab 1 … 9 | ⌘1 … ⌘9 | global | none | `global-key-tab-1` … | no |
| `session.new` | Session: New Session | ⌘N | globalInCode | none | `global-key-new-session` | yes |

Settled (our calls): the menus keep exactly today's items, order and shortcuts, plus the one new View item. Every
existing accessibility id is kept through `menuAccessibilityID` and `keyAccessibilityID`; a command without one (new or
plugin) gets `menu-<id>` and `global-key-<id>`. "Go to Tab N" is nine static commands with fixed titles, never one row
per open tab, so tab changes never touch the registry. Repeatable navigation (tab cycling, Go to Tab N, focus moves,
Close Tab) and the palette itself do not record recents, so ⌃Tab cannot flood the list.

Enabled rules match today's: Settings and the mode switches need a workspace; splits, focus moves, Reveal in Tree and
Toggle Chat Column need Code mode; Go to Definition needs a workspace. Close Tab also needs quick open and the palette
to be closed (today's inline `if !quickOpen.isShowing` guard in `GlobalKeys`, moved into the enabled rule). Quick Open
hides the palette before showing; the palette hides quick open before showing, so only one is ever open.

### Menus

`alloyCommands(model: LauncherModel, settings: SettingsWindowController, themes: ThemeController?)` gains a
`center: CommandCenter` parameter and keeps its other parameters (`settings` and `themes` stay because
`BuiltinCommands` is registered with them in `main.swift`). Its body becomes:

- `CommandGroup(replacing: .appSettings) { for c in registry.commands(in: .appSettings) { button(c) } }`
- `CommandMenu("Go") { for c in registry.commands(in: .go) { button(c) } }`
- `CommandMenu("View") { … .view … }`
- `if registry.hasCommands(in: .plugins) { CommandMenu("Plugins") { … } }`: hidden when empty (our call).

`button(c)` is `Button(c.title) { _ = registry.run(id: c.id) }` with `.keyboardShortcut` when `c.binding == .menu`,
`.disabled(!c.isEnabled())` and the item's accessibility id. MetalUI's `MenuContentBuilder` has `buildArray` and
`CommandsBuilder` has `buildOptional`, so `for` and `if` need nothing new. MetalUI re-evaluates this content each time
the bar is needed, so a plugin registered after launch appears at the next menu open or keystroke with no observation.
The drawn strip on Linux and Windows renders the same content.

`main.swift` and both test helpers (`installAlloyMenu(_:themes:)` and `installAlloyMenu(model:themes:)` in
`Tests/AlloyKitTests/Support.swift`) build a `CommandCenter`, register the built-ins and pass the center. The helpers
gain an optional `center:` parameter so a test can register fake plugin commands before installing.

### GlobalKeys

`GlobalKeys` stays the per-workspace zero-size hidden stack mounted in `AlloyScreen`'s `ZStack`, with the same modifiers.
It takes `workspace` and `registry`, reads `registry.revision` (so a plugin load reruns it, nothing else does) and
`workspace.mode` (as it does today for ⌘N). It emits one hidden `Button` per `.global` command, then
`if workspace.mode == .code { … }` for the `.globalInCode` ones. Each button calls `registry.run(id:)`. The buttons carry
no `.disabled`: a disabled command's key is still consumed and does nothing, as today's guarded ⌘W is (our call; it
keeps a key from leaking to a lower handler mid-state). It is an `Equatable` component keyed on workspace and registry
identity, so `AlloyScreen` reruns never rebuild it.

The element count must match today's 4 + 9 (+1 in Code mode) buttons. Task 3 captures the baseline counts before
touching it.

### Palette

- `CommandPaletteModel` (`@MainActor @Observable`): `isShowing`, `query`, `rows`, `selected`, and an
  `@ObservationIgnored` snapshot. `toggle(workspace:)` shows or hides synchronously (no animation), so a rapid ⇧⌘P
  cannot race a hiding palette.
- **Open**: the `view.commandPalette` command's run calls `center.bringProjectWindowForward()` (MetalUI's public
  `makeKeyAndOrderFront`, so ⇧⌘P pressed in the Settings window shows the palette where the user can see it), hides
  quick open, then `palette.show(...)`. Its enabled rule needs a workspace, so in the chooser the item is greyed and
  the key does nothing (our call: almost every command needs a project).
- **Mount**: a new `PaletteLayer` component, `Equatable` on the model's identity, added as the last child of
  `AlloyScreen`'s `ZStack` after `GlobalKeys` and `HeldReconciler`. Being last, it draws above the islands and their
  glass. It reads `palette.isShowing`; when false it produces nothing. When true it produces the panel aligned top,
  centred horizontally, offset down by `style.titleBandHeight` plus 8 pt so it never covers the window controls or the
  title band that `windowTitleBarMetrics` describes (our call). Only the panel is hit-testable; the alignment container
  around it is not, so clicks elsewhere still land on the islands.
- **Close**: Esc in the field (an `onKeyPress(.escape)` on the field, which is focused, so it runs before any other Esc
  handler), ⇧⌘P again, a run, or focus loss (`onChange(of: focused)` as quick open does). A click elsewhere closes it
  when the click moves focus, which every focusable island does. A click on non-focusable chrome leaves it open, as
  with quick open today (our call: no full-window scrim, which would add an element and swallow the click).
- **View**: `CommandPaletteView`, a field plus `ScrollView { LazyVStack { … } }` capped at 50 rows (MetalUI has
  `LazyVStack`). Each row's title is a `Text(AttributedString)` with the matched ranges in the accent ink; the shortcut
  is a second `Text`.
- **Submit**: look the command up again by id, then `hide()`, then `registry.run(id:)`, which re-checks `isEnabled()`.
  A missing id (a plugin unloaded) or a disabled command does nothing and the palette still closes.
- **Focus after close**: MetalUI drops focus when the focused field leaves the tree and does not restore it (its
  probe F2 matches SwiftUI), the same as quick open today. Commands do not depend on keyboard focus: Alloy's commands
  act on the workspace's own pane model (`workspace.defaultPane`, the focused group), which the palette never changes,
  so a command run from the palette hits the same target as from the menu. Putting keyboard focus back where it was is
  MetalUI gap 2; the palette ships with quick open's behaviour until it lands, with no Alloy-side substitute.
- **Commands that open something** (Settings window, the dirty-tab prompt) run after `hide()` in the same action, so
  whatever focus they set is the last focus write of that frame. Gap 2 asks MetalUI to skip a restore when something
  else took focus in the same frame.
- **IME**: ⇧⌘P is a menu command shortcut. MetalUI runs the command stage only after the focused view declined the key,
  and a field mid-composition owns every key, so the palette never opens mid-composition. Inside the palette field,
  composition works like any text field; ↩ while composing commits the composition, not a run, because the field
  claims the key first.

### Fuzzy matching

`FuzzyMatch` gains `scoreWords(_:in:)` and `topIndices(query:in:limit:) -> [(index: Int, score: Int, matched:
[Range<Int>])]`, beside the unchanged path scoring (quick open and the composer are unaffected). Bonuses: the first
character, after a space, after ": ", and at an ASCII lower-to-upper transition. Like the path scorer it works on UTF-8
bytes with ASCII-only case folding (our call): a non-ASCII query matches the same bytes case-sensitively, and a
multi-byte character only matches whole. Matched byte ranges map back to `AttributedString` ranges through UTF-8
offsets, which never split a scalar because a match is either a whole ASCII byte or whole multi-byte sequences of the
query. A recent command adds a fixed bonus smaller than one word-start bonus, so it reorders only near-ties.

Ranking runs on the main actor (our call). The list is at most a few hundred entries, so there is no off-main ranking,
generation ticket or `rankGate`; quick open needs those only because it scores tens of thousands of paths.

### Data flow

⇧⌘P → `registry.run(id: "view.commandPalette")` → `palette.show`. Show snapshots the registry once into
`[PaletteEntry]` (id, "Category: Title", shortcut display text, enabled flag evaluated now) and builds the empty-query
rows from the workspace's recents. Each keystroke calls `setQuery`, which ranks the snapshot and writes `rows`; only the
palette subtree reruns. Enabled flags are not re-evaluated while the palette is open (our call); a flag that went stale
is caught by the re-check at submit. ↩ runs as described under Submit.

### Persistence

Recents live in the workspace and in `ui-state.json` (Decision 3 option a):

- `UIState.recentCommands: [String]`, ids newest first, cap 10. Decoded with `(try? c.decodeIfPresent(...)) ?? []`,
  like every later field, so a missing or malformed value yields an empty list and never makes the file `.corrupt` or
  resets the rest of the UI state. `UIState.currentVersion` stays 1: adding a tolerant field is the documented pattern
  in `UIState.swift` and needs no bump.
- `Workspace.recentCommands`, `@ObservationIgnored` because only the palette reads it, at open. `noteCommandRun(id:)`
  moves the id to the front; if it was already first nothing changes and no write is scheduled. Otherwise it calls the
  workspace's existing `scheduleUIStateWrite()` (0.5 s debounce in `Workspace+UIState.swift`). `currentUIState()` and
  `apply(_:)` carry the field. `UIStateSplitStore` is not involved.
- Unknown ids (an unloaded plugin) are kept and skipped when shown, so they come back when it reloads; only the cap
  trims them.

### Settings

If Decision 2 is (a): `AlloySettings.paletteShowsDisabled: Bool`, default true, decoded if present. Settings shows one
toggle, "Show unavailable commands in the command palette", id `settings-palette-show-disabled`.

### Accessibility ids

`command-palette` (container), `command-palette-field`, `command-palette-row-<i>`, `command-palette-row-<i>-shortcut`,
`command-palette-recent-header`, `command-palette-empty`, `view-command-palette` (the menu item), the existing menu and
`global-key-*` ids unchanged, `menu-<id>` and `global-key-<id>` for commands without an explicit id, and
`settings-palette-show-disabled`. Disabled rows carry the accessibility value "unavailable".

### Failure modes

- The workspace has gone, or the command is disabled at submit: `run(id:)` returns false and does nothing.
- A plugin registers a duplicate id or shortcut: `.rejected`, noted in `rejections`; the earlier command wins.
- A plugin unregisters while the palette is open: its rows stay until the next keystroke re-ranks the snapshot; ↩ on
  one does nothing (lookup fails). The snapshot is not rebuilt mid-session (our call).
- A plugin unregisters during its own `run`: safe, the closure was copied out first.
- The palette is open and ⌘P is pressed: Quick Open's run hides the palette, then shows quick open.
- ⌘W while the palette or quick open is open: Close Tab is disabled, so the key is consumed and nothing closes.
- Esc: the focused palette field handles it first. Quick open and the palette are never open together, and the file
  panel's Esc only runs when the file panel is focused.
- ⇧⌘P from the Settings window: the project window comes forward, then the palette opens there.
- In the chooser: the menu item is greyed; ⇧⌘P does nothing.
- Recents in a corrupt state: see Persistence; only `recentCommands` falls back to empty.
- A plugin closure that blocks or traps: documented limit above; isolation belongs to the plugin feature.
- One project window per process: `LauncherModel` holds one workspace, so one `CommandCenter` holds one palette. If
  Alloy later gains several project windows, the palette and quick open move to a per-window owner; the registry stays
  app-wide.

## Performance plan

How idle and typing stay at zero cost:

- Closed: `PaletteLayer` reads one Bool and produces nothing. It reruns only when `isShowing` flips. `AlloyScreen` reads
  nothing of the registry or the palette. `GlobalKeys` reruns only on a mode switch (as today) or a plugin
  register/unregister. Steady keystroke frames are unchanged (Chat 88, Code 91/107/117) and idle frames cost 0.
- Menus: evaluated only when MetalUI needs the bar, as today. The loops walk a flat array of a few dozen entries,
  the same work as the hand-written builder.
- Open and typing: work is confined to the palette subtree; ranking a few hundred strings on the main actor; rows in a
  `LazyVStack` capped at 50.
- Running commands: no disk write per run. A write is scheduled only when the recents order changes, debounced 0.5 s,
  and repeatable commands never record.

Guards:

1. Before any migration, task 3 records the current guard numbers and the `GlobalKeys` element count in its notes;
   the migrated code must match them exactly.
2. `ViewRerunTests`: Chat steady count stays 88 with the registry wired and the palette closed; `AlloyScreen` and
   `SidebarView` reruns stay 0.
3. `CodeModePerformanceTests`: 91/107/117 unchanged with the generated menus and `GlobalKeys`.
4. New `CommandPalettePerformanceTests`: after open and close the steady count returns to its baseline (no leaked
   elements); typing 20 keys into the open palette leaves `AlloyScreen` reruns at 0; registering a plugin command
   reruns `GlobalKeys` once and `AlloyScreen` zero times; running ⌃Tab 20 times schedules no UI-state write.
5. An idle-frame test: open the palette, let it settle, and assert no further frame is requested.
6. Ranking speed: a 2,000-command ranking benchmark lives in the existing `Bench` package (release build), target
   under 2 ms. `swift test` keeps only a loose debug smoke bound (under 50 ms) so it cannot flake (our call).

## MetalUI gaps (forward to the MetalUI session)

1. **Public shortcut display text.** MetalUI formats shortcuts for drawn menus in `MenuPanel.swift`
   (`static func shortcutText`, internal), which takes a `PlatformKeyEquivalent?` and a `TextEditing.Platform`: ⌘
   glyphs on macOS; on Linux and Windows `.primary` reads Ctrl and `.command` reads the platform's super-key name
   ("Super" or "Win"). Wanted: `extension KeyboardShortcut { public var displayText: String }` going through that same
   path for the current platform, plus `public func displayText(for platform: TextEditing.Platform) -> String` so a
   macOS test can check the Linux and Windows forms. SwiftUI has no direct equivalent (the system draws the shortcut in
   a menu). Blocks Goal 4: rows ship without the shortcut column, behind one call site, until it lands.
2. **Focus restore when a focused overlay goes away.** Today, removing the focused element through an `if` drops focus
   and does not restore it (matching SwiftUI's probe F2). Wanted: a modifier such as
   `.restoresFocusOnDismiss()` on a subtree: when the subtree that holds focus leaves the tree, focus returns to the
   element that was focused when the subtree first took focus, if that element is still produced and nothing else took
   focus in the same frame. The nearest SwiftUI equivalents are `focusScope(_:)` with
   `@Environment(\.resetFocus)` and `prefersDefaultFocus(_:in:)` on macOS, or a `.popover`/`.sheet` returning focus to
   its presenter. Quick open would adopt it too. Not blocking: without it the palette behaves like quick open.
3. **Confirm** that `KeyboardShortcut("p", modifiers: [.primary, .shift])` as a `CommandMenu` item matches ⇧⌘P on
   macOS and Ctrl+Shift+P on SDL platforms (`KeyboardShortcut.swift` compares `charactersIgnoringModifiers`
   lower-cased, so it should). Ask for a probe test on the SDL path, including the shifted character.
4. **Shortcuts the standard menus own.** Wanted: a public read of the key equivalents MetalUI's default menu bar
   claims on the current platform, for example `public static var standardShortcuts: [KeyboardShortcut]` on
   `CommandGroupPlacement` or `App`, so the registry can refuse a plugin shortcut that would collide with ⌘Q, ⌘C, ⌘V
   and the rest. SwiftUI has no equivalent. Until it lands, plugin shortcuts are not bound (see Clash rule).
5. **Not needed:** a public read of the evaluated `MenuBarModel` (`Commands.swift`, internal). Approach 1 avoids it.
   Tell the MetalUI session it is declined, so it is not built speculatively.

## Testing strategy

- **AlloyCoreTests**: `FuzzyMatchTests` for word-start, ": " and capital bonuses, `topIndices` ordering and ties, a
  non-ASCII query and the matched ranges. `CommandDescriptor` codable round trip. `UIState` decodes without
  `recentCommands`, decodes a malformed `recentCommands` to empty while keeping the other fields, and caps at 10.
- **AlloyKitTests/CommandRegistryTests**: register, `unregister(source:)`, id and shortcut clash (built-in vs plugin,
  plugin vs plugin), plugin shortcut dropped while gap 4 is open, `revision` bumps, `run(id:)` refuses a disabled or
  missing command, unregister during run, recents recorded only when `recordsRecent` and only when the order changes.
- **AlloyKitTests/CommandPaletteTests** (rig from `QuickOpenTests`): ⇧⌘P opens in Chat and in Code mode; ⇧⌘P again
  closes; ⇧⌘P in the chooser does nothing; ⇧⌘P mid-IME-composition does not open (mirroring the existing `GlobalKeys`
  composition test); "spl r" selects View: Split Right and ↩ splits and closes; Esc and focus loss close; a disabled
  row is greyed and ↩ does nothing; the empty query shows recents first, with fewer than 5 and with an unknown id; ⌘P
  while open swaps to quick open; ⌘W while open closes no tab; a plugin command unregistered while open does nothing
  on ↩.
- **Registry parity test**: for both `installAlloyMenu` variants, walk the presented menu and assert every item maps to
  a registry id with the same title, shortcut and accessibility id, and every command with a `menu` placement is in
  the bar; drive every `.global` command's key and assert it ran through `run(id:)`.
- **Shortcut regression**: every existing key and menu test (⌘P, ⌘W, ⌃Tab, ⌘1-9, ⌘N in both modes, F12 with and
  without a focused code view, ⇧⌘C, ⌘\, ⌘,) passes unchanged.
- **Plugins**: a test-only fake source registers commands with and without a menu placement; they appear in the
  palette and the "Plugins" menu, the menu disappears when the source unregisters.
- Performance guards as above. All runs use `swift test --no-parallel`.

## Suggested task breakdown

Each task is independently reviewable and lands green.

1. **FuzzyMatch word scoring.** `scoreWords`, `topIndices`, tests. No UI.
2. **Command model and registry.** `CommandDescriptor`, `CommandRegistry`, `run(id:)`, the clash rule,
   `UIState.recentCommands` and `Workspace.recentCommands`, tests. Not wired.
3. **Command center, built-ins and generated menus and keys.** First record the baseline guard numbers and the
   `GlobalKeys` element count. Then `CommandCenter` (with quick open moved into it), `BuiltinCommands`, the new
   `alloyCommands` signature in `main.swift` and the test helpers, the generated `GlobalKeys`, the parity test, and all
   existing tests and guards unchanged. The riskiest task; review it alone.
4. **Palette UI.** `CommandPaletteModel`, `CommandPaletteView`, `PaletteLayer`, the View menu item, palette tests and
   perf guards. Rows ship without the shortcut column until MetalUI gap 1 lands; adding it is one call site.
5. **Disabled-command setting.** Only if Decision 2 is (a).
6. **Plugin seam test.** The fake plugin source and the "Plugins" menu tests.

Tasks 1 and 2 run in parallel. Task 3 needs 2. Task 4 needs 1 and 3. Tasks 5 and 6 need 4 and can run in parallel.

## Decisions for the user

1. **Registry source.** (a) An Alloy-side registry that generates the menus, the global keys and the palette
   (recommended: no new MetalUI read API, covers non-menu commands and plugins). (b) Read the menu bar back from
   MetalUI (a new MetalUI API, and it misses non-menu commands).
2. **Disabled commands.** (a) Show them greyed, with a setting to hide them (recommended: discoverable, the setting is
   cheap). (b) Always greyed, no setting. (c) Always hidden. Changes whether task 5 exists.
3. **Recents scope.** (a) Per project in `ui-state.json` (recommended: habits differ per project, and the save path
   exists). (b) App-wide in `AlloySettings`.
4. **What counts as "used".** (a) Any run of a recording command, from the palette, a menu or a shortcut (recommended:
   "recent" means what the user actually does; repeatable navigation is already excluded). (b) Palette runs only
   (closer to VS Code; the list fills more slowly).
5. **Plugin menu placement.** (a) Plugin commands appear in the palette, plus a "Plugins" menu when a plugin asks for
   one (recommended). (b) Plugins may add items to any built-in menu (more flexible, but needs ordering rules and
   widens shortcut clashes).


## Approved decisions (2026-11-16)

The user approved every recommendation above ("Approved build it"). Binding:
- 1(a) one Alloy-side registry generates menus, global keys, palette, shortcut settings and plugin commands. It is built first, as its own feature ("registry"), merging this design's command model with editor-essentials.md's registry section; where they differ, this design's command model wins and the editor-essentials binding/override fields are added to it.
- 2(a) disabled commands greyed, with a setting to hide them. 3(a) recents per project in ui-state.json.
- 4(a) any run of a recording command counts. 5(a) plugin commands in the palette plus a Plugins menu.
