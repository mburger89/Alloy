# claude stream-json protocol notes (claude 2.1.319)

Verified by probe runs against `claude` 2.1.319 on 2026-11-07. Driver: `tools/ccprobe/drive.py` (`hooksrv.py` is the hook receiver used in the earlier hook experiments). Fixtures: `Tests/AlloyCoreTests/Fixtures/*.jsonl`, real CLI stdout lines only (host-written lines removed).

Probe flags: `-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --replay-user-messages --permission-prompt-tool stdio --model haiku --setting-sources project`. `--setting-sources project` is PROBE ONLY (so the user's allow rules do not hide prompts). The app never passes it.

## Thinking text: FOUND a way (hidden flag)

Thinking text is empty by default (`thinking_delta.thinking == ""`, only `estimated_tokens`). It is NOT fixed by `--settings '{"showThinkingSummaries":true}'` (tried, sonnet, `--effort max`: still empty) nor by `--effort`, `--model sonnet`, or prompt wording.

What works: the hidden CLI flag **`--thinking-display summarized`** (absent from `--help`, found in the binary; its choices include `summarized`, `omitted`, and `highlights`). With it, `thinking_delta` carries real text, wrapper events carry `"thinking_display":"summarized"`, and the final `assistant` thinking block has non-empty `thinking`. Fixture: `thinking-summarized.jsonl` (sonnet-5-5, `--thinking-display summarized --effort high`). A `set`-style control request also exists to change the display mode mid-session (binary text: "a value replaces the session display mode, null clears that override"); its subtype name was not probed.
Notes: `estimated_tokens` is `null` in summarized mode. Sonnet does not always think (an easy prompt produced zero thinking blocks), so the UI must handle turns with no thinking. Plan 3 may show summarized thinking text, with the "Thinking · N tokens" collapsed block as the fallback for `omitted`/empty.

## Message shapes (all verified)

Every top-level line is one JSON object with `type`.

- `system/init` — re-emitted at the start of EVERY turn. `{type,subtype:"init",cwd,session_id,tools[],mcp_servers[],model,permissionMode,slash_commands[],terminal_slash_commands[],claude_code_version,output_style,agents[],skills[],plugins[],capabilities[],memory_paths,fast_mode_state,uuid}`. `permissionMode` reflects `set_permission_mode` (saw `"plan"`).
- `system/status` `{status:"requesting"}`, `system/thinking_tokens {estimated_tokens,estimated_tokens_delta}`, `rate_limit_event {rate_limit_info}` — informational.
- `stream_event` `{event:<raw SSE>,session_id,parent_tool_use_id,uuid,api_message_id}`. Event types: message_start, content_block_start (thinking|text|tool_use), content_block_delta (`text_delta`, `thinking_delta`, `input_json_delta`, `signature_delta`), content_block_stop, message_delta, message_stop.
- `assistant` — one per content block, same `message.id`. Tool use block: `{"type":"tool_use","id":"toolu_..","name":"Edit","input":{file_path,old_string,new_string,replace_all}}`.
- `user` — host echo (`isReplay:true`, content string) OR tool result: `message.content[{type:"tool_result",tool_use_id,content,is_error?}]` plus top-level `tool_use_result` and `tool_result_meta:[{id,permission_decision:{decision,source,reason_type?},non_execution_kind?}]`.
- `result` — one per host user message: `{subtype,is_error,result,stop_reason,terminal_reason,num_turns,session_id,total_cost_usd,usage,modelUsage,permission_denials,duration_ms,...}`.

### Tool results (`tool_use_result`)

- Edit (edit-turn): `{"filePath":".../login.swift","oldString":"    return user == \"admin\"","newString":"    return user == \"root\"","originalFile":"import Foundation\n...","structuredPatch":[{"oldStart":1,"oldLines":6,"newStart":1,"newLines":6,"lines":[" ...","-    return user == \"admin\"","+    return user == \"root\""," }"]}],"userModified":false,"replaceAll":false}`
- Write create (write-create): `{"type":"create","filePath":".../notes.txt","content":"hi","structuredPatch":[],"originalFile":null,"userModified":false}`
- Write update (write-update): `{"type":"update","filePath":..,"content":"hello","structuredPatch":[{...,"lines":["-hi","\\ No newline at end of file","+hello","\\ No newline at end of file"]}],"originalFile":"hi"}`
- Read: `{"type":"text","file":{"filePath","content","numLines","startLine","totalLines"}}`. Bash: `{stdout,stderr,interrupted,isImage,noOutputExpected}`.
- Failed tool (failed-tool, permission-deny): `tool_use_result` is a plain STRING, e.g. `"Error: File does not exist. Note: your current working directory is ..."` or `"Error: Denied by host"`; the inner `tool_result` has `is_error:true`. Denied: `tool_result_meta[0]` = `{non_execution_kind:"permission-rule",permission_decision:{decision:"reject",source:"user_reject"}}`.
- No `gitDiff` anywhere.

### Permission flow (`--permission-prompt-tool stdio`; no `initialize` needed)

CLI -> host: `{"type":"control_request","request_id":"..","request":{"subtype":"can_use_tool","tool_name":"Edit","display_name":"Edit","input":{...},"description":"login.swift","permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],"tool_use_id":"toolu_.."}}`.
Host allow: `{"type":"control_response","response":{"subtype":"success","request_id":"..","response":{"behavior":"allow","updatedInput":{...}}}}`. Deny: `...{"behavior":"deny","message":".."}` (turn continues, file untouched). The CLI echoes the host's own `control_response` on stdout; ignore it (it is in the fixtures). `control_cancel_request {request_id}` withdraws a pending request.

**(e) `updatedPermissions` VERIFIED.** Allow with `"updatedPermissions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]` alongside `updatedInput` (permission-allow fixture): the next Write in the same turn was NOT prompted (`permission_decision:{decision:"accept",source:"config",reason_type:"mode"}`). `init.permissionMode` in the next turn still printed `default` (the mode change is session state, not reflected in init at that point).

### (b) AskUserQuestion — a `can_use_tool` control request, no special subtype

CLI -> host (`requires_user_interaction:true`, no permission_suggestions):
`{"type":"control_request","request_id":"..","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","display_name":"AskUserQuestion","input":{"questions":[{"question":"Which color do you prefer: red or blue?","header":"Color","options":[{"label":"Red","description":".."},{"label":"Blue","description":".."}],"multiSelect":false}]},"tool_use_id":"toolu_..","requires_user_interaction":true}}`.
Host answers with allow and `updatedInput` = the original input plus `"answers":{"<question text>":"<chosen label>"}`:
`{"behavior":"allow","updatedInput":{"questions":[...unchanged...],"answers":{"Which color do you prefer: red or blue?":"Blue"}}}`.
The tool result is `content:"Your questions have been answered: \"Which color...\"=\"Blue\". You can now continue with these answers in mind."` with `tool_use_result:{questions,answers}`; the model then answers ("You prefer blue."). If stdin closes while the question is pending the turn ends `terminal_reason:"aborted_tools"`. Multi-select answer shape (comma-joined vs array) NOT verified.

### (d) Plan mode / ExitPlanMode

`{"type":"control_request","request_id":"pm1","request":{"subtype":"set_permission_mode","mode":"plan"}}` -> `control_response {mode:"plan"}`; next `init.permissionMode == "plan"`. In plan mode Read/Bash-read run without prompts. The model first does a `ToolSearch select:ExitPlanMode` (tool_reference result), writes the plan file via Write WITHOUT a prompt (the CLI itself writes `~/.claude/plans/<slug>.md` — outside Alloy's control and not an edit to track), then:
`{"type":"control_request","request_id":"..","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","display_name":"ExitPlanMode","input":{"plan":"# Plan: ...markdown...","planFilePath":"$HOME/.claude/plans/read-login-swift-and-plan-xxx.md"},"tool_use_id":"toolu_..","requires_user_interaction":true}}`.
Allow with `updatedInput` = original input and `updatedPermissions:[{"type":"setMode","mode":"default","destination":"session"}]`: result text "User has approved your plan. You can now start coding...", `tool_use_result:{plan,isAgent:false,filePath}`; the very next Edit was prompted normally (mode left plan). Reject path (deny + feedback message) not probed.

### (c) `--resume <session_id>` after the process exits

Process 2 started with `--resume <id>` (same cwd) and a new stdin message: NOTHING from history is replayed on stdout. First lines are `system/init` (same `session_id` as the original) and `system/status`, then the new user echo, stream events, `assistant`, `result`. The model remembered the earlier turn (context restored from the on-disk transcript). The host must reload history itself (transcript file) if it wants to show it. Note `--resume` replaces `--session-id` (do not pass both).

### Interrupt

`{"type":"control_request","request_id":"int1","request":{"subtype":"interrupt"}}` while a `can_use_tool` is pending (interrupt fixture) -> `control_cancel_request {request_id:<pending>}`, `control_response {request_id:"int1",response:{still_queued:[]}}`, user tool_result "User rejected tool use" (`tool_use_result` string), user text "[Request interrupted by user for tool use]", then `result{subtype:"error_during_execution",is_error:true,terminal_reason:"aborted_tools"}`. The process stays alive. Interrupt mid-text-stream NOT tested.

### Compact (`/compact keep it short` as a user message)

compact fixture spans TWO turns (a normal "say hi" turn, then `/compact`), so it contains two `system/init` lines: init is emitted at the start of every turn, including the compact turn. Compact turn: `system/status` x2, `system/init`, `system/compact_boundary {compact_metadata:{trigger:"manual",pre_tokens,post_tokens,cumulative_dropped_tokens,duration_ms,preserved_segment,preserved_messages}}`, `user` (summary), `user` `<local-command-stdout>Compacted </local-command-stdout>`, `result{subtype:"success",result:"",num_turns:0}`.

### Other control requests (earlier probe)

`initialize`, `set_permission_mode {mode}`, `set_model {model}` (-> `{model:"claude-sonnet-5-5"}`), `get_settings`; unknown subtype -> `{"subtype":"error","request_id","error":"Unsupported control request subtype: .."}`. Mid-turn user line with `"priority":"next"` is consumed in the same turn; echo has `isReplay:true`. Hooks (`--settings` inline http hooks) fire with `tool_response` carrying `structuredPatch`/`originalFile`; `additionalContext` from a PreToolUse hook reaches the model.

### Unknown / malformed lines

`unknown-lines.jsonl`: one real assistant line, `{"type":"brand_new_thing"}`, a truncated line `{"type":"assist`, one real result line. Decoders must skip the last two without failing later lines.

## Still unverified

Multi-select AskUserQuestion answer shape; ExitPlanMode rejection; interrupt mid-stream; `--thinking-display` control request subtype for changing mode mid-session; `priority:"now"/"later"`; plain mid-turn line without priority; hook blocking decisions; `--bare` (never used).
