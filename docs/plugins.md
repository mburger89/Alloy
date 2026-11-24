# Alloy plugins

A plugin is a folder with an `alloy-plugin.json` manifest. There are two tiers:

- **Declarative** (no `main`): themes, language-server configs, settings and task commands. Nothing of the plugin runs inside Alloy's process; language servers and task commands are launched by Alloy itself.
- **Scripted** (has `main`): an out-of-process JSON-RPC child that adds commands, panels and MCP tools, and can use the events and project access its permissions allow. **Not yet available:** this Alloy lists scripted plugins in Settings › Plugins as "Scripted plugins arrive in a later Alloy version"; their toggle is off, nothing of them starts (`onStartup` included) and their declarative contributions stay off too. The scripted sections below (commands, panels, MCP tools, decorations, events) describe what is coming.

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
| `settings` | `[{key, title, type: "bool"\|"string"\|"number"\|"enum", options?, default?}]`; keys match `^[A-Za-z][A-Za-z0-9_.-]{0,63}$`; `options` is a non-empty string array, enum only | |
| `commands` | (not yet available) `[{id, title, shortcut?, menu?: "plugins", when?}]` | `main` |
| `taskCommands` | `[{id, title, command, args?, cwd?}]` | `process.spawn` |
| `panels` | (not yet available) `[{id, title}]` | `main` |
| `mcpTools` | (not yet available) `[{name, description, inputSchema}]`; names match `^[a-z0-9_]{1,40}$`; `inputSchema.type` is `"object"` | `main`, `mcp.tools` |

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

Not yet available: scripted plugins (and with them commands, panels, MCP tools, decorations and events) arrive in a later Alloy version; this section and the two after it describe the host that is built and tested but not switched on.

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
