# Protocol notes, Plan 5 (claude 2.1.319, 2026-11-09)

## Resume and fork: model, permission mode, history (Task 7 probe)

Setup: `claude -p` stream-json, `--model haiku`, then `set_model sonnet` and `set_permission_mode plan` as control requests, one tiny turn ("Reply with the single word OK."). Then three further runs in the same scratch directory, each with one such turn and no `--model` or permission flags:

| Run | `system/init` model | `permissionMode` | session_id |
|---|---|---|---|
| original | claude-sonnet-5-5 | plan | 6882f2a8-... |
| `--resume 6882f2a8-...` | claude-sonnet-5-5 | plan | same |
| `--resume 6882f2a8-... --fork-session` | claude-sonnet-5-5 | auto (the machine default) | 190cd199-... (new) |

Conclusions:
- `--resume` restores both the model and the permission mode. A relaunch needs no `set_model` / `set_permission_mode` re-sent.
- `--fork-session` keeps the model but not the permission mode. Alloy sets the fork's mode from the source (deferred control, sent before anything else).
- The fork's `<new-id>.jsonl` contains the copied history (the source's user/assistant lines rewritten with the new sessionId) followed by the fork's own turns. Before the fork's first turn there is no file of its own, so Alloy shows the source's file as the fork's history. After the first turn in a later run, the fork's own file holds everything.
- `--resume` of a conversation whose file is gone fails in the CLI; Alloy checks for the source file when waking an unsent fork and says "Fork source no longer exists".

## Live check of the whole feature (Task 9, claude 2.1.319, model claude-haiku-5-5, 2026-11-09)

Run with `ALLOY_LIVE=1 swift test --filter LiveKnowledgeTests` (opt-in; skipped otherwise). It drives a real `Workspace`
with the real `ClaudeProcess` (wrapped in a recorder) over a scratch git repo with `hello.py` and `util.py`, a temp
appSupport, `/model haiku`, and short explicit prompts. Retried once with a firmer prompt when the model skipped a
tool. Two clean runs, about 44 s each; cost per run: A about $0.016 (513k tokens, mostly cache reads), B about $0.006
(143k to 181k), fork about $0.0005 (36k).

| Assertion | Result | Evidence |
|---|---|---|
| A's Read of hello.py is indexed | pass | `readIndex.entries(of: A)` has `hello.py` |
| A's note exists, author is A | pass | one note, subject `file("hello.py")`, author A, text from `notes_write` |
| B's `notes_lookup` and `notes_read` succeed | pass | both `tool_use`/`tool_result` succeeded in B's stream |
| No permission request for the notes tools | pass | zero permission blocks (the `can_use_tool` requests become them); the `--allowedTools` rule works |
| B's first message carries "Shared by other sessions (via Alloy):" | pass | on the wire as its own leading text part (excerpt below) |
| B's repeat message does not repeat the block | pass | by design, told once per file |
| Fork of A, asked which file it summarised, names hello.py | pass | reply "hello.py"; the fork got a new session id |
| After `/compact` on A, a re-read is not redundant | pass | `compact_boundary` arrived (pre 37k, post 12k tokens); redundant count stayed 1 -> 1 while util.py was read again (2 -> 3 Reads) |
| Baseline: a repeat read before compaction is redundant | pass | 0 -> 1 |

Findings (honest record):
- One earlier run failed the compaction assertion (redundant 1 -> 2). The cause was the test, not the feature: the model
  had written a note on util.py, and a current note makes a read redundant by design. The test now tells A not to write
  notes, and reports "not observed" if a note on the file exists. The same applies to hello.py (it has a note, and the
  fork holds a copy), which is why the compaction check uses util.py.
- Another run skipped the post-compact Read on the first prompt (the model answered from the summary); the firmer
  prompt made it call Read. Tool use is guidance, not enforcement.
- The model passed wrong argument names twice: `notes_write` with `summary` instead of `text` (the tool answered
  "Error: text is required." and the model retried correctly), and `notes_read` with `lines: "1-3"` instead of
  `startLine`/`endLine`, which was ignored and returned the whole file (7 lines). Fixed after the final review:
  `MCPServer` now answers an unknown or non-object `arguments` with an `isError` tool result naming the valid keys, and
  the schemas say `additionalProperties: false`.
- Hooks configured on the test machine add some noise to the sessions; harmless.

Scrubbed excerpts (`tools/ccprobe/scrub.py`; session A wrote, session B read):

```
A notes_lookup {"path":"hello.py"}  -> Shared knowledge about hello.py: Read by: nobody yet. notes_read can serve it: no (...). Notes: none.
A notes_write  {"path":"hello.py","text":"hello.py defines greet(name), ... "} -> Saved your note on hello.py.
B notes_lookup {"path":"hello.py"}  -> Shared knowledge about hello.py:
                                       Read by:
                                       - A read the whole file at 2026-11-09T18:54:21Z (file unchanged since)
                                       notes_read can serve it: yes, the whole file.
                                       Notes:
                                       - [current] A, 2026-11-09T18:54:24Z: hello.py defines greet(name), ...
B notes_read   {"path":"hello.py","startLine":1,"endLine":3} -> 1	def greet(name): / 2	    return "hello, " + name / 3
B first user message on the wire, content parts:
  [0] "Shared by other sessions (via Alloy):\nhello.py — read by \"A\" at 10:54, unchanged since. Summary: hello.py defines greet(name), ..."
  [1] "Call mcp__alloy__notes_lookup for hello.py, then mcp__alloy__notes_read for lines 1-3 of hello.py, and reply with what you got."
```

## Fork point: `--resume-session-at` (probe, 2026-11-09, claude 2.1.319, haiku)

`claude --help` does not list the flag, but the CLI accepts `--resume-session-at <message uuid>` together with
`--resume <id> --fork-session` (the Agent SDK's `resumeSessionAt`). Probe in a scratch directory, two turns
("Reply with just: one", "Now reply with just: two"), then a fork asked to quote every earlier user message:

| Launch | The fork saw |
|---|---|
| `--resume S --fork-session` | both user messages |
| `--resume S --fork-session --resume-session-at <uuid of the first assistant record>` | only "Reply with just: one" |
| `--resume S --fork-session --resume-session-at <uuid of the last user/assistant record>` | both |
| `--resume S --fork-session --resume-session-at 00000000-0000-0000-0000-000000000000` | no run: prints `No message found with message.uuid of: <uuid>` |

So the flag works, and an unknown uuid is an error, not a fallback. Alloy takes the uuid from the source's own
transcript file (`TranscriptFile.lastMessageUUID`: the newest `user` or `assistant` record outside a sidechain), saves it as
`Session.forkPoint` beside `forkSource`, passes it on every launch of the unsent fork (first launch, relaunch at
idle, wake after a restart), and cuts the fork's replayed history at the same uuid. Before a launch it checks that the
uuid is still in the source file; if not it drops the point, shows "This fork's source has moved on; the fork now
starts from its latest point." and launches without the flag. The point is cleared with `forkSource` at the fork's first
`system/init`. The flag is undocumented, so if a CLI refuses it (an exit before the first init whose stderr mentions
`resume-session-at`, `unknown option` or `No message found`), Alloy clears `forkPoint`, saves that, shows "Couldn't fork at
the exact point; the fork starts from the source's latest point." and launches once more without the flag. The retry
carries no point, so there is no third attempt. The point is the source's last assistant record (a user record is not
used, and a user uuid was not probed).
