# Alloy Plan 3: Rich chat — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Plan 1's plain chat into the rich, central chat of spec §6.2. Each block has a color and an icon. Replies are block markdown, thinking can be collapsed, and tool blocks get real bodies. There are question and plan cards, and the composer gains everything the user uses in the CLI: slash commands, `@file`, images, queueing, mode and model, and stop. Past sessions show their history again.

**Architecture:** Protocol work stays in `AlloyCore`:
- wire types;
- the `Transcript` model;
- `Workspace` control methods;
- a transcript-file replayer;
- a project file index.

`AlloyKit` gets one style table (kind → tint, ink, icon) and small block views built on it. The composer's state lives in an `@Observable ComposerModel` so its key routing is unit-testable without a window. MetalUI supplies icons (G3), stick-to-bottom (G6), block markdown (G2) and the suggestion overlay. Anything not merged when its task starts uses the logged stopgap the task names.

**Tech Stack:** Swift 6.1 (Swift 6 language mode), macOS 14, MetalUI (path dependency `../MetalUI`), `MetalUIMarkdown`, Swift Testing, `MetalUITesting`.

**Spec:** `docs/superpowers/specs/2026-11-07-alloy-design.md` (§6.2 chat, §6.3 hosting, §6.7). Protocol facts: `docs/protocol-notes.md` plus the probe results in `.superpowers/sdd/plan-3-4-research/cli-features.md`. Copy that file to `docs/protocol-notes-plan3.md` in Task 1, since `.superpowers` is not committed.

## Global Constraints

- MetalUI only for UI. Gaps go to the MetalUI session and are logged in `docs/metalui-gaps.md`. Stopgaps stay minimal.
- Never write to `~/.claude` or the project's `.claude/`. Reading `~/.claude/projects/<slug>/<id>.jsonl` (Task 5) is read-only and allowed.
- Never pass `--bare`, `--permission-mode` or `--setting-sources`. Permissions follow the user's Claude settings.
- Alloy must not be branded or named "Claude Code".
- Every new interactive view gets an `.accessibilityIdentifier`, which is the test hook. Keep every existing identifier, because Bench and the Plan 1 tests use them.
- Colors are `ThemeColorKey` tokens in `Sources/AlloyKit/Theme.swift`, never inline hex in views.
- The icon name per block is fixed in Task 6. On Linux and Windows only MetalUI's 38 bundled names draw. That is acceptable for macOS-only v1, but log names outside the bundled table in `docs/metalui-gaps.md` under G3.
- Fixtures are real CLI stdout, scrubbed with `tools/ccprobe/scrub.py`. Never hand-write a fixture line that the CLI has not produced.
- Swift Testing (`@Suite`, `@Test`, `#expect`). Run with `swift test`, and read the printed counts, not the exit status. The release build must have zero warnings.
- Agents kill only processes they started. No broad `pkill`.
- Commit trailer, on every commit:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Review Focus

1. **The user sends while Claude is mid-turn, several times quickly.** Each message appears exactly once: queued messages show as queued until echoed, and the doubled `"next"` echo is deduplicated by uuid. Test in Task 2.
2. **`/clear` then app relaunch.** The session must resume the *new* CLI session id, not the original Alloy id, or the history and context are wrong. Test in Task 3.
3. **A restored session whose transcript file is missing, truncated mid-line or huge (50 MB).** The chat shows what could be read plus one notice and never hangs the UI: parsing runs off the main actor and keeps only the last 2000 blocks. Test in Task 5.
4. **AskUserQuestion with "Other" free text and multi-select, and a plan sent back with feedback.** Claude receives exactly the documented shapes. Tests in Task 8.
5. **A pasted TIFF screenshot or a 20 MB image.** TIFF is converted to PNG. Images over 5 MB after encoding are refused with a visible message, never sent. Test in Task 11.

---

### Task 1: Wire-protocol additions

**Files:**
- Modify: `Sources/AlloyCore/Wire/InboundMessage.swift`, `Sources/AlloyCore/Wire/OutboundMessage.swift`, `Sources/AlloyCore/Wire/JSONValue.swift`
- Create: `Tests/AlloyCoreTests/Fixtures/{ask-question,plan-allow,plan-deny,slash-local,clear,image,queue-next,queue-later,interrupt-stream}.jsonl` (scrubbed from local probe captures (not committed): CLI→host lines only, host lines dropped; `p6a-d` for queueing)
- Create: `docs/protocol-notes-plan3.md` (copy of `.superpowers/sdd/plan-3-4-research/cli-features.md`)
- Test: `Tests/AlloyCoreTests/InboundDecoderTests.swift`, `OutboundTests.swift`

**Interfaces:**
- Produces:
  - `SystemInit` gains `skills: [String]`, `agents: [String]`, `terminalSlashCommands: [String]`, `claudeCodeVersion: String?`, `cwd: String?`.
  - `public struct SlashCommandInfo: Sendable, Equatable, Codable { name: String; description: String; argumentHint: String? }`
  - `InboundMessage` gains these cases:
    - `.commandsChanged([SlashCommandInfo])` for `system/commands_changed`
    - `.statusChanged(permissionMode: String?)` for `system/status`, which was `.ignored`
    - `.conversationReset(newSessionID: String)` for top-level `conversation_reset`
    - `.localCommandOutput(text: String)` for an `assistant` with `message.model == "<synthetic>"` or a top-level `local_command_source`
    - `.controlResponse(requestID: String, result: ControlResult)` with `public enum ControlResult: Sendable, Equatable { case success(JSONValue); case error(message: String, code: String?) }`. The CLI's echo of *our* `control_response` lines (no `request_id` match) stays `.ignored`.
  - `.userEcho` becomes `.userEcho(text: String, imageCount: Int, uuid: String?, isReplay: Bool)`.
  - `TurnResult` gains `durationMS: Int?`, `numTurns: Int?`.
  - `public enum UserContent: Sendable, Equatable { case text(String); case image(mediaType: String, base64: String) }`
  - `OutboundMessage.user(content: [UserContent], uuid: UUID, priority: Priority?)`, with a convenience `static func user(text:uuid:priority:)`.
  - `.allow(requestID: String, updatedInput: JSONValue, updatedPermissions: [JSONValue]?)`, where nil omits the key.
  - `ControlSubtype` gains `.initialize`.
  - `JSONValue.objectValue: [String: JSONValue]?`.

- [ ] **Step 1: Make the fixtures.** Extract the CLI stdout lines of each probe into the fixture names above. Run `python3 tools/ccprobe/scrub.py` on them, as Plan 1 did.
- [ ] **Step 2: Write the failing decoder tests.**
  - `askQuestionDecodesAsCanUseTool`: `ask-question.jsonl` yields `.controlRequest(.canUseTool(toolName: "AskUserQuestion", …))` whose input has `questions[0].options` non-empty.
  - `slashLocalDecodesAsCommandOutput`: `slash-local.jsonl` (the `/cost` probe) yields exactly one `.localCommandOutput` whose text is non-empty, and no `.assistantBlock`.
  - `clearDecodesReset`: `clear.jsonl` yields `.conversationReset(newSessionID:)` equal to the following init's `session_id`.
  - `statusCarriesMode`: a `system/status` line with `permissionMode:"plan"` yields `.statusChanged(permissionMode: "plan")`.
  - `imageEchoCountsImages`: `image.jsonl`'s replayed user line yields `.userEcho(…, imageCount: 1, …)`.
  - `initializeResponseDecodes`: a control_response with a matching `request_id` and `response.commands[]` yields `.controlResponse(…, .success(_))`.
  - `controlErrorDecodes`: the `set_model` not_found error yields `.error(message: "Model 'nonexistent-model' not found", code: "not_found")`.
  - `systemInitKeepsSkills`: `skills` and `terminalSlashCommands` are non-empty.
- [ ] **Step 3: Write the failing encoder tests.**
  - `userWithImageEncodesContentArray`: the output equals `{"message":{"content":[{"source":{"data":"QUJD","media_type":"image/png","type":"base64"},"type":"image"},{"text":"hi","type":"text"}],"role":"user"},"parent_tool_use_id":null,"type":"user","uuid":"…"}` with sorted keys.
  - `textOnlyUserStaysString`: a single `.text` encodes `content` as a string, byte-identical to Plan 1.
  - `allowWithPermissions` and `initializeEncodes`.
- [ ] **Step 4: Run the tests** (`swift test --filter "InboundDecoderTests|OutboundTests"`). Expected: they fail to compile or fail.
- [ ] **Step 5: Implement.** Decode `assistant` with `message.model == "<synthetic>"` before the normal path. Keep `InboundDecoder.decode` non-throwing.
- [ ] **Step 6: Run the full suite.** Expected: all pass. Update the existing tests that pattern-match `.userEcho` or `.user(text:…)` mechanically.
- [ ] **Step 7: Commit** with `feat(wire): images, local command output, resets, control responses (Plan 3)`.

### Task 2: Transcript model upgrades

**Files:**
- Modify: `Sources/AlloyCore/Chat/Transcript.swift`, `Sources/AlloyCore/Chat/ToolKind.swift`
- Test: `Tests/AlloyCoreTests/TranscriptTests.swift`

**Interfaces:**
- Consumes: the Task 1 messages.
- Produces:
  - `ToolBlock` gains `input: JSONValue`, `startedAt: Date?`, `endedAt: Date?` and `result: JSONValue?` (the raw `tool_use_result`).
  - `ToolResultMessage` gains `raw: JSONValue?`. Decode it in Task 1 if it isn't there yet.
  - `public struct QuestionBlock: Sendable, Equatable { requestID: String; toolUseID: String?; questions: [Question]; state: CardState; answers: [String: String] }`, where `Question { question: String; header: String; options: [Option(label: String, description: String)]; multiSelect: Bool }`.
  - `public struct PlanBlock: Sendable, Equatable { requestID: String; toolUseID: String?; plan: String; planFilePath: String?; state: CardState; feedback: String? }`.
  - `public enum CardState: Sendable, Equatable { case pending, answered, sentBack, cancelled }`
  - `ChatBlock` gains `.question(QuestionBlock)` and `.plan(PlanBlock)`. Their ids are `q-<requestID>` and `plan-<requestID>`.
  - `.user` becomes `.user(id: UUID, text: String, imageCount: Int, state: UserState)` with `public enum UserState: Sendable, Equatable { case sent, queued(Priority) }`.
  - `NoticeKind` gains `.modeChanged` and `.reset`.
  - `Transcript.apply(_:)` takes a clock: `apply(_ message: InboundMessage, now: Date)`. The old one-argument form calls it with `Date()`.
  - New methods:
    - `appendUser(text:imageCount:id:queued: Priority?)`
    - `resolveQuestion(requestID:answers:)`
    - `resolvePlan(requestID:approved:feedback:)`

- [ ] **Step 1: Write the failing tests.**
  - `askQuestionBecomesQuestionCard`: `ask-question.jsonl` yields a `.question` block, not a `.permission` block.
  - `exitPlanModeBecomesPlanCard`: `plan-allow.jsonl` yields a `.plan` block with a non-empty `plan`.
  - `planRevisionAddsSecondCard`: `plan-deny.jsonl` yields two `.plan` blocks. The first is `.sentBack` after `resolvePlan(approved:false, feedback:"x")`; the second is `.pending`.
  - `queuedMessageShowsUntilEchoed`: `appendUser(queued: .next)` then the `queue-next.jsonl` echoes leave one `.user` block with state `.sent`. The doubled `"next"` echo adds nothing; dedupe by uuid.
  - `queueLaterRunsAsOwnTurn`: with `queue-later.jsonl`, the queued user block flips to `.sent` only when its echo arrives, after the first `result`.
  - `localCommandOutputIsNotice`: `slash-local.jsonl` yields one `.notice(kind: .commandOutput)` with the `/cost` text, and no `.assistantText`.
  - `toolBlockKeepsInputAndTiming`: Bash in `interrupt.jsonl` has `input["command"]` set and `startedAt` set. When `endedAt` is set, it is later than `startedAt`.
  - `streamInterruptMarksTurn`: `interrupt-stream.jsonl` (`terminal_reason:"aborted_streaming"`) yields an `.interrupted` notice and stops the streaming text.
- [ ] **Step 2: Run the tests.** Expected: they fail.
- [ ] **Step 3: Implement.**
  - A `can_use_tool` request for `AskUserQuestion` or `ExitPlanMode` creates the card instead of `.permission`. Every other tool stays `.permission`.
  - `.controlCancel` sets a card's state to `.cancelled`.
  - `.localCommandOutput` adds a `.commandOutput` notice.
  - `.conversationReset` adds a `.reset` notice "Conversation cleared".
  - Echo matching goes by uuid first, then by text as in Plan 1.
- [ ] **Step 4: Run the full suite.** Expected: all pass.
- [ ] **Step 5: Commit** with `feat(chat): question and plan cards, queued messages, tool input and timing`.

### Task 3: Workspace and Session control API

**Files:**
- Modify: `Sources/AlloyCore/Model/Workspace.swift`, `Sources/AlloyCore/Model/Session.swift`
- Test: `Tests/AlloyCoreTests/WorkspaceTests.swift`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces:
  - Session state:
    - `Session.cliSessionID: String`, which starts as `id.uuidString.lowercased()`, is replaced on `.conversationReset`, and is persisted.
    - `Session.slashCommands: [SlashCommandInfo]`
    - `Session.terminalOnlyCommands: Set<String>`
    - `Session.queued: [UUID]`
  - `SessionRecord` gains `cliSessionID: String?`, `model: String?` and `permissionMode: String?`. Decoding must still read Plan 1's files: missing means use the defaults.
  - `LaunchConfiguration` gains `resumeID: String?`, used with `--resume` instead of `sessionID` when set.
  - Workspace methods:
    - `func send(_ message: OutgoingMessage, to: Session.ID) async`, with `public struct OutgoingMessage: Sendable, Equatable { text: String; images: [ImageAttachment]; priority: Priority? }` and `public struct ImageAttachment: Sendable, Equatable, Identifiable { id: UUID; mediaType: String; base64: String; pixelSize: (Int, Int)?; byteCount: Int }`. Make it `Equatable` by comparing `id`, `mediaType` and `byteCount`. The old `send(_ text:to:)` wraps it.
    - `func setModel(_ model: String, for: Session.ID) async`
    - `func setPermissionMode(_ mode: PermissionMode, for: Session.ID) async`, with `public enum PermissionMode: String, CaseIterable, Sendable { case default_ = "default", acceptEdits, plan, auto, dontAsk }` and display names "Default", "Accept edits", "Plan", "Auto", "Don't ask".
    - `func answerQuestion(session:requestID:answers: [String: String]) async`
    - `func answerPlan(session:requestID:approve: Bool, modeAfter: PermissionMode, feedback: String?) async`
    - `func rename(_ id: Session.ID, to: String)`

- [ ] **Step 1: Write the failing tests**, using `ScriptedTransport`.
  - `setModelSendsControlAndUpdates`: the sent message is `.control(_, .setModel("opus"))`. On `.controlResponse(.success(["model":"claude-opus-5-5"]))`, `session.model == "claude-opus-5-5"` and a `.modelChanged` notice reads "Model: claude-opus-5-5". On `.error`, an `.error` notice carries the message.
  - `setModeSendsControl`: sends `.setPermissionMode("plan")`. `.statusChanged("plan")` sets `session.permissionMode` and adds a `.modeChanged` notice "Mode: Plan".
  - `answerQuestionSendsAnswers`: `updatedInput` equals the original input plus `"answers": {"Which language?": "Swift", "Which toolchains?": "pytest, mypy"}`. Multi-select is joined with `", "`. `updatedPermissions` is nil.
  - `approvePlanSetsMode`: `updatedPermissions == [{"type":"setMode","mode":"acceptEdits","destination":"session"}]` and `updatedInput` is the original input.
  - `sendBackPlanDenies`: `.deny(requestID, message: "Revise: <feedback>")`. Empty feedback gives `"Revise the plan."`
  - `clearAdoptsNewSessionID`: after `.conversationReset(newSessionID: "abc")`, `cliSessionID == "abc"`. Persist, restore and send: the transport's `LaunchConfiguration.resumeID == "abc"`.
  - `initializeAfterStart`: the first message sent after start is `.control(_, .initialize)`. Its success response fills `slashCommands` with `{name, description, argumentHint}`. `.commandsChanged` replaces them.
  - `busySendUsesPriority`: while `.working`, `send(OutgoingMessage(text:"x", images:[], priority:.later))` writes priority `"later"` and adds a `.queued(.later)` user block.
  - `imagesEncodeAsContent`: the sent `.user(content:)` has `.image` first, then `.text`.
  - `plan1SessionsFileStillLoads`: a Plan 1 `sessions.json` without the new keys restores.
- [ ] **Step 2: Run the tests.** Expected: they fail.
- [ ] **Step 3: Implement.**
  - Track pending control requests by `request_id` in a private map, so the response routes to the right handler.
  - Send `initialize` immediately after start.
  - Hide every name in `terminalSlashCommands` from `slashCommands`.
- [ ] **Step 4: Run the full suite.** Expected: all pass.
- [ ] **Step 5: Commit** with `feat(model): model and mode control, cards answering, /clear session ids, images`.

### Task 4: Slash commands handled by Alloy

**Files:**
- Create: `Sources/AlloyCore/Chat/SlashCommands.swift`, `docs/slash-commands.md`
- Test: `Tests/AlloyCoreTests/SlashCommandTests.swift`

**Interfaces:**
- Produces: `public enum SlashRoute: Equatable { case passThrough; case setModel(String); case showModelPicker; case setMode(PermissionMode); case localHelp }` and `public enum SlashCommands { static func route(_ text: String) -> SlashRoute }`.
  - `/model <name>` routes to `.setModel`.
  - `/model` alone routes to `.showModelPicker`.
  - `/plan` routes to `.setMode(.plan)`.
  - `/help` routes to `.localHelp`, because the CLI turns it into a wasted model turn.
  - Everything else, including `/compact`, `/clear`, `/cost`, `/context`, skills and unknown names, routes to `.passThrough`.
- `Workspace.send` applies the route before writing:
  - `.localHelp` adds a `.commandOutput` notice listing `slashCommands` (name — description).
  - `.showModelPicker` sets `Session.requestModelPicker = true`, which Task 10 observes.

- [ ] **Step 1: Write the failing tests.** Check the routing table above row by row. Add `helpListsCommandsLocally`: nothing is sent to the transport, and the notice contains "compact".
- [ ] **Step 2: Implement.** Write `docs/slash-commands.md` from the probe table in `docs/protocol-notes-plan3.md`. For every built-in it says what Alloy does: passes it through, handles it itself, or hides it as terminal-only. It explicitly lists commands that cannot work headless (`/doctor`, `/color`, `/focus`, `/config`).
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(chat): slash command routing and support table`.

### Task 5: History replay from the transcript file

**Files:**
- Create: `Sources/AlloyCore/Chat/TranscriptFile.swift`
- Create: `Tests/AlloyCoreTests/Fixtures/transcript-sample.jsonl`. Scrub one real transcript from the ccprobe3 runs, with `api-request*` records removed.
- Test: `Tests/AlloyCoreTests/TranscriptFileTests.swift`

**Interfaces:**
- Produces:
  - `public enum TranscriptFile`:
    - `static func url(cliSessionID: String, projectRoot: URL, home: URL) -> URL`: `<home>/.claude/projects/<realpath(projectRoot) with every non-[A-Za-z0-9] char → "->/<id>.jsonl`.
    - `static func messages(from data: Data) -> (messages: [InboundMessage], skippedLines: Int)`. It maps records to the same `InboundMessage`s the live stream gives, and skips `attachment`, `queue-operation`, `api-request*`, `cost-state` and the rest.
  - `Workspace.loadHistory(_ id: Session.ID) async`. It runs once per session on first selection of a restored session: parse off the main actor, then feed `Transcript.apply` on main.
    - Keep only the last 2000 blocks.
    - Re-attach edits by matching `EditRecord.toolUseID` to tool blocks, so in-chat diffs return.
    - A missing file adds the notice "No earlier history found".
    - Skipped or unreadable lines add one notice: "N lines of history could not be read".

- [ ] **Step 1: Write the failing tests.**
  - `slugMatchesCLI`: `/private/tmp/a b/c.d` maps to `-private-tmp-a-b-c-d`.
  - `sampleReplaysBlocks`: the fixture yields user, assistantText, tool and thinking blocks in order. The thinking block has text.
  - `truncatedLastLineSkipped`: a fixture cut mid-line gives `skippedLines == 1` and the earlier blocks intact.
  - `largeFileKeepsTail`: a synthetic 3000-turn transcript built from fixture records leaves 2000 blocks, and the last block matches.
  - `historyReattachesEdits`: a ledger with an `EditRecord(toolUseID: "toolu_X")` and a transcript with that tool give the replayed tool block `editIDs == [record.id]`.
  - `restoredSessionLoadsOnSelect`: the `Rig` with `home` injected and a dormant session gives history blocks after `loadHistory`. Nothing is launched.
- [ ] **Step 2: Implement.** Assistant records are one line per content block. Map each to `.assistantBlock`. A `user` record with `toolUseResult` maps to `.toolResult`. Inject `home` through `Workspace.init`, defaulting to `FileManager.default.homeDirectoryForCurrentUser`.
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(chat): replay session history from the CLI transcript`.

### Task 6: Block style table, icons, collapsible block chrome, stick-to-bottom

**Files:**
- Create: `Sources/AlloyKit/BlockStyle.swift`, `Sources/AlloyKit/BlockChrome.swift`
- Modify: `Sources/AlloyKit/Theme.swift`, `Sources/AlloyKit/ChatView.swift`, `Sources/AlloyKit/ChatBlockViews.swift`, `docs/metalui-gaps.md`
- Test: `Tests/AlloyKitTests/ChatStyleTests.swift`

**Interfaces:**
- Produces:
  - `enum BlockKind: CaseIterable { case thinking, read, search, shell, edit, write, web, subagent, todo, question, plan, mcp, other, error, overlap, notice, command, user }`
  - `struct BlockStyle { tint: Color; ink: Color; icon: String }` and `static func style(_ kind: BlockKind) -> BlockStyle`, with icons:

    | thinking | read | search | shell | edit | write | web | subagent | todo | question | plan | mcp | other | error | overlap | notice | command | user |
    |---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
    | `brain.head.profile` | `doc.text` | `magnifyingglass` | `terminal` | `pencil` | `doc.badge.plus` | `globe` | `cpu` | `checklist` | `questionmark.bubble` | `list.bullet.clipboard` | `puzzlepiece.extension` | `sparkles` | `xmark.circle` | `exclamationmark.triangle` | `info.circle` | `chevron.right` | `person` |

    `checklist`, `questionmark.bubble`, `list.bullet.clipboard`, `puzzlepiece.extension` and `info.circle` are outside MetalUI's bundled set, so they draw only on macOS. Log them under G3 and send the list to the MetalUI session.
  - New theme tokens:
    - ink tokens per family: `thinkingInk` purple, `readInk` teal, `shellInk` amber, `editInk` green, `webInk` blue, `questionInk` indigo, `planInk` indigo, `errorInk` red, `warningInk` amber
    - `questionTint`, `planTint`, `commandTint`

    Use light and dark pairs. Pick values that read on `chatFill`; spec §8 leaves the palette to the builder.
  - `struct BlockChrome<Body: Element>: Component`, initialised with `(kind:, title:, summary:, trailing: String?, collapsed: Binding<Bool>?, id:, body:)`.
    - A header row: icon in the ink color, title, summary in secondary text, and the trailing chip.
    - It has the identifier `block-header-<id>`, and clicking it toggles `collapsed` when non-nil.
    - The body shows when expanded. The background is the tint, with radius 8.
- Stick to the bottom: `TranscriptView` drops `ScrollViewReader` and `TailKey`, and puts `.defaultScrollAnchor(.bottom)` on its `ScrollView` (G6; it must be on the `ScrollView` itself). Mark G6 "adopted" in `docs/metalui-gaps.md`.
- Default collapse rules:
  - Thinking is expanded while streaming and collapses when its turn's text starts.
  - Read, search, web, todo and mcp blocks are collapsed.
  - Edit and write blocks are expanded.
  - Shell blocks are expanded, capped at 20 lines with "Show all".

  Keep the state in a `@State` dictionary in `TranscriptView`, keyed by block id, so a collapse survives re-render.

- [ ] **Step 1: Write the failing tests**, headless.
  - `everyKindHasDistinctIconAndTint`: the `BlockStyle` table is total, and no two of thinking, read, shell, edit, web, error and question share a tint.
  - `thinkingCollapsesAfterText`: emit thinking deltas, then text. The header `block-header-<thinkingID>` exists, and the body text is no longer in the tree.
  - `clickHeaderExpands`: clicking a collapsed read header shows the body.
  - `transcriptFollowsBottom`: emit 200 notices. The last one is on screen (frame inside the window), with no `scrollTo` involved.
- [ ] **Step 2: Implement.** Move each existing block view onto `BlockChrome`. Keep the Plan 1 identifiers: `approve-`, `deny-`, `keep-`, `revert-` and `show-all-`.
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(ui): block colors, icons, collapsible chrome, stick-to-bottom (G3, G6)`.

### Task 7: Tool block bodies

**Files:**
- Create: `Sources/AlloyKit/ToolBodies.swift`
- Modify: `Sources/AlloyKit/ChatBlockViews.swift`, `Sources/AlloyCore/Chat/ToolKind.swift` (summaries)
- Test: `Tests/AlloyKitTests/ToolBodyTests.swift`, `Tests/AlloyCoreTests/ToolSummaryTests.swift`

**Interfaces:**
- Consumes: `ToolBlock.input`, `result`, `startedAt`, `endedAt` (Task 2) and `BlockChrome` (Task 6).
- Produces the body per kind. Every path is relative to the project root.

  | Kind | Summary | Body | Trailing chip |
  |---|---|---|---|
  | shell | — | `$ <command>` in Menlo, then stdout and stderr (stderr in `errorInk`), capped at 20 lines with "Show all" | duration `1.2 s`, plus `interrupted` when the result says so |
  | read | `<path> · <numLines> lines` | the first 40 lines of the content, Menlo, with line numbers from `startLine` | — |
  | search | `"<pattern>" · <n> matches` (Grep) or `<glob> · <n> files` (Glob) | the result lines, first 50 | — |
  | web | URL or query | the first 20 lines of the result text | — |
  | subagent | the `description` input | the prompt (collapsed) and the result text | — |
  | todo | — | a checklist of the TodoWrite `todos` input: ✓ done, ● in progress, ○ pending | — |
  | mcp | `server · tool` | the input JSON, pretty-printed and capped at 30 lines | — |
  | failure | — | the error text in `errorInk` | — |

  A failed block gets the `.error` kind's icon in the header.
- `ToolSummary.line` gains Grep and Glob match counts, taken from the result when present.

- [ ] **Step 1: Write the failing tests.** One test per row of the table above, using fixtures or inline `ToolBlock` values whose `input` and `result` are copied from real fixture lines.
  - `shellShowsCommandAndDuration`
  - `readSummaryCountsLines`
  - `todoRendersChecklist`
  - `failedToolUsesErrorKind`
  - `mcpShowsPrettyInput`
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(ui): tool block bodies for shell, read, search, web, agent, todo, mcp`.

### Task 8: Question and plan cards

**Files:**
- Create: `Sources/AlloyKit/QuestionCard.swift`, `Sources/AlloyKit/PlanCard.swift`
- Test: `Tests/AlloyKitTests/CardTests.swift`

**Interfaces:**
- Consumes: `QuestionBlock`, `PlanBlock` (Task 2), and `Workspace.answerQuestion` and `answerPlan` (Task 3).
- Produces:
  - **QuestionCard**:
    - Per question: a header chip, the question text, and one row per option (label plus description). Single-select is radio-like; multi-select toggles.
    - An "Other" row with a `TextField` (id `q-other-<requestID>-<i>`). Typing in it selects it.
    - "Submit" (id `q-submit-<requestID>`) is enabled when every question has an answer. It sends the answers through `answerQuestion`: multi-select labels joined with `", "` in option order; "Other" text sent as the value.
    - Answered: the chosen answers show read-only.
    - Option ids: `q-opt-<requestID>-<qi>-<oi>`.
  - **PlanCard**:
    - The plan rendered as markdown (Task 9's `MarkdownText`; until Task 9 lands, plain `Text`).
    - Buttons:
      - "Approve" (`plan-approve-<id>`) sets the mode to `.default_`.
      - "Approve, accept edits" (`plan-approve-edits-<id>`) sets it to `.acceptEdits`.
      - "Send back" (`plan-sendback-<id>`) reveals a feedback `TextEditor` (`plan-feedback-<id>`) and a "Send" button (`plan-send-<id>`) that calls `answerPlan(approve:false, feedback:)`.
    - A sent-back card shows "Sent back: <feedback>".

- [ ] **Step 1: Write the failing tests**, headless, with `ask-question.jsonl` and `plan-*.jsonl` emitted through `ScriptedTransport`.
  - `submitDisabledUntilAnswered`
  - `multiSelectJoinsInOptionOrder`: click options 2 then 0, submit. The sent answers value is `"opt0, opt2"`.
  - `otherTextIsSent`
  - `approveWithEditsSendsAcceptEdits`
  - `sendBackSendsFeedback`
  - `secondPlanCardAfterRevision`
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(ui): AskUserQuestion and plan approval cards`.

### Task 9: Block markdown replies (MetalUI G2)

**Gate:** MetalUI's G2 views (`MarkdownView`, `MarkdownBlockView`, `MarkdownTheme`) must be on `../MetalUI` master. If they are not when this task comes up, run Tasks 10–13 first. If G2 is still unmerged after Task 13, keep Plan 1's `Text(LocalizedStringKey)` stopgap and record the ruling in the ledger. Status 2026-11-07: G2 is complete on MetalUI master dc20b918 (#228 parser product, #232 views), so the gate is open. `MarkdownCodeHighlighter` is not main-actor and runs only when a fence changes. Known cost: while a reply streams, its other rich paragraphs re-measure per token (~3.8 ms/token on a 4 KB paragraph, release). That cost doesn't grow with transcript length; MetalUI is tracking a fix. Defaults: code fences wrap, tables don't scroll sideways. The nested-wheel fix is merged (MetalUI 7523f587): a vertical wheel over a horizontal scroller now reaches the transcript. So `alloyMarkdownTheme` sets `codeWraps: false` and `tableScrolls: true`, and Step 1 adds a `wheelOverCodeScrollsTranscript` test: a vertical wheel over a wide fence moves the transcript's scroll offset.

**Files:**
- Modify: `Package.swift` (AlloyKit depends on the `MetalUIMarkdown` product, if it is separate from `MetalUI`)
- Create: `Sources/AlloyKit/MarkdownText.swift`
- Modify: `ChatBlockViews.swift` (`AssistantText`, `PlanCard`, `.commandOutput` notices)
- Test: `Tests/AlloyKitTests/MarkdownChatTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor final class MarkdownCache`, owned by `TranscriptView`. Its `func document(for blockID: String, text: String) -> MarkdownDocument` keeps one document per block. When `text` extends the cached text it `append`s only the new suffix; otherwise it re-parses.
  - `struct MarkdownText: Component`, initialised with `(blockID:, text:, cache:)`. It renders `MarkdownBlockView`s for each block inside the transcript's `LazyVStack` row and applies `.markdownTheme(alloyMarkdownTheme)`. Code blocks are wrapped with a "Copy" button (id `copy-code-<blockID>-<n>`) that writes the code to `Clipboard`.
  - `.codeHighlighter` is **not** set here; Plan 4 Task 1 supplies it.

- [ ] **Step 1: Write the failing tests.**
  - `streamingAppendsOnly`: append "Hello" then " **world**". The cache's document `version` increments, and the parse count from a test counter on `MarkdownCache` is 1.
  - `codeFenceHasCopy`: a reply with a fenced block shows `copy-code-…`. Clicking it puts the code on the test clipboard (`window.clipboardItems`).
  - `headingAndListRender`: the a11y labels contain the heading and list item texts.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Update `docs/metalui-gaps.md`:** G2 adopted. **Commit** with `feat(ui): block markdown replies with copyable code (G2)`.

### Task 10: Composer core: keys, busy sending, stop, mode and model

**Files:**
- Create: `Sources/AlloyKit/ComposerModel.swift`
- Modify: `Sources/AlloyKit/ComposerView.swift`
- Test: `Tests/AlloyKitTests/ComposerTests.swift`

**Interfaces:**
- Consumes: Task 3 API.
- Produces: `@MainActor @Observable final class ComposerModel`, initialised with `(workspace:, sessionID:)`, plus `ComposerView` around it.
  - Properties: `draft: String`, `attachments: [ImageAttachment]` (Task 11), `suggestions: SuggestionState?` (Task 12).
  - `func handleKey(_ press: KeyPress) -> KeyPress.Result`:
    - Return without modifiers: if the session is idle or dormant, send with no priority. If it is working or awaiting permission, send with `.next`. That steers the running turn, as the CLI does.
    - ⌥Return: send with `.later`, a queued separate turn.
    - ⇧Return: insert a newline. Return `.ignored` so `TextEditor` does it.
    - Esc: interrupt when working; otherwise clear the suggestions.
    - ⇧Tab: cycle the mode default → acceptEdits → plan → default, as the CLI does.
  - `func send(priority: Priority?)`: trims the draft. An empty draft with no attachments does nothing. It clears the draft and attachments.
  - A composer toolbar row above the editor holds:
    - a mode `Picker` (id `mode-picker`) over `PermissionMode.allCases`
    - a model `Menu` (id `model-menu`) with Sonnet, Opus and Haiku (aliases `sonnet`, `opus`, `haiku`) plus the current model name; it opens when `Session.requestModelPicker` flips
    - a "Stop" button (id `stop`) shown while working
    - the queued count chip (id `queued-count`) when `Session.queued` is non-empty
  - The Send button stays, with id `send`. Plan 1's ⌘Return keeps working.

- [ ] **Step 1: Write the failing tests.** Drive `ComposerModel.handleKey` directly and `ComposerView` headless.
  - `returnSendsWhenIdle`
  - `returnSteersWhenBusy` (priority `next`)
  - `optionReturnQueues` (`later`, the chip shows 1, then disappears after the echo)
  - `shiftReturnNewline`
  - `shiftTabCyclesMode`
  - `stopVisibleOnlyWhenWorking`
  - `modelMenuSetsModel`
  - `slashModelOpensMenu`
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the full suite.** Expected: all pass. Plan 1's `ChatTests` still pass.
- [ ] **Step 4: Commit** with `feat(ui): composer keys, steer and queue, stop, mode and model controls`.

### Task 11: Image attachments: paste and drop

**Files:**
- Create: `Sources/AlloyCore/Chat/ImageEncoding.swift` (ImageIO and CoreGraphics; macOS)
- Modify: `ComposerModel.swift`, `ComposerView.swift`
- Test: `Tests/AlloyCoreTests/ImageEncodingTests.swift`, `Tests/AlloyKitTests/AttachmentTests.swift`

**Interfaces:**
- Produces:
  - `public enum ImageEncoding`:
    - `static func attachment(from data: Data, typeHint: String?) throws(ImageError) -> ImageAttachment`. PNG, JPEG, GIF and WebP pass through. TIFF, HEIC and anything else ImageIO decodes is re-encoded as PNG.
    - The result is refused with `.tooLarge(bytes:)` when the base64-decoded byte count is over 5 MB, and with `.unreadable` when ImageIO can't decode it.
  - Composer behaviour:
    - Paste (⌘V while the composer is focused): if `Clipboard.read(ImageData.self)` returns image data, add an attachment and don't paste text. `ImageData` carries `data` and `contentType` (`.png`, `.tiff`, `.jpeg`, parent `.image`; merged in MetalUI c6779ba4). No conversion happens, so TIFF→PNG stays Alloy's job.
    - Drop onto the composer (`dropDestination(for: ImageData.self)` plus `URL`): image data becomes an attachment; a dropped image *file* arrives as a `.fileURL` `URL`, so check its extension and load it as an attachment. Other files inside the project insert `@<relative path> ` at the caret. Files outside the project insert their absolute path.
    - Chips above the editor show the size and an "×" (id `attachment-remove-<id>`).
    - Errors show inline under the composer (id `composer-error`) for 5 s.

- [ ] **Step 1: Write the failing tests.**
  - `tiffBecomesPNG`: a TIFF generated with CGImage in the test gives `mediaType == "image/png"`.
  - `pngPassesThrough`
  - `oversizeRefused`: random-noise 3000×3000 PNG data gives `.tooLarge`.
  - `garbageRefused`
  - `pasteImageAddsChip`: use `window.setClipboard` with PNG data.
  - `dropImageFileAddsChip`, `dropSourceFileInsertsMention`: use `window.drop` with a file URL in the rig's root.
  - `sendCarriesImage`: the transport's last `.user` content has an `.image` block.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(ui): image paste and drop, file-drop mentions`.

### Task 12: Autocomplete for slash commands and `@file`

**Files:**
- Create: `Sources/AlloyCore/Model/FileIndex.swift`, `Sources/AlloyCore/Model/FuzzyMatch.swift`, `Sources/AlloyKit/SuggestionList.swift`
- Modify: `ComposerModel.swift`, `ComposerView.swift`, `docs/metalui-gaps.md`
- Test: `Tests/AlloyCoreTests/FileIndexTests.swift`, `FuzzyMatchTests.swift`, `Tests/AlloyKitTests/AutocompleteTests.swift`

**Interfaces:**
- Produces:
  - `public actor FileIndex`. Plan 4's ⌘P reuses it.
    - `init(root: URL)` and `func refresh() async`. In a git repo it runs `git -C root ls-files --cached --others --exclude-standard -z`. Otherwise it walks the directory, skipping `.git`, `.build`, `node_modules`, `.swiftpm` and `DerivedData`.
    - It caps at 100 000 paths.
    - `func paths() -> [String]` (relative).
  - `public enum FuzzyMatch { static func score(_ query: String, _ candidate: String) -> Int? }`. It is a case-insensitive subsequence match: nil means no match. The score favours contiguous runs, matches right after `/`, `_`, `-` or `.`, and matches in the file name over the directory. `static func top(_ query:, in candidates:, limit: Int = 50) -> [String]` returns the best first; equal scores sort the shorter path first.
  - `struct SuggestionState { kind: .slash | .file; query: String; items: [Suggestion]; selected: Int; tokenRange: Range<String.Index> }` and `Suggestion { id: String; title: String; detail: String? }`.
    - Opens on `/` at the draft's start, with the slash commands as items (title `/name`, detail = description + argumentHint).
    - Opens on `@` after whitespace or at the start, with files as items.
    - ↑ and ↓ move the selection.
    - Return or Tab accepts: it replaces the token with `/name ` or `@path `.
    - Esc closes it.
    - Typing re-filters, with at most 50 items.
  - View: MetalUI's `.suggestionOverlay(isPresented:edge:alignment:spacing:) { list }` on the composer (merged c6779ba4). The field keeps focus, and its `.onKeyPress` sees ↑/↓/Return/Tab/Esc, so ComposerModel routes them. The overlay has no chrome (draw the background), caps its height so wrap the list in a `ScrollView`, and is dismissed only by setting `isPresented` false. Ids: list `suggestions`, rows `suggestion-<i>`.

- [ ] **Step 1: Write the failing tests.**
  - `fuzzyPrefersFileName`: query `wsv` gives `Sources/AlloyCore/Model/Workspace.swift` before `docs/ws/v.md`.
  - `fuzzyNoMatchNil`
  - `gitIndexHonoursIgnore`: a temp git repo with `.gitignore` containing `build/` excludes it.
  - `nonGitWalkSkipsBuild`
  - `slashOpensAndAccepts`: type `/com` and ↓/Return give the draft `"/compact "`.
  - `atOpensFiles`: type `look at @wor` and Tab give `"look at @Sources/…/Workspace.swift "`.
  - `escCloses`
  - `terminalOnlyHidden`: `/doctor` never appears.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(ui): slash and @file autocomplete with fuzzy matching`.

### Task 13: Sidebar details, rename, settings

**Files:**
- Modify: `Sources/AlloyKit/SidebarView.swift`, `Sources/AlloyCore/Model/Workspace.swift`, `Sources/AlloyCore/Model/AlloySettings.swift`
- Create: `Sources/AlloyKit/SettingsPopover.swift`
- Test: `Tests/AlloyKitTests/SidebarTests.swift`, `Tests/AlloyCoreTests/WorkspaceTests.swift`

**Interfaces:**
- Produces:
  - `SessionRow` shows the name, a status word, `$cost`, tokens as `12.3k tok`, and the model short name plus a mode badge when the mode isn't default.
  - Double-click on the name shows a `TextField` (id `rename-<uuid>`). Return commits through `workspace.rename`; Esc cancels.
  - A gear button (id `settings`) at the sidebar bottom opens a popover with:
    - a `TextField` for the `claude` path (id `settings-claude-path`), with a placeholder showing the auto-detected path
    - "Detect" (id `settings-detect`), which clears the override
    - "Save" (id `settings-save`)
  - `Workspace.updateSettings(_ s: AlloySettings) throws` saves to disk and applies to new launches. Running sessions are untouched.

- [ ] **Step 1: Write the failing tests.**
  - `rowShowsTokensAndMode`
  - `renamePersists` (the restore shows the new name)
  - `settingsSaveAppliesToNextLaunch`: the rig's `locate` closure records the override string it receives.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the full suite.** Expected: all pass.
- [ ] **Step 4: Commit** with `feat(ui): session details, rename, claude path settings`.

### Task 14: Live check and docs

- [ ] **Step 1: Build.** Run `swift build -c release`. Expected: no warnings. Run `swift test`. Expected: all pass.
- [ ] **Step 2: Update the docs.** In `docs/metalui-gaps.md`, mark G2, G3 and G6 as adopted, with stopgaps noted. Mark the README feature list.
- [ ] **Step 3: Live smoke run, by the user** (controller prepares, user drives; scratch repo only). Checklist:
  - colors and icons per block
  - thinking collapses
  - `/cost` shows as command output
  - a question card round-trip
  - plan mode: approve, then send back
  - a pasted screenshot is understood
  - `@file` autocomplete
  - steer and queue while busy
  - stop
  - model and mode switches
  - quit and relaunch, then the history reappears

  Record the outcome in the ledger.
- [ ] **Step 4: Benchmark checkpoint.** Run `alloy-bench --apps alloy --metrics startup,memoryIdle,idleCPU` and compare with the first live run. Stop if Alloy regresses by more than 20%.
- [ ] **Step 5: Commit** with `docs: Plan 3 gaps and feature status`.
