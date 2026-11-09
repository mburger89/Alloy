# Slash commands in Alloy

Source: the probe table in `docs/protocol-notes-plan3.md` section 1 (CLI 2.1.319, stream-json input). Alloy routes the
trimmed message text in `SlashCommands.route` (`Sources/AlloyCore/Chat/SlashCommands.swift`). A command is recognised
only when the text starts with `/`; its name is the run of characters up to the first whitespace.

Three outcomes:

- **Pass through**: sent to the CLI as an ordinary user message.
- **Alloy handles it**: nothing is sent as a user message.
- **Hidden (terminal-only)**: the CLI lists it in `terminal_slash_commands`; Alloy leaves it out of the command list.

## Handled by Alloy

| Command | What Alloy does | Why |
|---|---|---|
| `/model <name>` | Calls `setModel` (the `set_model` control request). | The CLI's own `/model` only reports the current model headless. |
| `/model` | Sets `Session.requestModelPicker = true`; the composer's model `Menu` (`model-menu`: Sonnet, Opus, Haiku) opens through `.menuPresented` bound to the flag (G9). Choosing an item or dismissing the menu resets the flag. On macOS the menu is modal, so setting the flag false from code cannot close an open menu. | Same. |
| `/plan` (no arguments) | Calls `setPermissionMode(.plan)`. | Switches mode without a model turn. `/plan <text>` passes through. |
| `/fork [name]` | Calls `Workspace.fork`: a new session that resumes this conversation with `--fork-session`, named `<name>` or `<this name> (fork)`. Waits for the next idle if a turn is running (a "Forking when idle…" notice), and is refused with a notice when nothing has been said yet. Alloy adds it to `Session.slashCommands` so `/` suggests it (the CLI does not list it). | The CLI has no headless fork command; the fork needs Alloy's reads and told records copied too. |
| `/help [...]` | Adds a local command-output notice listing `Session.slashCommands` (name, hint, description). | The CLI does not handle `/help` headless; the model answers "/help isn't available" in a wasted turn. |

## Passed through

| Command | Behaviour (probed) |
|---|---|
| `/compact [instructions]` | Works: `compact_boundary`, summary, `Compacted` output, `result` with 0 turns. |
| `/clear` | Works: `conversation_reset` and a new session id; Alloy adopts it. |
| `/cost`, `/usage` | Work (though not in `slash_commands`): synthetic assistant message, rendered as command output. |
| `/context` | Works: synthetic assistant message with markdown tables, rendered as command output. |
| `/status` | Not handled by the CLI: the model replies that it is unavailable (a real turn). Passed through anyway. |
| `/mcp`, `/init` | Listed by the CLI, not probed. Passed through. |
| Skills (`/loop`, `/simplify`, user skills) | The CLI expands them into a model turn. |
| Unknown names (`/bogus-cmd`) | Not an error: the CLI treats them as a prompt and the model answers. |

## Terminal-only (hidden)

`/doctor`, `/color`, `/focus` and `/reload-plugins` are reported in `terminal_slash_commands` and are removed from the
list Alloy offers.

## Commands that cannot work headless

- `/doctor`, `/color`, `/focus`: TUI only. Hidden as above.
- `/config`: not probed; presumed terminal-only (TUI). Alloy does not offer a replacement.
- `/status`, `/help`: not handled by the CLI (see above); `/help` is replaced locally, `/status` is not.
