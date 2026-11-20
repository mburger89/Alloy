# Alloy: other AI agents through ACP (Agent Client Protocol)

Date: 2026-11-19. Status: draft for the user's review. Approach A chosen by the user. Research notes:
`docs/acp-research.md` (ACP v1, the adapters, gotchas, with source URLs).

## Intent and why

The user wants people to be able to use other AI providers in Alloy (OpenAI and local models in particular) while
Claude stays a first-class option. ACP is the open standard editors use to talk to coding agents: the editor launches
an agent process and exchanges JSON-RPC over stdio. Supporting it lets Alloy run Codex (OpenAI), Gemini CLI,
OpenCode and Goose (which can drive local models through Ollama or LM Studio), and any of the 50+ agents that adopt
ACP, without Alloy implementing each provider.

Standing goal: "MetalUI and Alloy run as lite and fast as possible without giving up quality." An idle ACP session
costs nothing per frame; nothing here touches the typing path.

## Goals

1. A session can run either Claude (today's native connection, unchanged) or an ACP agent. The choice is made when
   the session is created and is shown on the session row.
2. ACP sessions use the same chat: streaming replies, thinking, tool cards (with diffs), plans, permission prompts,
   stop, slash commands the agent offers, and the agent's own modes and model picker when it exposes them.
3. Alloy's coordination features work for ACP sessions as far as the agent allows: per-session line colours and the
   ledger, overlap warnings, shared notes (MCP tools), "already read" tracking, and the changed-files list.
4. Agents are easy to find and add: built-in presets that Alloy detects when installed, plus custom agents.
5. Restored ACP sessions come back after relaunch (history replayed when the agent supports `session/load`).

## Non-goals

- Alloy acting as an ACP *agent* for other editors (e.g. Zed driving Alloy).
- Remote agents over HTTP or WebSocket (an RFD in ACP; local stdio only).
- ACP v2 (draft, breaking). Build against `protocolVersion: 1`; tolerate unknown fields and update variants.
- Installing agents or their runtimes. Alloy never installs software; it shows the install command.
- A provider account or billing UI. Each agent owns its login and model configuration; Alloy only offers
  Keychain-backed secrets for agents that need an environment key.
- Claude through ACP. Claude stays on the native connection.
- Fork (`/fork`) and `/theme` for ACP sessions (both stay Claude-only, shown as unavailable).
- The ACP `terminal/*` client capability in this project (agents run commands themselves; listed as a later item).

## Anti-goals (a failure even if it works)

- Any change to how Claude sessions behave, look or perform.
- An agent writing outside the project folder through Alloy, or Alloy writing a file the user didn't allow.
- Alloy silently installing anything, or writing any API key or other secret to a file or in plain text (the
  Keychain is the only place Alloy may keep one).
- A stuck or crashed agent freezing the UI or blocking quit.
- Per-frame or idle cost from an ACP session.

## Constraints

- Swift 6, macOS first; the code stays portable (Linux/Windows builds mirror the macOS design).
- No new package dependency for ACP: no official Swift SDK exists and the community ones are immature. Alloy writes
  its own Codable models from the v1 schema, like its LSP client (`Sources/AlloyLSP`).
- MetalUI is used as-is; any missing UI capability is a MetalUI gap, never a workaround.
- Privacy: no local paths or personal data in committed files.

## Approaches (decided)

- **A. Claude native, ACP for every other agent (chosen).** Claude keeps every feature; ACP brings any compliant agent.
- B. Everything through ACP, Claude via its adapter. Rejected: Claude would lose cost/token reporting, compaction
  signals, fork and history replay, hooks-based pre-edit warnings and session details, against "Claude first class".
- C. Alloy runs its own agent loop against the OpenAI and Ollama APIs. Rejected: rebuilds what Codex/OpenCode do, a
  far larger project, and not ACP.

## Design

### 1. Architecture: an ACP transport that speaks Alloy's existing wire model

Today everything above `SessionTransport` (Workspace, Session, Transcript, ledger, coordination) consumes
`ProcessEvent`/`InboundMessage` and emits `OutboundMessage`, all Claude stream-json shaped.

- New module `AlloyACP` (next to `AlloyLSP`): JSON-RPC 2.0 over newline-delimited stdio (unbounded line reader,
  tolerate and log stray non-JSON lines), Codable v1 models, a client connection with request/response correlation,
  notifications and incoming agent→client requests, `$/cancel_request`.
- New `ACPTransport: SessionTransport` that owns one agent process and **translates** ACP into the existing
  `InboundMessage` cases and `OutboundMessage` cases into ACP. Translating (rather than refactoring the app onto a
  new neutral event model) keeps the Claude path byte-for-byte unchanged and reuses the transcript, ledger,
  coordination and UI code. The translation table is the heart of the build (section 3).
- `Workspace`'s `TransportFactory` takes the session's backend: `.claude` → `ClaudeProcess` (unchanged), `.acp(agentID)`
  → `ACPTransport` with the agent definition. `launch()` branches only where Claude-specific setup lives (executable
  resolution, hooks settings, `--mcp-config`, `--append-system-prompt`, `--allowedTools`, resume/fork flags).
- `Session` and `SessionRecord` gain `backend` (`decodeIfPresent`, default `.claude`, so existing data loads as before).

### 2. Agents: presets, custom agents, detection

An agent definition: `id`, display name, command, args, env (name/value pairs), and an optional install hint.
Built-in presets (definitions shipped with Alloy, editable copies allowed):

| Preset | Command | Detected when | Notes |
|---|---|---|---|
| Codex (OpenAI) | `codex-acp` | `codex-acp` on the login PATH (install hint: `npm install -g @agentclientprotocol/codex-acp`) | Uses the user's Codex login (ChatGPT or API key). Never launched through `npx -y`, which would download software silently |
| Gemini CLI | `gemini --acp` | `gemini` on the login PATH | Probe at detection: fall back to `--experimental-acp` if `--acp` is rejected |
| OpenCode | `opencode acp` | `opencode` on the login PATH | Best route to local models (OpenAI-compatible provider in `opencode.json`) |
| Goose | `goose acp` | `goose` on the login PATH | Local models via `GOOSE_PROVIDER`/`GOOSE_MODEL` env |

Detection reuses `ClaudeLocator`'s login-shell lookup, generalised to a command name, run once per launch of the app
and on Settings' "Detect". A preset that isn't installed is listed greyed out with its install command (copyable).

Custom agents: Settings → **Agents** section: list of presets and custom agents; "Add agent…" (name, command, args,
optional non-secret environment variables such as `GOOSE_PROVIDER=ollama`); edit, remove; "Default agent for new
sessions" (Claude by default).

**Keys only in the Keychain (user ruling).** Alloy never writes an API key, token, password or other secret to a
file or anywhere in plain text: not `settings.json`, not session history, not logs, not crash or error text. Where an
agent needs a key that the agent's own login or config doesn't already provide, Alloy stores it in the macOS
Keychain and nowhere else:

- The custom-agent form has a separate **Secrets** list (name + value, the value in a secure text field). Each secret
  is a Keychain generic-password item (service `dev.alloy.agent-secret`, account `<agent id>/<VARIABLE_NAME>`,
  accessible only when the Mac is unlocked, this device only). `settings.json` records only the variable names, never
  values.
- At launch, Alloy reads the values from the Keychain and adds them to the agent process's environment in memory; they
  are never written back anywhere. Removing an agent or a secret deletes its Keychain item.
- An ordinary environment variable whose name looks secret (contains `KEY`, `TOKEN`, `SECRET`, `PASSWORD` or
  `CREDENTIAL`, any case) is refused in the plain list with "Add this under Secrets; Alloy keeps it in your Keychain."
- If the Keychain is unavailable or the user denies access, the agent launches without the secret and the chat says
  which variable was missing; Alloy never falls back to a file.
- Agents' own logins stay preferred (Codex's login, `opencode auth login`, Goose's config). Agents are also launched
  with the user's login-shell environment (read fresh at launch, never stored), so keys already in the shell profile
  keep working.
- Linux/Windows builds use the platform secret store (Secret Service, Credential Manager) behind the same interface;
  where none exists, the Secrets list is hidden rather than falling back to a file.

### 3. Translation (ACP v1 → Alloy wire model)

Startup: spawn the command (cwd = project root, login PATH merged, env added) → `initialize` with client capabilities
`fs.readTextFile`, `fs.writeTextFile`, `auth.terminal`, `session.notices` and `session.compaction` (advertise only what
Alloy implements; never `terminal`) → `session/new{cwd, mcpServers}`
(or `session/load` on restore) → synthesize `.systemInit` (session id = ACP session id, model from the agent's model
config option if any, commands empty until `available_commands_update`). `session/new` can take 10+ s: the session
shows Starting meanwhile.

| ACP | Alloy |
|---|---|
| `agent_message_chunk` | `.delta` text (one assistant text block per `messageId`, closed by a non-text update or turn end) |
| `agent_thought_chunk` | `.delta` thinking |
| `user_message_chunk` (replay) | `.userEcho` with `isReplay` |
| `tool_call` / `tool_call_update` | a `ToolBlock`: `name` = title, `kind` mapped from ACP kind (read, edit, delete, move, search, execute→shell, fetch, think, other), status mapped, content shown as text / diff / plain output. A generic ACP tool body renders in the chat; existing Claude tool bodies are untouched. |
| `diff` content `{path, oldText?, newText}` on a completed edit | `.toolResult` with a whole-file `ToolUseResult.write(filePath, isCreate:, content:, originalFile:)` so `ProjectLedger.record` attributes the lines to the session. If the probe (Testing) shows agents send snippets rather than whole files, the transport rebuilds whole-file before/after text from the pre-edit file it knows (buffer or disk) before emitting the result. |
| `plan` | the existing plan/todo rendering (full list each time) |
| `available_commands_update` | `Session.setCommands` (slash autocomplete); invoking one sends "/cmd args" as prompt text |
| `current_mode_update`, `config_option_update` | composer Mode/Model pickers (below) |
| `usage_update{used, size, cost?}` | session row: context `used/size` and cost when present; hidden otherwise |
| `compaction_update` / `session_info_update` / `notice` | compaction → `.compactBoundary` (bumps the knowledge/overlap generation); notice → transcript notice; unknown → ignored |
| `session/request_permission` | `.controlRequest(.canUseTool)` → permission card with the agent's options (allow once, allow always, reject once, reject always); the chosen `optionId` is returned; the tool call it refers to is looked up by `toolCallId` |
| `session/prompt` response `{stopReason}` | synthesize `.result` (end_turn → normal; cancelled → interrupted notice; refusal/max_tokens/max_turn_requests → warning notice) |
| user message from Alloy | `session/prompt` with text and image blocks (images only if `promptCapabilities.image`); synthesize the `.userEcho` with the same uuid immediately, so queued bubbles and "told" bookkeeping settle |
| Stop | `session/cancel`; answer every pending permission request with `cancelled` |
| Mode picker | from the agent's modes / `configOptions` (category `mode`), set with `session/set_mode` or `session/set_config_option` |
| Model picker | from the `configOptions` entry with category `model`; hidden if absent |
| Effort picker, Fork, `/theme`, "Install theme skill" | hidden or disabled for ACP sessions |

Turn watchdog: if a prompt gets no update for 10 minutes the session shows "The agent stopped responding" with Stop
and Restart; quit always kills agent processes within the existing `stopAndWait` budget.

### 3a. Messages while the agent is working

ACP takes one prompt at a time. A user message sent while a turn runs is queued and shown as "Queued — sends when
the agent finishes" with a **Send now** button (cancel the turn, then prompt). Messages from other sessions, overlap
and tug-of-war notices also wait for the turn to end, then go out first in the next prompt's shared-context block.
The `.userEcho` (which settles queued bubbles and "told" bookkeeping) is synthesized only when the message is actually
sent in a `session/prompt`, never earlier.

### 4. Files, edits and attribution

- `fs/read_text_file{path, line?, limit?}`: served from the open editor buffer when the file is open (unsaved text
  included), else from disk. Each read feeds the `ReadIndex` (so "already read" and shared notes work exactly).
- `fs/write_text_file{path, content}`: the path must resolve inside the project root (symlinks resolved), else the
  request fails with an error. Ordinary files are written once the agent's own permission flow allowed the edit (Alloy
  adds no second prompt). Protected paths always need the user's approval in Alloy, regardless of the agent: anything
  under `.git/`, `.env` and `.env.*`, agent and editor config (`opencode.json`, `.claude/`, `.codex/`, `.goose/`,
  `.gemini/`, `.vscode/`), git hooks, and MCP config files; the approval card names the session and shows the diff.
  The write follows the same path as a Claude session's disk edit: written to disk, attributed to the session in the
  ledger (line colours, changed files, follow edits), and merged into an open buffer with unsaved typing through the
  existing DirtyMerge path. Missing files are created.
- Before applying an `fs` write or when a pending `tool_call` carries a diff, Alloy proposes the change to the
  `OverlapIndex`; an overlap with another session's live edits shows the existing warning notice in both sessions,
  and the overlap text is included in the next prompt's shared-context block for the agent (ACP has no hook to inject
  it mid-turn, unlike Claude's PreToolUse hook).
- Agents that write to disk directly (likely Codex): the `diff` tool content gives attribution; the file watcher
  picks up the disk change; `execute` tool calls open the same "shell window" attribution Claude's Bash calls use.

### 5. Shared notes and coordination tools (MCP)

If the agent's `mcpCapabilities.http` is true, `session/new` passes Alloy's local MCP server as
`{type:"http", name:"alloy", url, headers:[{name:"Authorization", value:"Bearer <token>"}]}` with the same per-session
token and scopes as Claude. The guidance text goes in `systemPrompt` when `sessionCapabilities.systemPrompt` is
offered; otherwise the tools are still available and the guidance is sent once as a short preface in the first prompt.
Approval of Alloy's own tools follows `askBeforeSharedNotes`: when not asking, Alloy auto-selects the agent's
allow option for permission requests on those tools. Agents without HTTP MCP get no shared notes (the session's info
says so).

### 6. Login

If any call fails with ACP error -32000 (`auth_required`) or the agent lists `authMethods`:
- `agent`-type methods: a card in the chat with one button per method; choosing calls `authenticate{methodId}`.
- `terminal`-type methods: Alloy opens a terminal tab (Code mode's terminal panel) running the agent command with
  the method's args, then re-initializes when the user returns.

### 7. Sessions, history and persistence

- `SessionRecord.backend` and the ACP session id are persisted. Alloy keeps its own history file per ACP session in
  its data directory (the translated wire lines, appended as they arrive, like Claude's `.jsonl`), so a restored ACP
  session is dormant and shows its history without starting a process, through the existing history-replay path
  (`prepend(history:)`, the 2000-block cap; no ledger, overlap or read-index side effects).
- The agent process starts on `wake` (first send), exactly like Claude. It then uses `session/resume` when the agent
  offers it, else `session/load` with the replayed updates discarded (Alloy already has the history), else
  `session/new` with a notice "This agent doesn't remember the earlier conversation". The same order applies to a
  relaunch after a settings change and to Restart after the watchdog.
- Cost: from `usage_update.cost` when present (summed per session); local agents report none and the row shows the
  context size instead.

### 8. UI

- **New Session**: the "+" button and title-bar New Session open a small menu: Claude (default, first), then
  detected agents, then "Add agent…". ⌘N creates a session with the default agent.
- **Session row**: the agent's short name replaces the Claude model short name (e.g. "Codex · gpt-5" when the model
  option is known); cost and tokens shown only when reported.
- **Composer**: placeholder "Message <Agent name>"; Mode/Model pickers driven by what the agent offers; Effort hidden.
- **Strings**: user-facing "Claude" strings in shared code become the session's agent name where they describe the
  session's agent (permission card title, exit notice, launch errors).
- **Settings → Agents** as in section 2. Accessibility ids follow the existing pattern (`agents-list`,
  `agents-add`, `agents-default`, `new-session-menu`).

### 9. Performance

- Agent I/O runs off the main actor; updates are coalesced into the transcript at most once per frame like Claude
  deltas.
- No frame-guard constant may rise (chat 46, code 46/62/72, steadyCompare 77, terminal guards, idle 0). A guard test
  pins that a streaming ACP session costs the same per frame as a streaming Claude session, and an idle ACP session 0.

### 10. Testing

- `AlloyACP` codec and connection tests against fixtures from the v1 schema examples.
- A scripted fake agent (`fake-acp-agent`, like `fake-claude.sh`) for process tests: handshake, prompt streaming,
  permission round-trip, fs read/write (including a write outside the root being refused), cancel, crash, stuck turn,
  stray stdout lines, multi-megabyte lines.
- Translation tests per row of the table in section 3, through the existing `ScriptedTransport`-style harness.
- Probe first (approved by the user): install `@agentclientprotocol/codex-acp` (npm, global) and OpenCode (brew),
  OpenCode pointed at the user's local Ollama. Before the translation work, record real transcripts from both:
  whether they call `fs/*`, what `diff` content carries (whole file or snippets), permission request shapes, modes and
  config options, usage reports. Recorded transcripts become test fixtures (scrubbed of local paths). The final live
  check runs one Codex and one OpenCode-with-Ollama session end to end.

## Left to the builder

- Exact module/file layout and type names; how the generic ACP tool body looks within the existing chat style.
- The coalescing interval and watchdog timing details within the stated limits.
- Which v1 fields beyond those named are decoded (decode tolerantly; ignore unknowns).
- Task order, provided each task ends green and Claude sessions are untouched at every step.

## Later (not in this project)

ACP `terminal/*` capability backed by Alloy's terminal; ACP v2; the `providers/*` RFD (point any agent at a local
base URL from Alloy); remote agents; Fork for agents that gain `session/fork`.
