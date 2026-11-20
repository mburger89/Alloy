# Agents over ACP

Alloy can run other coding agents next to Claude. A session talks to any agent that speaks the Agent Client Protocol
(ACP, protocol version 1) over stdio. Claude sessions are unchanged; an ACP session gets the same chat, permission
cards, file ledger, overlap warnings and shared notes.

## Choosing an agent

- The New Session menu (the "+" button, or New Session in the title bar) lists Claude first, then the agents Alloy
  found on your machine, then "Add agent...". Command-N starts a session with the default agent.
- Settings, Agents, "Default agent for new sessions" picks what Command-N uses (Claude unless you change it).
- A session keeps its agent. The session row shows the agent's name and, when the agent reports them, the model and
  context or token use. Cost is shown only when the agent reports one.

## Built-in agents

| Agent | Command Alloy runs | Install (Alloy never installs anything) |
| --- | --- | --- |
| Codex | `codex-acp` | `npm install -g @agentclientprotocol/codex-acp` |
| Gemini CLI | `gemini --acp` | `npm install -g @google/gemini-cli` |
| OpenCode | `opencode acp` | `brew install opencode` |
| Goose | `goose acp` | `brew install block-goose-cli` |

Alloy looks for each command on your login shell's PATH (so tools installed by Homebrew, npm or nvm are found even
though the app was not started from a terminal). A missing agent is greyed out in Settings, Agents with its install
command and a copy button. Detect re-reads your login PATH after you install something.

Your own agent: Settings, Agents, "Add agent..." takes a name, a command (a name on your PATH or a full path),
arguments and plain environment variables (`NAME=value`, one per line).

## Secrets

An agent that needs an API key gets it from the macOS Keychain (service `dev.alloy.agent-secret`, account
`<agent id>/<VARIABLE_NAME>`, readable only while the Mac is unlocked, never synced). Secrets are never written to
settings.json, history files, logs or error text. Settings shows only the names of the stored secrets, each with a
Remove button; removing a custom agent deletes its Keychain items. Entering a secret value in Settings is not
available yet (it waits for a secure text field in the UI framework); store the item in Keychain Access with the
service and account above, or use the agent's own login.

A plain environment variable whose name looks like a credential (`..._KEY`, `..._TOKEN`, `..._SECRET`, `PASSWORD`...)
is refused with "Add this under Secrets; Alloy keeps it in your Keychain." If the Keychain is unavailable or denies
access, the agent still starts without the secret and the chat names the missing variable.

## What the agent may do

- Files: `fs/read_text_file` and `fs/write_text_file` are served inside the project root only (symlinks resolved).
  Writes outside the root are refused. Writes to protected paths (`.git/`, `.env`, `.env.*`, `opencode.json`,
  `.claude/`, `.codex/`, `.goose/`, `.gemini/`, `.vscode/`, git hooks, MCP config files) always ask you first.
- Attribution: the file ledger records what an agent changed from its `fs` writes and from the diffs in its tool
  calls, so overlap warnings and revert work as for Claude. Agents that edit files with their own tools (Codex and
  OpenCode do) are attributed from their reported diffs and the file's state on disk.
- Shared notes: Alloy offers its notes server to the agent in `session/new` (over http); the tools follow the same
  "Ask before sessions use Alloy's tools" setting.
- Alloy advertises `fs.readTextFile`, `fs.writeTextFile`, terminal login and a few Alloy notice extensions. It does
  not offer the ACP `terminal` capability: agents run their own shell commands.

## Login

If an agent needs to sign in, the chat shows a card with one button per method the agent offers. Choosing an
`agent` method authenticates in place; a `terminal` method opens a terminal tab running the agent's login command and
retries when you return. OpenCode describes its login in prose (`opencode auth login`); the card shows it with a
copyable command.

## Messages while the agent works

Messages typed during a turn are queued and shown with a "Send now" action. Stop cancels the turn and discards what
was queued behind it. A permission request that arrives after Stop is answered "cancelled".

## History and restart

Alloy keeps its own history file per ACP session, so a restored session shows its conversation without starting the
agent. The agent starts on the first send and uses, in order, `session/resume`, `session/load` (the replay is
discarded, Alloy already has the history), or `session/new` with the notice "This agent doesn't remember the earlier
conversation". The same order applies after a settings change and after Restart.

## Limits and safety nets

- A turn with no sign of life for ten minutes is cancelled with a notice; Stop or Restart the session.
- A multi-megabyte line, a stray non-JSON line on stdout, or an agent that exits mid-turn never hangs Alloy; the
  chat shows an exit notice with the end of the agent's stderr.
- Quitting stops every agent: SIGINT, SIGTERM, then SIGKILL within the stop budget.
- Not yet: the ACP `terminal/*` methods, ACP v2, forking a session, remote agents.

## Live check

`Tests/AlloyACPTests/LiveAgentTests.swift` runs one Codex session and one OpenCode-with-Ollama session end to end,
headless (prompt, an edit, cancel, relaunch with resume). It is skipped unless `ALLOY_ACP_LIVE=1`, spends a little
Codex quota, and talks only to the local Ollama for OpenCode (`ALLOY_ACP_LIVE_OLLAMA_MODEL` picks the model, default
`qwen3.8:27b`):

```
ALLOY_ACP_LIVE=1 swift test --no-parallel --filter LiveAgentTests
```

Probe findings and recorded transcripts: [acp-probe.md](acp-probe.md).
