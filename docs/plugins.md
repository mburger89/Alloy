# Alloy plugins

A plugin is a folder with an `alloy-plugin.json` manifest. There are two tiers:

- **Declarative** (no `main`): themes, language-server configs, settings and task commands. Nothing of the plugin runs inside Alloy's process; language servers and task commands are launched by Alloy itself.
- **Scripted** (has `main`): an out-of-process JSON-RPC child that adds commands, panels and MCP tools, and can use the events and project access its permissions allow.

Plugins live in Alloy's application-support folder under `Alloy/Plugins/<plugin id>/`; the folder name must equal the plugin id. Hidden folders (`.running`, `.staging`) and `*.previous` update backups are not plugins.

## Manifest

The file is a UTF-8 JSON object of at most 256 KiB. Unknown keys are errors, so a typo is caught instead of ignored.

```json
{
  "id": "dev.example.tool",
  "name": "Example",
  "version": "1.2.3",
  "apiVersion": 1,
  "description": "What it does.",
  "main": { "command": "run.sh", "args": [] },
  "permissions": ["project.read"],
  "activationEvents": ["onCommand:hello"],
  "contributes": { }
}
```

| Key | Rule |
| --- | --- |
| `id` | 1 to 100 characters of `[a-z0-9.-]`, at least one `.`, no leading or trailing `.`, no `..`; equal to the folder name. |
| `name` | 1 to 60 characters after trimming. |
| `version` | `major.minor.patch`, optionally `-prerelease` (`^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$`). |
| `apiVersion` | Integer of 1 or more (default 1). Alloy speaks version 1; a plugin asking for another loads, and Settings › Plugins lists it as "needs API v<N>". |
| `description` | Optional text. |
| `main` | `{command, args?}`. `command` is a file inside the plugin folder (a relative path, symlinks followed, must stay inside and be executable) or a bare interpreter name found executable on the login shell's `PATH` (`node`, `python3`). Absolute paths and paths leaving the folder are refused. |
| `permissions` | Array of the permissions below. |
| `activationEvents` | `onCommand:<id>`, `onLanguage:<id>`, `onPanel:<id>`, `onMcpTool:<name>`, `onStartup`. |
| `contributes` | Object with only the keys below. |

### Contributions

| Key | Shape | Needs |
| --- | --- | --- |
| `themes` | `[{path}]`; relative `.json` path inside the folder | |
| `languageServers` | `{<server id>: <server override>}`; ids match `^[a-z0-9-]{1,64}$`; the value is the same object `settings.json` accepts under `languageServers` | `process.spawn` |
| `settings` | `[{key, title, type: "bool"\|"string"\|"number"\|"enum"\|"secret", options?, default?, env?}]` (see Secret settings); keys match `^[A-Za-z][A-Za-z0-9_.-]{0,63}$`; `options` is a non-empty string array, enum only | |
| `commands` | `[{id, title, shortcut?, menu?: "plugins", when?}]`; registered as `<plugin id>.<id>` in the command palette (category: the plugin's name) and, with `menu: "plugins"`, in the Plugins menu. `when` is `always`, `codeMode`, `editorFocused` or `language:<id>`. A `shortcut` is not bound yet; Settings › Plugins notes it. Running one starts the plugin and sends the request `commands/execute {command: "<id>"}`; an error answer goes to the plugin's log | `main` |
| `taskCommands` | `[{id, title, command, args?, cwd?}]` | `process.spawn` |
| `panels` | `[{id, title}]`; each is a tab in the Code sidebar (see Panels) | `main` |
| `mcpTools` | `[{name, description, inputSchema}]` (see MCP tools); names match `^[a-z0-9_]{1,40}$`; `inputSchema.type` is `"object"` | `main`, `mcp.tools` |

Command, task and panel ids match `^[A-Za-z0-9_-]{1,64}$` and are unique within their kind. A `shortcut` is a chord such as `cmd+shift+h` (the Keyboard settings format). `when` is `always` (default), `codeMode`, `editorFocused` or `language:<id>`.

## Permissions

- `project.read`: read files in the open project.
- `project.write`: write files in the open project, through Alloy only (never the plugin's own file access).
- `network`: outbound network access (scripted plugins; needs a sandbox backend).
- `process.spawn`: start other processes (needs a sandbox backend for scripted plugins; declarative language servers and task commands are launched by Alloy).
- `sessions.read`: receive agent session events.
- `mcp.tools`: expose tools to agent sessions through Alloy's MCP server.

The user approves the manifest's permissions when enabling the plugin; the grants are stored in `settings.json` under `plugins`.

## Installing and enabling

Open Settings and find the Plugins section. **Install...** asks for a folder that holds an `alloy-plugin.json`; Alloy validates the manifest, copies the folder into its plugin directory and lists the plugin as disabled. A bad manifest is refused with its reason shown under the button. Installing the same plugin again keeps its settings.

Switching a plugin on opens a prompt that names the plugin, its version and where it came from, and lists each permission it asks for in plain words. A declarative plugin's prompt also lists the exact commands Alloy will run for it (`Runs: <command> <args>`); a scripted plugin's prompt says it runs with your account's file access. **Enable and grant** stores the grants; Cancel changes nothing. Once enabled, every permission is a toggle: revoking one leaves the plugin listed as "needs new permissions" and stops it until you grant it again.

A plugin's declared settings (switch, text, number or choice) appear in a Settings disclosure under its row. Text and number fields save when you press Return; a number that does not parse is not saved. Remove asks first, then deletes the plugin's folder, data and settings entry. A plugin whose folder was deleted by hand is listed as "folder missing" and can only be removed. A folder placed in the plugin directory by hand, with no settings entry, is listed as "not enabled" and can be enabled or removed. An enabled declarative plugin shows "enabled" (nothing of it runs as a process).

## Lifecycle and handshake

Scripted plugins run today. Until the sandbox exists, permissions are enforced at the protocol only: a plugin process runs with your account's file access and can read or write whatever you can, whatever it was granted.

A scripted plugin's process starts only when one of its activation events fires (never at Alloy launch unless it asks for `onStartup`). It runs as the leader of its own process group, in the plugin's folder, with a minimal environment: `PATH`, `HOME`, `LANG`, `TMPDIR` (the plugin's scratch folder), `ALLOY_PLUGIN_ID` and the plugin's own secret variables. Messages are `Content-Length` framed JSON-RPC 2.0 over stdin and stdout; stderr is kept for the log.

1. Alloy sends the request `initialize` with `{apiVersion: 1, pluginId, grants: [<permission>...], settings: {...}, root: <file URI or null>}`. The answer must be an object with `apiVersion: 1`; any other value stops the plugin and lists it as "needs API v<N>" (the version the plugin answered).
2. Alloy sends the notification `initialized`, then `workspace/opened {root}` when a project is open.
3. Switching projects sends `workspace/closed {root}` then `workspace/opened {root}`. Requests the plugin has in flight are answered `-32800`, and a plugin that was started by anything but `onStartup` is stopped.
4. To stop a plugin Alloy closes its stdin, sends SIGTERM to its group, and SIGKILL after two seconds. A plugin should exit when stdin closes.

A request to a method the plugin holds no grant for (`document/text` and `project/read` need `project.read`, `project/write` needs `project.write`) is answered with error `-32003` and `data: {"permission": "<name>"}`. Alloy records each running group in a pid file and kills groups a crashed Alloy left behind at its next launch.

## Failure modes and budgets

- **Crash**: a non-zero or signal exit Alloy did not ask for, a framing error (anything but `Content-Length` frames on stdout), a memory or CPU kill, three request timeouts in a row, five chatty seconds, a full write queue, or a handshake that fails. Alloy restarts the plugin after 1, then 5, then 30 seconds (the step resets after a run of ten minutes), and only when the plugin is not stopped meanwhile. Three crashes inside ten minutes disable the plugin until its settings change.
- **Idle**: a plugin that saw no request, event or open panel for ten minutes is stopped and starts again at its next activation.
- **Cap**: at most 8 plugins run; starting another stops the one with the oldest message.
- **Timeouts**: Alloy's requests to a plugin time out after 2 s when they block the UI and 10 s otherwise.
- **Floods**: past 200 messages in one second Alloy stops reading until the next second; doing so in 5 different seconds within a minute restarts the plugin.
- **Resources**: Alloy samples a running plugin every 5 s; more than 500 MiB resident, or more than 90% of one core averaged over 30 s, kills it.

## Logs

Each scripted plugin's row in Settings › Plugins has a **Log** button that expands a disclosure under the row with the tail of the plugin's stderr and the last error Alloy recorded (a crash count, "disabled after repeated crashes", a failed start). The text is redacted before it is shown: each known secret value, `Bearer` tokens, `sk-`, `ghp_`, `github_pat_`, `xox*-` and `AKIA` keys, and any run of 32 or more base64-like characters become `‹redacted›`. Collapsing the disclosure removes it.

A plugin Alloy switches off after three crashes is saved as disabled (`enabled: false`, `disabledAfterCrashes: true`) and listed as "disabled after crashes" until the user switches it on again. At launch Alloy starts at most three `onStartup` plugins, in the order they were enabled, once the saved layout is back. A change to a plugin's settings value reaches a running plugin as the notification `settings/changed {values}`; a changed permission restarts it at its next activation. On quit every plugin group is stopped (stdin closed, SIGTERM, SIGKILL after two seconds) in parallel.

## Decorations

A plugin paints open documents with the notification `decorations/set {uri, version, items}`. `uri` is the file URI of a document that is open in Alloy (a URI that is not open, or lies outside the project, is dropped, never buffered); `version` is the buffer version the line numbers and byte offsets refer to (Alloy shifts line items through later edits and drops the set if its edit log no longer reaches back). Each call replaces everything that plugin set for the document; an empty `items` clears it.

Line items:

- `line` (0-based), optional `endLine` (exclusive, greater than `line`).
- `background` and `gutterBar`: a colour role.
- `marker`: `{text, role}` drawn in the gutter; `text` is one or two characters.
- `message`: `{text, role}` shown as a read-only row under the line; `text` is one line of at most 200 characters (longer text is cut, a line break ends it). Rows are not shown in a side-by-side comparison.

Range items: `start` and `end` (UTF-8 byte offsets, `start <= end`), with `underline` and/or `tint` (a colour role).

A colour role is one of `info`, `warning`, `error`, `success`, `accent`, `muted`; Alloy maps each to a theme colour, so decorations follow the theme. A plugin cannot name a literal colour.

An item with a negative line, an inverted range, an unknown role, a marker that is not one or two characters, or nothing to draw is dropped and the rest of the set still paints. A set holds at most 500 items (line items first, then ranges); the rest are ignored. Plugin decorations sit below Alloy's own (diff, diagnostics, git), so on a shared row or byte range Alloy's tint, bar, marker and underline win. Every open view of a document shows the same set.

Alloy applies at most one set per document per plugin every 0.25 s, and only when it differs from the one before. A plugin's decorations are removed when its process stops, it is switched off or removed, or the document closes.

## Panels

Each entry of `contributes.panels` adds a tab (puzzle-piece icon, labelled with the panel's title) after Git in the Code sidebar's tab row, for as long as the plugin is enabled. A panel that is not selected has no element and no task. Selecting the tab starts the plugin if needed, then sends the notification `panel/opened {panelId}`; leaving it sends `panel/closed {panelId}`. A plugin with a panel on screen is not idle-stopped. If the plugin's process ends while its panel is shown, the panel shows "Plugin stopped" above the last tree; when the plugin is running again Alloy sends `panel/opened` once more.

The plugin draws with the notification `panel/render {panelId, tree}`. `tree` is one node; every node is an object with a `type` and a `key`. A `key` is unique within the panel (a duplicate rejects the whole tree). Alloy keys the widgets by `key`, so a new tree keeps focus and scroll. A tree that is rejected (duplicate key, unknown widget or role, more than 300 elements, nested deeper than 16 levels) is not shown; the reason goes to the plugin's log and the previous tree stays.

| `type` | Fields |
| --- | --- |
| `text` | `text`, optional `role` (a colour role, as in decorations) |
| `button` | `title` |
| `toggle` | `title`, `isOn` (default false) |
| `textField` | `placeholder`, `text` |
| `picker` | `title`, `options: [{value, title}]`, `selection` (a value) |
| `list` | `rows: [node]` |
| `vstack`, `hstack` | `children: [node]` |
| `divider` | none |

Widgets send the notification `panel/event {panelId, key, kind, value?}`: a button sends `click`; a toggle sends `changed` with a Boolean; a picker sends `changed` with the chosen `value`; a text field sends `changed` with its whole text once 0.3 s after typing stops (never per keystroke) and `submit` with its text on Return (a pending `changed` goes first). While a text field has focus, Alloy owns its text: a new tree never overwrites it. Widgets carry the accessibility ids `plugin.panel.<plugin id>.<key>` and the panel `plugin.panel.<plugin id>.<panel id>`.

## Events, `document/text` and messages

Alloy sends these as notifications, never requests, and only to plugins that are running. An event never starts a plugin; the one exception is `onLanguage:<id>`, which starts the plugin when a document of that language opens. A plugin that activates on `onLanguage` needs `project.read`: without it the plugin hears no document events and the language never starts it.

With `project.read`:

- `document/opened {uri, languageId, version}` when a document opens. When a plugin starts, it receives `document/opened` for every document that is already open.
- `document/saved {uri, version}` after a save wrote the file.
- `document/closed {uri}` when the last tab holding the document closes.
- `document/renamed` is reserved and never sent in v1 (Alloy has no rename and does not pair moves); a moved-away document gets `document/closed` when its tab closes.

`uri` is a `file://` URI and `version` is the buffer version. There is no per-keystroke event: a plugin that needs the text asks for it.

`document/text {uri}` (request, `project.read`) answers `{text, version}` for an open document, or error `-32012` ("not open").

With `sessions.read`:

- `session/turnEnded {sessionId, isError, agent}` when a session's turn ends.
- `session/ended {sessionId, agent}` once per process run, when the session's process ends or is stopped.
- `claude/toolUsed {sessionId, toolName, paths}` after a tool ran (PostToolUse); `paths` are the project-relative files the tool named.

`agent` is `"claude"` for Alloy's own backend, otherwise the agent's id.

`window/showMessage {type, message}` (notification from the plugin; `type` is `info`, `warning` or `error`) shows a notice prefixed with the plugin's name. At most one notice per five seconds per plugin; extra messages are dropped and noted in the plugin's log.

## Project files and state

Paths are project-relative. An absolute path, a `..` component, or a symlink that resolves outside the project is refused with `outsideProject`.

- `project/read {path}` (needs `project.read`) returns `{text}`, the file as it is on disk (UTF-8). It fails with `-32012` and `data: {reason}` where reason is `binary`, `tooLarge` (over 16 MB) or `missing`. Files under `.claude` and `.git` can be read.
- `project/write {path, text}` (needs `project.write`) writes the file atomically, creating folders as needed, and returns `{}`. Alloy does not touch the open buffer: its file watcher sees an outside edit and reloads a clean buffer. A refusal is error `-32010` ("write refused") with `data: {reason}`:
  - `dirty`: the file is open with unsaved edits.
  - `claudeEditing`: a Claude Code session has a pending change to the file.
  - `outsideProject`: see above.
  - `protectedPath`: the path is, or resolves into, a `.claude` or `.git` folder (writing git hooks would turn a write into code execution).
- `state/get {key}` returns `{value}` (`null` when absent). `state/set {key, value}` stores a JSON value (`null` deletes it) and returns `{}`. State is per plugin and per project, kept in Alloy's per-project store, written one second after the last change and on quit. All of a plugin's state is limited to 64 KiB; past that `state/set` fails with `-32011` ("state too large") and changes nothing. State needs no permission.

## MCP tools

A plugin holding `mcp.tools` that lists `contributes.mcpTools` offers them to agent sessions through Alloy's MCP server. The tools are known from the manifest, so listing them starts nothing. Each is named `p_<short>_<name>`, where `<short>` is the first six hex digits of the 64-bit FNV-1a hash of the plugin id (offset `0xcbf29ce484222325`, prime `0x100000001b3`, over the UTF-8 bytes); `dev.example.todo` gives `c73409`, so its `notes_search` tool is `p_c73409_notes_search`.

- `mcp/call {tool, arguments}` (Alloy to plugin) runs the tool; `tool` is the manifest name without the prefix. Answer `{text, isError?}`. Alloy starts the plugin for the call. A call not answered within 10 s, or answered with an error, reaches the agent as an error result ("The plugin did not answer in time." or "The plugin failed: <message>").
- Every session started while the grant holds sees the tools. A session started earlier sees them after it restarts (Settings › Plugins says so on the plugin's row). Claude Code and ACP sessions both get them; an ACP session gets Alloy's MCP server for a plugin tool even with shared notes off.
- Plugin tools are never pre-approved: the agent asks before each use, whatever the notes setting says.
- Disabling the plugin, removing it or revoking `mcp.tools` takes the tools from every running session at once; a later call is refused as an unknown tool.

## Secret settings

A setting of `type: "secret"` holds a value such as an API token: `{"key": "token", "title": "API token", "type": "secret", "env": "TODO_TOKEN"}`. `env` is required, matches `^[A-Z][A-Z0-9_]{0,63}$`, and is none of `PATH`, `HOME`, `LANG`, `TMPDIR`, `SHELL`, `USER`; it does not start with `ALLOY_`, `DYLD_` or `LD_`. A secret has no `default`.

Settings shows a secret as a secure field with Save. A stored one shows "Stored in your Keychain" with Remove; the field is empty again after Save. Where there is no Keychain the row says so and nothing can be stored. The value lives only in the Keychain (service `dev.alloy.plugin-secret`, account `<plugin id>/<key>`), never in `settings.json`, in the plugin's state, in `initialize.settings` or `settings/changed`, or in any protocol message. Alloy reads it when it starts the plugin and passes it as the environment variable `env`. Alloy hides every secret value in the plugin's log. Saving or removing a secret stops the running process; it starts again with the new value at its next activation. Removing the plugin deletes all of its secrets.
