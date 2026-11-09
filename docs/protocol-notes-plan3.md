# claude CLI feature probes (2.1.319, model haiku, 2026-11-07)

Raw captures: local probe captures (not committed), `p{1,2,3,4,5,6a-d,7,8,9}.log` (HOST lines prefixed `#HOST->CLI`), scripts s*.json, driver ../drive3.py (drive.py minus `--setting-sources project`, plus `--thinking-display summarized`; auto-allow needed for Bash). Transcript digest: transcripts.txt. Binary strings: claude.strings.
All probes ran WITHOUT --setting-sources, so the user's allow rules apply (default mode is `auto` per user settings).

## 1. Slash commands in stream-json input  (VERIFIED)

`system/init` fields: type, subtype, cwd, session_id, tools[], mcp_servers[], model, permissionMode, slash_commands[] (198 strings: bare names; plugin ones namespaced `plugin:name`; includes skills + built-ins like compact, context, model, clear, usage, config, mcp, init, doctor), terminal_slash_commands[] (`doctor,color,focus,reload-plugins` = TUI-only, don't offer), skills[] (159 names), agents[] (names only: claude, Explore, Plan, general-purpose, ...), plugins, capabilities, apiKeySource, output_style, memory_paths, original_cwd, additional_directories, fast_mode_state, view_mode, ultrathink_available, etc.
Descriptions are NOT in init. For `{name,description,argumentHint}` use the `initialize` control request (response.commands[]) or the `system/commands_changed {commands:[...]}` event emitted after the first turn (and when skills reload). `reload_skills` control request returns `{skills:[{name,description,...}]}`.
User has no ~/.claude/commands; only one user skill in ~/.claude/skills (listed as `(user)` in description).

Send as a normal user message `{"type":"user","message":{"role":"user","content":"/cost"}}`. Every slash command yields a fresh `system/init` first, then:

| input | outcome |
|---|---|
| /cost | works though NOT in slash_commands. `assistant` with `message.model:"<synthetic>"`, top-level `local_command_source:"<local-command-stdout>...</local-command-stdout>"`, content[0].text = plan-usage text (session %, week %). `result{subtype:success,result:<same text>,num_turns:0}`. No user echo. |
| /usage | identical shape/text to /cost |
| /context | same synthetic assistant shape, markdown ("## Context Usage ... tables"), num_turns 0 |
| /model | synthetic assistant: "Current model: `Haiku 5.5`\nUsage: /model <name>. Available: sonnet, opus, haiku, ..." (no arg only reports; `/model sonnet` not tried, use set_model) |
| /compact [instr] | `system/status`, init, `system/compact_boundary{compact_metadata{trigger:"manual",pre_tokens,post_tokens,duration_ms,...},logical_parent_uuid}`, `user` (summary text), `user` `<local-command-stdout>Compacted </local-command-stdout>`, `result{result:"",num_turns:0}` |
| /clear | emits `{"type":"conversation_reset","new_conversation_id":"<uuid>","trigger":"clear","user_message_uuid":..,"session_id":<old>}` (top-level type, no subtype), `system/background_tasks_changed`, init (with NEW session_id, new transcript file), `result{result:"",num_turns:0}`. Host must adopt the new session id. |
| /help, /status | not handled: no local output; the MODEL replies "/help isn't available in this environment." (real LLM turn, num_turns 1 or 0) |
| /bogus-cmd | not an error: user echo, real model turn ("isn't a command in this session"). num_turns 1 |
| /config /mcp /init /doctor | not run (listed; /doctor, /color, /focus are terminal-only) |
Skills (`/loop`, `/simplify`, user skill names) are in slash_commands and are expanded by the CLI into a model turn (not run here).
Verdict: built-in "local" commands answer via synthetic assistant + result(num_turns 0); render `local_command_source`/`<synthetic>` as command output, not as model text. Unknown or UI-only commands become ordinary prompts.

## 2. Control requests Host -> CLI  (VERIFIED)

Envelope: `{"type":"control_request","request_id":"x","request":{"subtype":..}}`; reply `{"type":"control_response","response":{"subtype":"success"|"error","request_id":"x","response":{..}|"error":"..","error_code"?}}`. Works idle and mid-turn; no `initialize` required.
- interrupt: `{subtype:"interrupt"}` -> success `{still_queued:[]}`. Idle: no-op success. Mid text-stream (VERIFIED now): emits `user` content `[{"type":"text","text":"[Request interrupted by user]"}]` then `result{subtype:"error_during_execution",is_error:true,terminal_reason:"aborted_streaming",stop_reason:null,total_cost_usd:0}`. Process stays alive.
- set_model: `{subtype:"set_model",model:"sonnet"}` -> success `{model:"claude-sonnet-5-5"}` (aliases resolve; "haiku" -> claude-haiku-5-5). Unknown: error `{error:"Model 'nonexistent-model' not found",error_code:"not_found",model:"<current>"}`.
- set_permission_mode: `{subtype:"set_permission_mode",mode}` -> success `{mode}` and a `system/status {status:null,permissionMode:"<mode>"}` event. Accepted: default, acceptEdits, plan, dontAsk, auto. `bypassPermissions` -> error `bypass_not_launched` ("session was not launched with --dangerously-skip-permissions"). Invalid: error `invalid_mode` "must be one of acceptEdits, auto, bypassPermissions, default, dontAsk, plan".
- set_max_thinking_tokens (also the thinking display control): `{subtype:"set_max_thinking_tokens",max_thinking_tokens:null|int,thinking_display:"summarized"|"omitted"|"highlights"|null}` -> success (no payload). Omit max_thinking_tokens to leave budget unchanged. Bad display -> error listing allowed values. Effect on later stream not re-measured (UNVERIFIED), "highlights" may be rejected by API outside Anthropic-hosted sessions.
- initialize -> `{commands:[{name,description,argumentHint}],...}`.
- get_settings -> `{effective:{...merged settings...},...}`; get_status -> `{sections:[{title,rows:[{label,value}]}]}` (version, session id, login, model...); get_context_usage -> `{categories:[{id,name,tokens,kind,...}],...}`; get_plan -> `{exists:true,content:"<plan md>"}` (current session plan file); list_permission_rules -> `{state:{rules:[],workspaceDirectories,originalCwd,managedOnly}}`; get_hooks_listing -> `{events:[{name,summary,supportsMatcher,hookCount}]}`; file_suggestions `{query}` -> `{suggestions:[],cwd}` (returned empty for query "gre" in this repo; maybe needs different arg name, UNVERIFIED); get_workspace_diff -> `{diff:{stats,perFileStats,hunks,...}}`; mcp_status -> `{mcpServers:[{name,status,serverInfo,config,...}]}`; reload_skills -> `{skills:[...]}`; side_question `{question}` -> `{response,synthetic:false}`; cancel_async_message `{message_uuid}` -> `{cancelled:false}`; rewind_files -> error "File rewinding is not enabled." (needs --replay-user-messages + file checkpointing env; not explored).
- Bogus subtype: `{"subtype":"error","request_id":"b1","error":"Unsupported control request subtype: bogus_subtype"}`.
- Other subtype names present in the binary (UNVERIFIED, not probed): add_directory, apply_flag_settings, update_settings, set_cwd, mcp_set_servers, mcp_reconnect, mcp_authenticate, reload_plugins, rewind_conversation, fork_conversation, export_conversation, end_session, get_skills_dialog, get_memory_dialog, read_file, stage_file, seed_read_state, list_directory, start_shell_task, set_proactivity_level, set_prompt_suggestions_paused, session_metadata. Some `system` subtype names in the same grep are events, not requests.

## 3. Plan mode  (VERIFIED)

set_permission_mode plan -> init.permissionMode "plan". Flow: model does `ToolSearch select:ExitPlanMode`, Bash read-only (no prompt), `Write` of the plan file under `~/.claude/plans/<slug>.md` (no prompt; CLI-owned), then `ExitPlanMode`:
`control_request{subtype:"can_use_tool",tool_name:"ExitPlanMode",input:{plan:"<md>",planFilePath:"$HOME/.claude/plans/<slug>.md"},tool_use_id,requires_user_interaction:true}`.
- Deny `{behavior:"deny",message:"Revise: also add a docstring step, and mention type hints."}` -> tool_result `is_error:true` content = the message, `tool_use_result:"Error: <message>"`, `tool_result_meta[0]:{non_execution_kind:"permission-rule",permission_decision:{decision:"reject",source:"user_reject"}}`. Mode STAYS plan; Claude re-Wrote the plan file (Write `type:update`) and called ExitPlanMode again with a revised plan (new request_id, new tool_use_id). Revision incl. the requested docstring/type hints confirmed.
- Allow `{behavior:"allow",updatedInput:<original input>,updatedPermissions:[{type:"setMode",mode:"default",destination:"session"}]}` -> tool_result "User has approved your plan. You can now start coding... Your plan has been saved to: <path> ... ## Approved Plan: <md>". Claude then implemented; next Edit was prompted (default mode). Without the setMode update the mode behavior is UNVERIFIED (earlier notes: mode left plan only with updatedPermissions).
- get_plan control request returns the plan file contents afterwards.

## 4. AskUserQuestion  (VERIFIED end to end)

Request: `can_use_tool` `tool_name:"AskUserQuestion"`, `requires_user_interaction:true`, no permission_suggestions, `input:{questions:[{question,header,options:[{label,description}],multiSelect:bool},...]}` (1-4 questions; two in one call worked, mixed single/multi).
Response: `{"behavior":"allow","updatedInput":{"questions":<unchanged>,"answers":{"<question text>":"<label>"}}}`. Multi-select: comma+space joined string `"pytest, mypy"` (worked; Claude echoed it back; array form not tried). Tool result to model: `Your questions have been answered: "Which language?"="Swift", "Which toolchains?"="pytest, mypy". You can now continue with these answers in mind.`; `tool_use_result:{questions,answers}`. Free-text "Other" answer: just put any string as the value (UNVERIFIED but implied).

## 5. Images  (VERIFIED)

User line content array: `{"type":"user","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"<b64>"}},{"type":"text","text":"What single color fills this image? One word."}]}}` (16x16 red PNG). Replay echo keeps the array with the image block (isReplay:true). Claude answered "Red".

## 6. Message while busy  (VERIFIED, haiku; turn = Bash `sleep 12`)

Mid-turn user line is accepted, never rejected. Behavior by `priority` (sibling of `message`, top-level):
- none (plain): consumed at the next tool-result boundary inside the SAME turn (one `result`, num_turns 2); the model answered only the new message ("ALPHA", skipped "DONE1"). Echo `user` isReplay:true appears after the tool_result. Transcript logs `queue-operation enqueue`.
- "next": same as plain (merged into running turn); echo appeared twice in the stream (before and after tool_result) - dedupe by uuid. Answered BRAVO.
- "now": interrupts: running tool aborted, `result{result:"",terminal_reason:"aborted_tools",num_turns:2}`, then a new init + turn answering CHARLIE. (Earlier sloppy probe with a fast turn showed no abort, as the turn had ended.)
- "later": truly queued: current turn finishes normally (DONE1, result), then a separate turn (new init, result) answers DELTA. This is the "queue" behaviour; UI "Queue" button should use priority "later".
When the turn has already finished (fast count) all variants just start a new turn.

## 7. Resume / transcripts  (VERIFIED)

Path: `~/.claude/projects/<cwd with every non [A-Za-z0-9] char -> "-">/<session_id>.jsonl`; uses the REALPATH cwd (/private/tmp/... not /tmp). One file per session; /clear starts a new session id/file.
One JSON object per line, record `type`s: `session-owner{accountUuid,organizationUuid,sessionId}`, `tools-used{tools[]}`, `queue-operation{operation:"enqueue"|dequeue,content,timestamp}`, `attachment` (`attachment.type` = hook_success, hook_additional_context, file, environment, model, deferred_tools_delta, agent_listing_delta, mcp_instructions_delta, skill_listing, plan_mode, plan_mode_exit, total_tokens_reminder, instructions, session_context, date, async_hook_response, deferred_tools_record, prompt_snapshot, remote_session_change, ... each with `rendered:[{content}]` system-reminder text), `user`, `assistant`, `system` (`subtype` e.g. stop_hook_summary), `last-prompt{lastPrompt,leafUuid}`, `cost-state{totalCostUSD,modelUsage,...}`, `atis-latch`, `api-request`, `api-request-shape`, `api-request-blob` (bulky debug records; skip). Message-chain records carry `parentUuid, isSidechain, uuid, timestamp, sessionId, version, cwd, gitBranch, entrypoint:"sdk-cli", userType, slug, permissionMode`.
- user prompt: `{type:"user",promptId,message:{role:"user",content:"<text>"|[blocks]},permissionMode,promptSource:"sdk",turnOrigin:"sdk",turnPosition{promptIndex,turnIndex}}`.
- assistant: ONE LINE PER CONTENT BLOCK, same `message.id`: `message{model,id,role,content:[ONE block],stop_reason,usage}`. Blocks: `thinking{thinking,signature}` (text present because summarized), `text`, `tool_use{id,name,input,caller}`.
- tool result: `type:"user"`, `message.content:[{type:"tool_result",tool_use_id,content,is_error?}]`, top-level `toolUseResult` (the same object as stream `tool_use_result`: structuredPatch etc., or string on error), `sourceToolAssistantUUID`, `permissionDecision{decision,source}`.
- Resume: `--resume <id>` with --replay-user-messages: NOTHING from history replayed on stdout; first lines are the new turn's system/init (same session_id), status, echo of the new message. Context was retained (model answered earlier choice). Host must parse the jsonl to show history.

## 8. @file mentions  (VERIFIED)

`"@secret.py what is the value of SECRET_TOKEN? Do not use any tools."` as plain string content: CLI auto-attaches the file. Model answered `zebra-quartz-7731` with no tool_use in the stream (stdout shows nothing: no Read, no attachment line). Transcript shows `attachment{type:"file",filename,content:{type:"text",file{filePath,content,numLines,...}},displayPath:"secret.py"}` and `tools-used:["Read"]`, rendered to the model as a synthetic Read tool call. So: no host work needed, but the UI cannot see the attach on stdout; show the chip from what the user typed.

## Outside-edit attribution and background shells (Plan 4, Task 4)

Alloy attributes a disk change it was not told about to the one live session whose shell tool window covers the
change time. A window opens at the Bash `tool_use` and closes one second after its `tool_result`; this holds for
`run_in_background` calls too. A background call returns at once while its command keeps running, and the stream
does not reliably say when it ends, so writes a background command makes later than that second are recorded as
`.outside`. This is a known limit and it was chosen deliberately: labelling the user's own edits as Claude's is
worse than leaving a background command's edit unattributed.
