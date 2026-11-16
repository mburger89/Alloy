# Alloy: Plugins

Date: 2026-11-15. Status: draft for the user's review, revised after the builder cross-check. Builds on LSP v1
(`2026-11-12-alloy-lsp-design.md`), Code mode (`2026-11-15-alloy-code-mode-design.md`), linters
(`2026-11-15-alloy-linters-design.md`) and, from this batch, the command palette spec (which owns `CommandRegistry`)
and the terminal spec (which task commands run in).

## Intent and why

The user asked for "a plugin capability": Alloy should be extendable without editing Alloy itself. The plugin model is
the biggest decision here, because it fixes what plugins can do, what they can break, and what Alloy has to keep stable.
The standing goal still holds: "MetalUI and Alloy run as lite and fast as possible without giving up quality". So a
plugin must never stall typing, never add frame cost, and cost nothing while idle.

Alloy has no command registry today. The command palette spec in this batch builds one (`CommandRegistry` with
`register(_:)` and `unregister(source:)`, `CommandSource.plugin(id:)`, and a "Plugins" menu). This spec does **not**
build a second registry or a palette: plugin commands go into that registry, and the palette lists them.

## Approaches

1. **Declarative packages only.** A package is a folder with a manifest and data: themes, language-server configs,
   settings defaults, and task commands. No plugin code runs inside Alloy. It is the safest model and easy to version.
   Its weakness is that a package cannot react to events, add panels, decorate the editor or read state. Note that
   "no code" is not "no processes": a server config makes Alloy spawn a language server, and a task command runs a
   shell command, so both need the `process.spawn` grant.
2. **Out-of-process scripted plugins over JSON-RPC (LSP-like), with declarative packages as the no-code subset.
   Recommended.** One manifest format covers both: a manifest with no `main` is a pure package (option 1); a manifest
   with `main` also starts a child process that speaks JSON-RPC over stdio. That process can run commands, render
   panels in a closed widget vocabulary, set editor decorations, subscribe to events, and serve MCP tools. Alloy
   already has the framing, `JSONRPCConnection` (bounded write queue, request timeouts, cancel) and `ServerProcess`
   (stderr tail, SIGTERM then SIGKILL) in `AlloyLSP`; this project moves them to a shared target. A plugin that
   crashes or hangs is a dead child process: Alloy kills it, typing goes on, its decorations are removed. Plugins can
   be written in any language. The costs are designing and versioning the protocol, and UI that is limited to the
   vocabulary.
3. **In-process plugins (dylib or WASM).** A dylib runs on Alloy's threads: a crash takes the app down, a hang on the
   main actor stalls typing, and it cannot be killed. It also breaks the Swift 6 strict-concurrency boundary and would
   need a stable Swift ABI for Alloy's types. WASM avoids the crashes but needs a runtime nobody has written for this
   repo, adds memory, and still runs inside the frame budget. **Rejected.** WASM could come later as a second runtime
   behind the same protocol (our call).
4. **Interop with Claude Code plugins, skills and MCP.** Hosted sessions already load the user's own Claude plugins,
   skills and MCP servers, because Alloy launches the CLI, which reads its own config. Alloy adds nothing there. What
   Alloy can add: Alloy plugins that offer MCP tools to sessions through Alloy's local MCP server, and plugin events
   from Alloy's existing tool hooks. Installing into Claude's config is forbidden by the standing rule. **Adopted as a
   part of option 2, not as its own model** (our call).

Recommendation: **option 2 with option 4's MCP contribution**. Option 1 ships first as the zero-code tier of the same
manifest.

## Goals

1. **One manifest, two tiers.** `alloy-plugin.json` holds `id` (reverse-DNS, `[a-z0-9.-]`, max 100 chars), `name`,
   `version` (semver), `apiVersion` (protocol major), `description`, `contributes`, `permissions`,
   `activationEvents`, and optional `main` (`command`, `args`). `contributes` holds `themes`, `languageServers`,
   `settings` (schema), `commands`, `taskCommands`, `panels` and `mcpTools`. A package without `main` never starts a
   plugin process. Everything a plugin contributes is declared in the manifest, so Alloy can list it, show it in the
   palette and gate it without starting the process (our call).
2. **Install, enable, disable, update, remove.** Plugins live in `<appSupport>/Plugins/<id>/`. Sources: a local folder
   (copied in) and, if Decision 3 says so, a git URL at a tag. **Install never runs plugin code and never enables.**
   There is no build step: a plugin ships runnable (a script with an interpreter on `PATH`, or a prebuilt binary)
   (our call). Enabling shows the declared permissions and needs one click to grant them. Removing deletes the folder
   and the settings entry. The user's settings hold the enable flag, version, source and grants, never the plugin.
3. **Commands in the shared registry.** On enable, each manifest command is registered with
   `CommandSource.plugin(id:)`; on disable, remove or auto-disable, `unregister(source:)` removes them. A command's
   run starts the plugin if needed (`onCommand`) and sends `commands/execute`. Placement in the "Plugins" menu follows
   the palette spec's Decision 5.
4. **Settings.** A `PluginsSection` in Settings sits after Language Servers and has one row per plugin: name, version,
   source (folder path or git URL plus tag), enable toggle, permissions summary, status (not started / running /
   stopped / crashed n times / disabled after crashes / needs API vN / sandbox unavailable / bad manifest), and Log,
   Update and Remove buttons. Plugin-declared settings render from a declarative schema (bool, string, enum, number)
   as a disclosure under the row and are stored under `plugins[id].values`. There is no `secret` type in v1 (our
   call): Alloy has no Keychain code and no Linux/Windows credential store, so a plugin that needs a token reads its
   own environment or config.
5. **Contributions a scripted plugin can make** (protocol v1):
   - `commands/execute` (Alloy to plugin) for manifest commands.
   - `decorations/set {uri, version, items}`: line-level only in v1: line background, gutter bar, gutter marker, and a
     message row under a line (a `CodeVirtualRow`). These are what MetalUI's `CodeDecorations` already takes per
     owner (`setLineDecorations(_:asOf:owner:)`, `setVirtualRows(_:asOf:owner:)`). Range underlines and range tints
     wait for MetalUI gap 1 (range highlights have layers but no owner, so a plugin would overwrite LSP
     diagnostics). Capped at 500 items per document per plugin.
   - `panel/render {panelId, tree}`: a manifest-declared panel shown as a tab in the Code mode sidebar tab row
     (`CodeSidebarView` has the row today, with Files; search and git add their own tabs), described in the closed
     widget vocabulary (Text, Button, Toggle, TextField, Picker, List of rows, VStack/HStack, Divider), capped at 300
     elements (our call). UI events come back as `panel/event`.
   - `window/showMessage` as a toast, at most 1 per 5 s per plugin.
   - `document/text {uri}` (needs `project.read`): the open buffer's current text and version.
   - `project/read`, `project/write` (grants below).
   - `state/get|set`: per-project plugin state (see Persistence).
   - `mcp/call`: Alloy to plugin, when a Claude session calls one of the plugin's manifest `mcpTools`.
   - Events, all notifications, listed under "Events".
6. **Permissions.** Declared in the manifest, granted at enable time, stored in `plugins[id].grants`:
   `project.read`, `project.write`, `network`, `process.spawn`, `sessions.read`, `mcp.tools`. Alloy enforces at the
   protocol: a request that needs a missing grant fails with JSON-RPC error `-32003` ("permission denied", data
   `{permission}`). Grants apply to both tiers: theme-only packages need none; `languageServers` and `taskCommands`
   need `process.spawn`. The OS boundary depends on Decision 2. No plugin ever gets a write path into `~/.claude` or
   any `.claude/`, whatever its grants. A plugin cannot send text to a Claude session in v1 (our call: no
   `sessions.message`; Claude reaches a plugin only by calling its MCP tools, which removes the prompt-injection and
   rate-limit questions from v1).
7. **Status and logs.** A plugin's stderr tail (64 KiB, as `ServerProcess` keeps) and its last error show in a "Show
   log" sheet from its Settings row. The tail is kept in memory only, never written to disk, and passed through a
   redaction pass before display (`Bearer …`, `sk-…`, `ghp_…`/`github_pat_…`, `xox…-`, `AKIA…`, and any 32+ char
   token of base64/hex characters become `‹redacted›`) (our call).

## Calls settled after the builder check (our calls)

1. **Extract `AlloyRPC` from `AlloyLSP`, with renames.** Move `Framing.swift`, `JSONRPCConnection.swift` and
   `ServerProcess.swift` into a new `AlloyRPC` target that depends on `AlloyCore` (for `JSONValue`; `AlloyCore`
   carries only `MetalUICodeBuffer`, so this adds no weight). Generic names: `LSPFrameDecoder` → `RPCFrameDecoder`,
   `LSPFrame` → `RPCFrame`, `LSPFramingError` → `RPCFramingError`, `LSPByteChannel` → `RPCByteChannel`.
   `JSONRPCConnection`, `JSONRPCError` and `ServerProcess` keep their names. `AlloyLSP`, `AlloyFakeLSP`,
   `AlloyLSPTestSupport` and the LSP tests import `AlloyRPC` and use the new names; no typealiases are left behind.
   Behaviour is unchanged and the LSP tests stay green. `ServerProcess` gains one option, `processGroup: Bool`
   (default false, so LSP is unchanged), that spawns the child as a process-group leader and signals the group.
2. **`AlloyPlugins` does not depend on `AlloyLSP`.** `ServerRegistry` and `ServerLocator` stay in `AlloyLSP` (which
   pulls in tree-sitter through `AlloyHighlight`). A package's `languageServers` entries decode into
   `ServerConfigOverride` values, which already live in `AlloyCore`. `LSPCoordinator.reload(overrides:)` (AlloyKit)
   receives one merged dictionary: plugin entries first, then the user's `languageServers` applied over them field by
   field. So the order is built-in < plugin < user. Two plugins naming the same server id: the first enabled wins,
   and Settings shows the clash on the second. `AlloyPlugins` depends on `AlloyCore` and `AlloyRPC`; `AlloyKit`
   depends on `AlloyPlugins`.
3. **Coordinator shape copies `LSPCoordinator`.** `PluginCoordinator` (@MainActor, AlloyKit) pumps an ordered
   `AsyncStream<Command>` to an off-main `PluginHost` actor (AlloyPlugins). Only `PluginStatusModel` (read by the
   Settings section only) and per-target snapshot stores are observable; handlers are `@ObservationIgnored`.
   `PluginCoordinator` is not read by `AlloyScreen`, the root view or the menu builder.
4. **One host per app.** Alloy shows one workspace at a time. On a workspace switch the host sends
   `workspace/closed`, cancels every in-flight request for the old project (they answer `-32800`), stops plugins
   whose last activation was project-bound, and sends `workspace/opened` for the new one.
5. **The linters "no trust gate" decision does not carry over.** That decision covers the user's own project configs.
   Plugins are third-party code, so enabling is always a gate.
6. **Dynamic menu content needs no MetalUI change (verified).** MetalUI's `CommandMenu` content is "evaluated afresh
   whenever the bar is shown or a key reaches the command stage", and `App` hands each window
   `enabledCommandShortcuts()` re-read "at each keystroke that gets that far", so an item's `.keyboardShortcut` fires
   for an item added at runtime. A test proves it (see Testing).
7. **Plugin shortcuts are suggestions, bound only once MetalUI gap 2 lands.** Until then a plugin command is reachable
   from the palette and the menu with no key binding, and Settings shows the proposed key as "not bound". After gap 2,
   a proposed key is bound only if it collides with nothing in the registry and nothing in MetalUI's bound shortcuts;
   a collision drops it and Settings says with what.
8. **Command enablement.** A manifest command may carry `when`, a closed set: `always` (default), `codeMode`,
   `editorFocused`, `language:<id>`. It maps to the registry's `isEnabled` closure. No expression language.
9. **Language ids.** `onLanguage:<id>` and `language:<id>` use `ServerRegistry.languageID(forPath:)` when a server
   covers the file, else the highlight grammar's name (`swift`, `python`, `typescript`, …). The coordinator computes it
   once per document open, not per keystroke.
10. **Activation events.** `activationEvents` is optional. Allowed: `onCommand:<id>`, `onLanguage:<id>`,
    `onPanel:<id>`, `onMcpTool:<name>`, `onStartup`. Commands, panels and MCP tools imply their own activation, so a
    plugin with none listed starts on first use. `onStartup` plugins start after the first frame is shown and the
    file index has loaded, at most 3 of them, in enable order; the rest start on their next other event.
11. **Running-plugin cap and idle stop.** At most 8 scripted plugin processes run at once; starting a 9th stops the
    one with the oldest last message. A plugin with no request, event or panel on screen for 10 minutes is stopped
    and restarts on its next activation (our call; it keeps RAM and the process count down).
12. **Events.** Payloads (all notifications, never a request, so Alloy never waits on a plugin):
    - `workspace/opened|closed {root}`.
    - `document/opened {uri, languageId, version}`, `document/saved {uri, version}`, `document/closed {uri}`,
      `document/renamed {oldUri, newUri}` (the file tree rename and external moves the watcher sees; a delete is
      `closed`). Sent only with `project.read`.
    - `session/turnEnded {sessionId, isError}`: sent when a session's wire delivers `.result(TurnResult)`.
      `session/ended {sessionId}`: sent when the session process ends (where `Workspace` marks it stopped or failed;
      not `noteSessionEnded`, which only posts the "Session has ended" notice on a later send).
    - `claude/toolUsed {sessionId, toolName, paths}`: from the existing PostToolUse hook route.
    Session and Claude events go only to plugins with `sessions.read`, for every session in the open project.
    Each notification is encoded once and the same bytes are written to every subscribed plugin.
13. **Hook forwarding sits beside the overlap handler, not inside its deadline.** Today `LocalServer` has one hook
    handler (`OverlapHook`), run against `hookDeadline` (1 s) through `LocalServer.race`, and the CLI waits at most
    `Hooks.timeoutSeconds` (3 s). The hooks only fire for `Hooks.matcher` (`Edit|MultiEdit|Write|NotebookEdit`).
    Plugins only observe: after the overlap handler returns, the hook handler enqueues one `claude/toolUsed` event to
    the plugin host and returns at once. A plugin never adds context to a hook reply and never delays one. The event
    therefore covers edit tools only in v1.
14. **MCP tools.** `MCPToolScope` becomes `enum MCPToolScope: Hashable, Sendable { case shared, theme,
    plugin(String) }` (it loses `String` raw values; the builder updates any raw-value use). A plugin's
    `mcpTools` are declared in the manifest, so they are listed without starting the process; each is a
    `PluginMCPTool` proxy whose `scope` is `.plugin(id)` and whose `call` sends `mcp/call` (10 s timeout; a timeout
    returns an `isError` result). Tool names are `p_<short>_<name>`, where `<short>` is a stable 6-char hash of the
    plugin id, so two plugins cannot collide with each other or with Alloy's tools. The tool list Alloy's MCP server
    serves is rebuilt from the enabled plugins on enable/disable, not per call. Granting `mcp.tools` is the allow:
    every session started in the project after that holds the plugin's scope; a session started earlier sees the
    tools after it restarts, and the Settings row says so. No per-session allow-list screen in v1. Revoking the grant
    or disabling removes the scope from every live token at once, so a later call is refused.
15. **`project.write` semantics.** `project/write {path, text}` takes a project-relative path (absolute paths, `..`
    and symlinks resolving outside the root or into any `.claude/` are refused). It writes atomically, like autosave,
    and the file watcher then treats it like any outside edit: clean open buffers reload, the ledger records an outside
    change, and diff review shows it like other outside edits. It is refused with `-32010` and data `{reason}` when
    `reason` is `dirty` (an open buffer has unsaved edits), `claudeEditing` (a Claude session has a pending proposed
    change on the path, from `ProposedChange`), `outsideProject` or `protectedPath`.
16. **Decorations across views.** The store is keyed by `(plugin, uri)`. Every open view of that document
    (`OpenDocumentView`, one per pane) applies the same snapshot to its own `CodeDecorations` under
    `CodeDecorationOwner("plugin.<id>", priority: -10)`. Alloy's diff and diagnostics paint under the default owner
    (priority 0), and the git spec's `git` owner sits at its own priority, so plugins always lose a shared row's tint,
    bar and marker (new rule, stated here). `version` is the one the plugin was last told (`document/opened` or
    `saved`); MetalUI shifts line decorations forward through edits since and drops them if its edit log no longer
    reaches back. A `decorations/set` for a uri that is not open is dropped (no buffering). On close, rename and
    plugin stop, the owner's decorations are removed (`removeDecorations(of:)`).
17. **Panels.** Every widget in a tree needs a `key`, unique within the panel; a duplicate key rejects the whole tree
    with an error toast to the log. Rendering diffs by key, so focus and scroll survive a re-render. A TextField's text
    is owned by Alloy while it has focus: a re-render never overwrites a focused field, and the plugin gets
    `panel/event {key, kind: "changed", value}` 300 ms after typing in the field stops, and `kind: "submit"` on Return.
    No round trip per keystroke. A panel whose tab is not selected has no element and no task.
18. **Per-project state lives in its own files, not `ui-state.json`.** `state/get|set` reads and writes
    `plugin-state/<id>.json` in the project's store directory (next to `ui-state.json`), capped at 64 KiB per plugin,
    written with a 1 s debounce. `ui-state.json` and its "a newer file is never overwritten" rule are untouched.
19. **Settings decoding.** `AlloySettings` gains `plugins: [String: PluginSetting]` with its own lossy wrapper, the
    same shape as `LossyOverride` for `languageServers`, so a bad entry drops that entry only. Grants in
    `settings.json` are honoured as written: the file is the user's, outside every project.
20. **Contributions follow the plugin live.** Disable, remove and auto-disable unregister commands, drop the plugin's
    MCP scope, remove its decorations and panel tab, remove its server configs (the coordinator reloads, which stops
    those servers) and its themes. A theme in use that disappears falls back to the default built-in theme, as a
    deleted user theme file does. Theme packs add a third list to `ThemeLibrary` beside built-ins and user themes,
    tagged with the plugin id; a name clash goes user, then built-in, then first-enabled plugin.

## Design

**Layout.** Plugin commands appear in the palette (from the palette spec) with the plugin's name as category:

```
 ┌──────────────────────────────────────────────┐
 │ > format                                     │
 ├──────────────────────────────────────────────┤
 │ Prettier: Format Document                    │
 │ Prettier: Format Selection                   │
 │ Go: Go to Definition                  F12    │
 └──────────────────────────────────────────────┘
```

Settings → Plugins:

```
 Plugins                                    [Install…]
 ┌──────────────────────────────────────────────────┐
 │ [x] Prettier 1.2.0   running   project.read,     │
 │     process.spawn          [Log] [Update] [Remove]│
 │ [ ] Todo Panel 0.3.1 disabled after 3 crashes    │
 └──────────────────────────────────────────────────┘
```

**Data flow.** Plugin process → `JSONRPCConnection` → `PluginHost` (off main; validates grants and caps, keeps the
latest decorations per `(plugin, uri)` and the latest tree per `(plugin, panelId)`) → for each plugin, at most one
snapshot hop to the main actor per document every 250 ms, and only when the content differs from the last applied
snapshot → `PluginDecorationStore` / `PluginPanelStore` → applied imperatively to each view's `CodeDecorations`
(decorations, no view body reruns) or read by the panel view (Equatable on the tree snapshot). In the other
direction, events go out as notifications through the connection's bounded write queue. **No event is dropped**: if a
plugin stops reading stdin and the queue fills (1 MiB), the plugin is treated as hung and restarted (our call), so
`opened`/`closed` order is never broken.

**Lifecycle.** Nothing plugin-related exists until a plugin is enabled; with only declarative packages enabled, no
host actor exists either (their contributions are merged at load). The host starts a process on its first activation
event. `initialize` uses the LSP-style handshake with `apiVersion` and the granted permissions; a major mismatch means
the plugin is not started and Settings says "needs API vN". The protocol contract says a plugin exits when its stdin
closes, so a crashed or force-quit Alloy leaves no live plugin that follows the contract. Each process is a
process-group leader (POSIX) or in a job object (Windows), and stop sends SIGTERM to the group, then SIGKILL after 2 s.
Alloy records running groups (pid plus start time) in `<appSupport>/Plugins/.running`; at launch it kills any group
from that file whose start time still matches, then clears the file.

**Install and update details** (folder install always; git if Decision 3 picks it; all our calls).
- Folder install copies into a staging folder without following symlinks; any symlink that resolves outside the
  plugin folder fails the install. The manifest is validated in staging, then the folder is moved into place.
- `main.command` is either a path relative to the plugin folder (resolved with symlinks; must stay inside the
  folder; must exist and be executable) or a bare program name found on `PATH` (an interpreter such as `node` or
  `python3`, with the script in `args`). Anything else is a bad manifest.
- An `id` that is already installed from a different source is refused ("already installed from …"); the Settings
  row and the enable prompt always show the source, so a look-alike id is visible.
- Git install runs the `git` found on `PATH` (the same resolution the git spec uses) with `GIT_TERMINAL_PROMPT=0`,
  an empty `GIT_ASKPASS`, `-c core.hooksPath=` emptied and `--no-recurse-submodules`, as
  `git clone --depth 1 --branch <tag>` into staging, with a 60 s timeout and a 200 MB size cap; a URL that needs
  credentials fails rather than prompts. The commit hash of the tag is recorded.
- Update lists tags with `git ls-remote --tags`, picks the highest semver tag above the installed version, and refuses
  downgrades. A tag whose commit differs from the recorded hash for the same version is shown as "tag moved" and not
  installed. The new version installs into staging; the old folder is kept as `<id>.previous` until the new one
  completes `initialize` once, and is restored if it fails. New permissions leave the plugin disabled until granted.
- Revoking a grant, or a hand edit to `settings.json` that changes grants, stops the running process; it restarts with
  the new grants on its next activation.

**Failure modes.**
- Crash: restart with backoff (1 s, 5 s, 30 s). After 3 crashes in 10 minutes it is auto-disabled (see call 20) and
  its row says so.
- Hang: each request has a timeout (2 s for UI-facing requests, 10 s otherwise). Three timeouts in a row restart it.
- Chatty: above 200 messages per second a plugin's input is paused for the rest of the second; 5 such seconds in a
  minute restart it. Decorations are capped at 500 per document, toasts at 1 per 5 s, panel trees at 300 elements.
- Polluted stdout (bytes that are not a frame): the decoder error ends the connection, and it counts as a crash.
- Memory and CPU: resident size and CPU time are read through `proc_pid_rusage` (macOS), `/proc/<pid>/stat` (Linux)
  and the job object (Windows). They are sampled off main when the plugin sends a message, at most once per 5 s, and
  by one off-main 5 s timer that exists only while a scripted plugin process is alive; idle stop (call 11) ends it.
  Above the limits (default 500 MB, or 90% of a core for 30 s) the group is killed and it counts as a crash.
- Bad manifest: listed with the error, cannot be enabled. Other plugins are unaffected.
- Sandbox (if Decision 2 picks one): if the profile cannot be built (for example a path the profile language cannot
  quote) or the backend is missing, the plugin is not started and its row says "sandbox unavailable". Fail closed.
  macOS's `sandbox-exec` is deprecated; if a future macOS removes it, plugins needing it stop with that status.

**Accessibility ids.** `menu.plugins`, `menu-<commandId>` (the palette spec's menu id form), `settings.plugins.install`,
`settings.plugins.row.<id>`, `.toggle`, `.log`, `.update`, `.remove`, `settings.plugins.grant.<id>.<permission>`,
`code-sidebar-tab-plugin-<id>-<panelId>`, `plugin.panel.<id>.<panelId>`, and `plugin.panel.<id>.<key>` for each
widget.

**Cross-platform.** The host, protocol, manifest and UI are platform-neutral Swift. Process spawn uses the shared
`ServerProcess`. Process groups use `posix_spawn` with a process group on macOS and Linux and a job object on
Windows. OS confinement (if chosen) has one interface, `PluginSandbox`, with one backend per platform: a
`sandbox-exec` profile on macOS, bubblewrap or Landlock on Linux, an AppContainer plus job object on Windows. Where a
backend is missing, only plugins without `network`/`process.spawn` grants can be enabled. That is a shared rule, not a
substitute design.

## Performance plan

- **Idle is zero.** With no scripted plugin enabled, no host, task, timer or observation exists. With scripted plugins
  enabled but none running, the host is parked on `for await` over its stream. While a plugin process runs, the only
  timer is the off-main 5 s sampler; nothing touches the main actor, so idle frames cost 0. Idle stop ends the timer.
- **Typing is zero.** No event fires per keystroke. Decoration snapshots arrive only when a plugin sends one (after
  open or save), go through MetalUI's per-owner merge, and shift with edits inside MetalUI, so a keystroke reruns
  nothing plugin-related. Panel TextFields talk to the plugin only after typing stops.
- **Not observed from the root.** The registry, `PluginCoordinator` and the stores are never read by `AlloyScreen`
  or the menu builder's body; the menu reads registry entries only when MetalUI evaluates the bar.
- **Guards.** Chat 88 and Code 91/107/117 stay exact with plugins enabled and no plugin panel visible. A visible
  plugin panel tab is extra elements by design; the builder measures it and adds a "panel visible" guard figure, and
  editor typing with a panel visible must not rerun the panel's body.
- **Startup.** No plugin process starts before the first frame. At most 3 `onStartup` plugins; the startup profile
  run records the time with three fake `onStartup` plugins.
- **New guard tests.** (a) `PluginFrameCostTests`: three fake plugins (one slow, one crashing, one sending 1000
  decorations a second) give the exact steady counts 88 and 91/107/117 while typing, including while decorations
  arrive mid-typing. (b) `idleTicksDoNotRunPluginWork`: zero main-actor hops and zero body reruns over 120 idle
  ticks with all three running, the chatty one included once it has nothing new. (c) `PluginHostTests`: no host
  object while no scripted plugin is enabled. (d) `MemoryProbeTests`: the host and three idle plugin connections stay
  under a fixed budget, set by the builder from a measurement. (e) Decoration hops: the chatty plugin produces at most
  4 main-actor hops per second per document.

## Non-goals (this project)

- A plugin marketplace, ratings or signing service.
- A build or install script run by Alloy.
- File-tree badges (v2, after the git spec's per-row status input lands, so badges share it), snippets (v2, after the
  code-intelligence spec's snippet session), range underlines and tints (after MetalUI gap 1).
- Plugins that change text as the user types (completion providers, per-keystroke formatters).
- Plugins sending messages to Claude sessions.
- Arbitrary custom drawing or MetalUI views from plugins.
- Writing anything into Claude Code's config (plugins, skills, hooks, MCP).
- In-process plugin runtimes.

## Anti-goals

- No plugin path on the keystroke-to-frame route; no main-actor await on a plugin.
- No new idle timers when no scripted plugin is running.
- No data loss: `project.write` is refused on dirty buffers and on paths a Claude session is changing.
- A crashing plugin never takes Alloy, a Claude session or another plugin down with it.

## Constraints

MetalUI only, with MetalUI read-only from this project; theme values only, no literal colours (plugin decorations name
theme roles such as `info`, `warning`, `accent`, never colours); accessibility ids on every interactive view; zero
warnings; `swift test --no-parallel`; Linux/Windows mirror the macOS design. Alloy never writes `~/.claude` or a
project's `.claude/`, with the one exception of the user-clicked theme-skill install button. Plugins inherit that rule
and get no path to either. No secrets in manifests, logs or settings.

## MetalUI gaps (forward to the MetalUI session)

1. **Owner-keyed range highlights.** Wanted: `CodeDecorations.setHighlights(_ runs: [CodeStyleRun], in:
   Range<Int>, layer: CodeHighlightLayer, asOf: UInt64, owner: CodeDecorationOwner)` merged per owner by priority
   within a layer (as `setLineDecorations` does), and `removeDecorations(of:)` clearing them too. Today a range run
   has a layer but no owner, so a plugin's underline on `.diagnostics` would replace the language server's. No
   SwiftUI equivalent (closest: AppKit's `NSLayoutManager` temporary attributes). Not blocking: v1 ships line-level
   decorations and adds ranges when this lands.
2. **Read the app's bound command shortcuts.** Wanted: a public `App.boundCommandShortcuts: [KeyboardShortcut]` (the
   keys of the internal `enabledCommandShortcuts()`, without the actions), so Alloy can check a plugin's proposed key
   against MetalUI-built standard items as well as its own registry. No SwiftUI equivalent. Not blocking: plugin
   shortcuts stay unbound until it lands (call 7).

Verified, not gaps: runtime-changed `CommandMenu` content and its `.keyboardShortcut` firing (call 6), owner-keyed
line decorations and virtual rows with priority (`CodeDecorationOwner`), and `removeDecorations(of:)`.

## Testing strategy

- `AlloyFakePlugin` executable (like `AlloyFakeLSP`): scriptable responses, delays, crashes, floods, stdout garbage,
  ignoring SIGTERM, spawning a child, and not reading stdin.
- `AlloyRPCTests`: the moved framing, connection and process tests, plus process-group kill (the fake's child dies).
- `PluginManifestTests`: valid, invalid, unknown keys, version mismatch, `main` outside the folder, missing or
  non-executable `main`, symlink escape, duplicate id from another source.
- `PluginPermissionTests`: denied calls get `-32003`; an update with new permissions stays disabled; a revoked grant
  stops the process; `project/write` refusals for `dirty`, `claudeEditing`, `outsideProject`, `protectedPath`.
- `PluginLifecycleTests` with `ManualClock`: lazy start, backoff, auto-disable removing every contribution, idle
  stop, the 8-process cap, the sampler kill, write-queue overflow restart, stale `.running` cleanup, workspace switch
  cancelling in-flight requests.
- `PluginMenuShortcutTests`: a `Button` with `.keyboardShortcut` added to a `CommandMenu` after launch fires through
  the command stage (MetalUITesting harness).
- Registry tests: enable registers commands under `.plugin(id:)`, disable unregisters, a clash is rejected.
- `SettingsViewTests` for the plugins section, grants, log redaction.
- Decoration tests: caps, priority below diff and diagnostics, two views of one document both painted, decorations
  for an unopened uri dropped, removal on close and stop.
- Panel tests: duplicate key rejected, focused TextField not overwritten, `changed` sent once after typing stops.
- MCP: a plugin tool is visible only to sessions holding `.plugin(id)`, and disabling removes it from live tokens.
- Hook test: the PostToolUse route still answers within `hookDeadline` with a slow plugin subscribed.
- A test asserting no plugin code path writes under `.claude` (temp home injected, like `ThemeSkillInstallerTests`).
- Event fan-out encodes each notification once (counting encoder).

## Suggested task breakdown

1. Extract `AlloyRPC` from `AlloyLSP` with the renames and the process-group option (LSP tests green).
2. Manifest model, validation and path rules, `PluginSetting` with its lossy decoding, plugin folder discovery.
3. Declarative tier: themes and server configs (built-in < plugin < user merge), Settings → Plugins (folder
   install, enable with grants, disable, remove, live removal of contributions).
4. `PluginHost` and `PluginCoordinator`: lazy start, handshake, grants, budgets, process groups, `.running` cleanup,
   sampler, idle stop, `AlloyFakePlugin`, and guard tests (c) and (d).
5. Commands into the shared `CommandRegistry` (needs the palette spec's registry task).
6. Decorations (line-level), with guard tests (a), (b) and (e).
7. Panel vocabulary renderer and sidebar tab.
8. Events, `document/text`, `project/read|write`, `state/get|set`, hook forwarding.
9. MCP tool contribution (`MCPToolScope.plugin`).
10. Task commands, run in a terminal tab (needs the terminal spec's panel).
11. Git install and update (if Decision 3 picks it).
12. OS sandbox backend (if Decision 2 picks it).
13. Range underlines when MetalUI gap 1 lands; bound shortcuts when gap 2 lands.

Tasks 1 and 2 run in parallel. 3 follows 2. 4 follows 1 and 2. 5, 6, 7, 8 and 9 run in parallel after 4. 10 follows
3 and the terminal spec. 11 follows 3. 12 follows 4. Each task lands with its own perf guard, not at the end.

## Left to the builder

The exact JSON schemas of protocol messages, the measured sampler thresholds, the measured "panel visible" guard
figure, the wording of permission prompts, and the redaction pattern list's final form.

## Decisions for the user

1. **Plugin model.** (a) declarative only; (b) declarative + out-of-process JSON-RPC; (c) in-process. **Recommend (b).**
2. **OS-level sandbox in v1.** (a) none: permissions enforced at the protocol only, so a plugin process can read
   anything the user can, and the enable prompt says so; (b) a `sandbox-exec` profile per plugin on macOS now, built
   from its grants, with Linux/Windows backends to follow and the shared "no backend, no network/process.spawn" rule
   meanwhile; (c) refuse `process.spawn`/`network` plugins everywhere until every platform has a backend.
   **Recommend (b)**: the protocol gate alone does not stop a plugin process from reading the home folder. If no
   answer is given, the builder ships (a) with the warning, and task 12 is not started.
3. **Install sources.** (a) local folder only; (b) folder + git URL at a tag (Alloy runs `git`); (c) also a central
   index. **Recommend (b).**
4. **Per-keystroke events.** (a) never in v1; (b) a debounced `document/didChange` (300 ms after typing stops) for
   plugins that ask. **Recommend (a)**, add (b) later behind the frame guard.
5. **Claude interop scope.** (a) none; (b) MCP tool contribution and `claude/toolUsed` events; (c) (b) plus a
   read-only list of each session's Claude plugins and MCP servers in Settings. **Recommend (b)**; (c) only if the
   user wants that view.


## Approved decisions (2026-11-16)

The user approved every recommendation above ("Approved build it"). Binding:
- 1(b) declarative plus out-of-process JSON-RPC. 2(b) macOS sandbox-exec profile per plugin now (task 12 is in scope).
- 3(b) local folder plus git URL at a tag. 4(a) no per-keystroke events in v1.
- 5(b) plugins contribute MCP tools to sessions and receive `claude/toolUsed` / edit events.
- Plugin commands register in the shared `CommandRegistry`.
