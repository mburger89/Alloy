# ACP live probe findings

Probed 2026-11-19, headless over stdio, with `tools/acp-probe/drive.py` (scripted client) through `tools/acp-probe/record.py` (logging proxy). Agents: codex-acp 2.8.0 (Codex, ChatGPT login), OpenCode 2.3.2 against local Ollama (`qwen2.5-coder:7b`, then `qwen3.8:27b` because the 7B model never called a tool). Client advertised `fs.readTextFile` and `fs.writeTextFile`, protocol version 1.

Fixtures (scrubbed with `tools/acp-probe/scrub.sh`, stderr dropped, each line `{t, dir, line}` where `dir` is `c2a` or `a2c`) are in `Tests/AlloyACPTests/Fixtures/`:
`probe-codex-session.jsonl` (read, create, cancel, resume), `probe-codex-permission.jsonl` (permission-gated edit, set_config_option), `probe-opencode-qwen7b.jsonl` (text-only turns, cancel after completion, session/load replay), `probe-opencode-qwen27b.jsonl` (read, write, cancel mid-stream).

## Spec/plan adjustments

1. **Neither agent calls `fs/read_text_file` or `fs/write_text_file`**, even though both were offered. Codex runs shell commands and writes to disk itself; OpenCode writes with its own tools. Attribution must therefore come from `diff` content and from tool-call `locations` plus disk state (the spec's "diffToolContentAttributesLinesWithoutFsCall" path is the primary path, not the fallback). The fs handlers stay (other agents use them) but cannot be the only attribution source. Task 5.
2. **Codex `diff` content is a snippet, not a whole file**: `{oldText:"second line\n", newText:"second line\nthird line\n", path, _meta:{kind:"update"}}`. Creation has `oldText:null` and the whole new text. The transport must rebuild whole-file before/after text (spec row 139 fallback applies). Task 4/5. Codex sends the diff on the `tool_call` itself (status `in_progress`), before the permission request and before completion, then a bare `tool_call_update {status: completed}` with no content.
3. **OpenCode `tool_call` for edits carries no diff at all**: `kind: "edit"`, `rawInput:{path, content}` arriving on a `tool_call_update` (`in_progress`, with `locations`), completion content is only text ("Created file successfully"). The translator must treat `kind: edit` + `locations`/`rawInput.path` + completed as "this file changed on disk" and attribute by diffing the buffer/disk state it knew before. `tool_call` first arrives `pending` with empty `rawInput` and empty `locations`; fill in from the update.
4. **No `request_permission` in default modes**: Codex default mode `agent` (Auto review) and OpenCode never asked. Codex asked once in mode `read-only` (see below). Permission handling must be tested with the fake agent; real agents rarely exercise it.
5. **Codex `agentCapabilities.mcpCapabilities.acp: true`** (plus http; sse false). OpenCode: http true, sse false. Alloy's shared-notes MCP server must be offered as `http` (or stdio, always required) per `mcpServers` item shape; not `sse`. Task 6.
6. Codex advertises 63 models and a model option with 13 values mixing cloud-routed entries; model list size and long `description` strings need no special handling but pickers must scroll. `models.currentModelId` carries an effort suffix (`gpt-5.6-sol[high]`) while `configOptions[model].currentValue` does not.

## Per-agent findings

### Codex (`codex-acp`)

- **initialize** (3.2 s cold start, including node and app-server boot): `protocolVersion 1`; `agentInfo{name,title:"Codex",version}`; `agentCapabilities{loadSession:true, promptCapabilities{embeddedContext,image}, mcpCapabilities{acp,http,sse:false}, sessionCapabilities{resume,list,close,delete,fork,title,additionalDirectories,systemPrompt}, auth{logout}, providers{}, _meta{authStatus}}`; `authMethods`: `api-key` (type absent, `_meta["api-key"].provider`) and `chat-gpt`; `_meta.steering.supported`.
- **session/new**: 0.6 s after initialize. Returns `sessionId` (UUID), `models{availableModels[{modelId,name,description}], currentModelId}`, `modes{availableModes[read-only, workspace-write, agent, agent-full-access], currentModeId:"agent"}`, `configOptions` with categories `model`, `thought_level` (reasoning_effort), `speed` (fast-mode), `mode`, `collaboration_mode` (new category, tolerate unknown categories). A custom notification `_auth/status_update {authStatus{kind,label,account{email,plan}}}` arrives during session/new: it contains account details; never log or persist it, and ignore unknown `_`-prefixed notifications.
- **available_commands_update**: first update 40 ms after prompt is sent (not after session/new), 23 commands; a second, longer one (56) on the next prompt. Commands carry `input: null` or `{hint}`. Commands include `compact`, `plan`, `review`, `mcp`, `skills`, `status`.
- **Updates seen**: `agent_message_chunk` (with `messageId`; content `{type:text,text}`), `agent_thought_chunk`, `tool_call`, `tool_call_update`, `usage_update {used,size}` (no cost), `session_info_update` (`title`, and `_meta.codex.threadStatus{type: active|idle}`: a busy/idle signal), `available_commands_update`, `config_option_update` (full `configOptions` replacement, also returned as the result of `session/set_config_option`).
- **Tool calls**: reads are `kind:"read"` shell commands with title "Read file '<abs path>'", `status: in_progress` on creation, `locations[{path}]`, completed update carries `rawOutput{exit_code}` and `_meta.terminal_output_delta{data,terminal_id}` (command output is only in `_meta`, not in `content`). Generic commands are `kind:"execute"` with `content[{type:"terminal",terminalId}]` and `rawInput{command}`. Edits are `kind:"edit"` with the snippet `diff` described above. Tool call ids are `exec-<uuid>`.
- **fs/***: never called. **terminal/***: never called (not advertised).
- **request_permission** (only in `read-only` mode, for an edit): `toolCall{toolCallId,title:"Edit files",locations,kind:"edit",status:"pending"}`, options `allow_once` ("Yes, proceed", kind allow_once), `allow_for_session` ("Yes, and don't ask again for these files", kind allow_always), `cancel` (kind reject_once). Request id was numeric `0` (starts at 0, not 1). The reply `{outcome:{outcome:"selected",optionId}}` worked.
- **Usage**: `usage_update {used, size}` after each tool and at turn end; no `cost`. `session/prompt` result carries `usage{totalTokens,inputTokens,cachedReadTokens,cachedWriteTokens,outputTokens,thoughtTokens}` and `_meta.quota{token_count, model_usage[]}` (quota accounting).
- **Cancel**: `session/cancel` 4.0 s into a turn; the prompt result `stopReason:"cancelled"` arrived 110 ms later with `usage:null`; one more `usage_update` and `session_info_update{idle}` arrived just before the result (late updates are normal).
- **session/resume**: succeeded in 15 ms on the live session, result `{models, modes, configOptions}` with no replay. `loadSession:true` is advertised; load was not exercised for Codex (the codex session was still live). On exit the agent printed stack traces about the app-server shutting down to stderr: stderr tail must be bounded and not treated as a failure when stdin closed.
- **Turn latency**: first token about 4 to 5 s after prompt (model and app-server).

### OpenCode (`opencode acp`, Ollama)

- **initialize** (0.3 to 0.4 s): `agentInfo{name:"OpenCode",version}`; `agentCapabilities{loadSession:true, promptCapabilities{embeddedContext,image}, mcpCapabilities{http,sse:false}, sessionCapabilities{additionalDirectories,close,delete,fork,list,resume}}`; `authMethods[{id:"opencode-login", name, description:"Run \`opencode auth login\` in the terminal"}]` (no `type`; this is a terminal-style login described only in prose, so the Login button cannot rely on `type:"terminal"` and `args`; show the description with a copyable command). `_meta.steering.supported`.
- **session/new**: 0.4 to 1.4 s. Returns `sessionId` (`ses_...`), `configOptions` of categories `model` (13 values, `provider/model` ids) and `mode` (`build`, plan). No `models` or `modes` keys: pickers must be driven by `configOptions` alone.
- **available_commands_update**: arrives immediately after the session/new result (4 commands: init, review, ...), re-sent after `session/load`. `config_option_update` is also sent right after the first prompt starts (twice).
- **Updates seen**: `agent_message_chunk` (`messageId`), `agent_thought_chunk` (qwen3.8 streamed 184 thought chunks), `tool_call`, `tool_call_update`, `usage_update{used,size,cost{amount,currency}}` (cost present, `0 USD` for local models), `user_message_chunk` (replay only), `config_option_update`.
- **Tool calls**: `tool_call` `pending` (empty `rawInput`, `locations`), then `tool_call_update in_progress` with `locations[{path}]` and `rawInput{path[,content]}`, then `completed` with `content[{type:"content",content:{type:"text",text}}]`; read results are text ("Read file notes.txt, lines 1-2\n1: ..."). Tool call ids are opaque model call ids (`call_xxxx`, not UUIDs; could collide across turns, key by session plus id).
- **fs/***: never called. **request_permission**: never requested.
- **qwen2.5-coder:7b** answered text-only turns (no tool call for "create hello.txt"; it replied in prose), so no file was written. Use qwen3.8:27b for tool probes (cold turn took 85 s to first tool call).
- **Cancel**: 8 s into a streaming turn, `stopReason:"cancelled"` returned 130 ms later with no `usage`. In the 7B run the turn had already ended, so the cancel was a no-op.
- **session/load**: result `{configOptions}`; replay is `user_message_chunk` and `agent_message_chunk` pairs (with `messageId`, one chunk per message for text-only history), followed by `available_commands_update`, in about 35 ms for three turns. Tool calls in history were not replayed in the 7B run (it had none). `session/resume` advertised but not exercised.
- **Prompt result**: `usage{inputTokens,outputTokens,totalTokens,cachedReadTokens}`, no thoughtTokens.

## Protocol shape notes for later tasks

- Agent-to-client request ids may be numeric starting at `0`; treat `id: 0` as valid (not falsy).
- Unknown notification methods starting with `_` (`_auth/status_update`) occur and may carry account data; drop them unlogged.
- `usage_update.cost` is optional; `session/prompt` result `usage` is a second, per-turn source.
- `session_info_update` may carry only `_meta` or only `title`; all fields optional.
- Tool-call `status` first value is `in_progress` (Codex) or `pending` (OpenCode); `title` and `locations` may arrive only on later updates.
- Both agents emit no `plan` updates in these short probes; plan, mode and notice updates are covered by fake-agent tests instead.
- Not probed (agents not installed, per the approved scope): Gemini CLI, Goose, `fs/*` callbacks, `terminal` auth, session/load for Codex.

## Reproducing

`python3 tools/acp-probe/drive.py OUT.jsonl CWD "prompt:...,cancel:...@4,config:mode=read-only,resume" -- codex-acp`, then `sh tools/acp-probe/scrub.sh OUT.jsonl > fixture.jsonl` and drop `"dir": "err"` lines. Check with `sh tools/acp-probe/scrub-test.sh`.

## Live end-to-end check (Task 9)

Run 2026-11-19 through `ACPTransport` headless (no GUI app), with `ALLOY_ACP_LIVE=1 swift test --filter LiveAgentTests`
(`Tests/AlloyACPTests/LiveAgentTests.swift`). Each run: a prompt, an edit prompt (permission requests auto-allowed), a
cancel mid-turn, then stop, relaunch and resume the same agent session.

| Agent | Prompt | Edit (file written) | Cancel mid-turn | Relaunch with `session/resume` | Time |
| --- | --- | --- | --- | --- | --- |
| Codex (`codex-acp`) | ok | yes | turn ended | same session id, no "doesn't remember" notice | 14 s |
| OpenCode + Ollama (`qwen3.8:27b`) | ok | yes | turn ended | same session id, no "doesn't remember" notice | 102 s |

Both agent processes ended through `stopAndWait` (the exit event arrived each time); `pgrep` found none afterwards.
Neither agent called `fs/*` here either, as in the probe above, so attribution relied on the reported diffs and disk
state. The session/load fallback is covered by the fake-agent tests (`ResumeTests`); both real agents offer resume.
