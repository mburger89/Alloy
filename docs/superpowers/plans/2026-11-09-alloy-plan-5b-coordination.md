# Alloy Plan 5b: Coordination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sessions working on one folder stay out of each other's way. Before a session edits lines that another session changed or is about to change, Alloy tells it what changed, and it adjusts. Sessions can see each other's changes, message each other and claim a region. Alloy spots a tug-of-war, tells the latest editor to stop, and warns the user.

**Architecture:**
- **Hooks.** Alloy's existing loopback server (Plan 5a's `LocalServer`) gains two HTTP hook endpoints, PreToolUse and PostToolUse. They are wired per session through `--settings` hook JSON, authenticated with the session's token, and answer with `additionalContext` only, never a permission decision.
- **Overlap.** An overlap index in AlloyCore holds each session's live edits (from the ledger) and its proposed edits (tool calls issued but not yet applied). It answers "who else touched these lines" with a ±3-line margin.
- **Tools and messages.** Three coordination MCP tools join the notes tools. Cross-session messages go to the target's stdin as `priority: "next"` user messages.

**Tech Stack:** Swift 6 (strict concurrency), macOS 14, Network.framework (existing `LocalServer`), MetalUI, Swift Testing.

**Spec:**
- `docs/superpowers/specs/2026-11-07-alloy-design.md` §6.5 (Coordination: user decisions in bold, binding), §6.3, §5.
- `docs/superpowers/specs/2026-11-09-alloy-shared-knowledge-design.md` §5 (the permission exception) and §6.6 (settings).

**Research:**
- `.superpowers/sdd/plan-5-research/cli-probes.md` §5 (http hooks through `--settings`: body shape, `additionalContext` reaches the model, permissions unchanged, 10,000-character inline limit), §3 (`--allowedTools`), and `captures/hook-*.jsonl` for real hook bodies.
- `docs/protocol-notes-plan5.md` (5a live results).
- The 5a code itself, which is the interface of record.

## Global Constraints

- All of Plan 5a's global constraints apply. In particular:
  - never write `~/.claude` or `.claude/`;
  - never pass `--bare`, `--permission-mode` or `--setting-sources`;
  - never send `updatedPermissions` except `session` or `cliArg`;
  - never use the "Claude Code" branding;
  - accessibility ids on every interactive view;
  - theme tokens only, with the theme guard and contrast audit passing;
  - real, scrubbed fixtures;
  - zero warnings;
  - async work through `track`/`settle`;
  - disk and whole-file work off the main actor;
  - kill only processes you started.
- **Never block an edit** (user decision). Hooks return `additionalContext` only. They never return `permissionDecision`, `decision:"block"` or `updatedInput`.
- **Hook latency budget:** a hook reply within 50 ms p95 on the main path. A PreToolUse hook stalls the session's tool call, so the overlap check never does disk I/O or whole-file diffs on the hook path.
- **Hook failure is harmless:** a hook that errors or times out must leave the CLI running the tool normally. Configure `timeout` small (3 s) and never `onFailure:"block"`.
- **Messages are short and factual** (user decision): who, when, which lines, and a compact diff, capped at 4,000 characters per message. That is well under the 10,000-character inline limit.
- **Red is reserved** for things that truly need the user. Overlap and tug-of-war notices use the warning tokens.
- **Permission ruling (controller, extending the user's 5a decision):** the coordination tools act only on Alloy's own state. Like the notes tools, they are pre-approved through `--allowedTools`. The 5a setting "Ask before sessions use shared notes" is renamed **"Ask before sessions use Alloy's tools"** and covers notes and coordination tools alike. Each tool name is listed exactly; no wildcard.
- Commit trailer, as in Plan 5a.

**Constants**

| Name | Value |
|---|---|
| Hook paths | `POST /hooks/pre-tool-use`, `POST /hooks/post-tool-use` on the existing server |
| Hooked tools (matcher) | `Edit\|MultiEdit\|Write\|NotebookEdit` |
| Hook timeout passed to the CLI | 3 (seconds) |
| `Overlap.margin` | 3 lines |
| `Overlap.maxMessageCharacters` | 4,000 |
| Coordination tool names | `sessions_changes`, `send_message`, `claim_region`, `release_region` (wire names `mcp__alloy__…`) |
| `Messages.perPairPerMinute` | 5 |
| `Messages.perSessionPerMinute` | 10 |
| `Claims.expiry` | 10 minutes without an edit from the claimant |
| Tug-of-war | the same lines changed A → B → A within 10 minutes |

## Review Focus

1. **A session edits lines that another session is editing at the same instant.** The proposed change is visible to the other session's PreToolUse before either applies. Neither is blocked. Each gets told about the other at most once. (Task 3 test `simultaneousProposalsTellBothOnce`)
2. **A hook arrives for a session Alloy doesn't know, or with a revoked token.** 401, the CLI runs the tool normally, and nothing is recorded. (Task 1 test `hookWithRevokedTokenIs401AndHarmless`)
3. **Two sessions bounce messages back and forth.** Rate limits stop ping-pong. The sender gets a clear "rate limited" tool error, and the user sees nothing alarming. (Task 5 test `pingPongIsRateLimited`)
4. **A file edited by a session has unsaved user typing open in the editor.** Overlap with the user's own unsaved region is reported as "the user is editing lines a–b". The user is never treated as a session that can be told to stop. (Task 3 test `unsavedUserTypingCountsAsProposed`)
5. **A tug-of-war where the latest editor keeps going after the stop message.** The alert escalates to the user once. Alloy never pauses or blocks the session. (Task 6 test `ignoredStopEscalatesOnce`)

---

### Task 1: Hook endpoints and per-session hook settings

**Files:**
- Modify: `Sources/AlloyCore/Coordination/LocalServer.swift` (routes for the two hook paths, reusing auth and limits), `Sources/AlloyCore/Model/Workspace.swift` (launch passes `extraSettingsJSON`)
- Create: `Sources/AlloyCore/Coordination/Hooks.swift` (request and response types, settings JSON builder)
- Test: `Tests/AlloyCoreTests/HookServerTests.swift`, `KnowledgeLaunchTests` (extend)

**Interfaces:**
- **Consumes:** `LocalServer` (token auth, Origin/Host checks, connection caps, `ContinuousClock` deadlines) and `Workspace.mcpToken(for:)`.
- **Produces:**
  - `public struct HookRequest: Sendable`, decoded from the CLI body (shape from `captures/hook-a.jsonl`):
    - `event`: `.preToolUse` or `.postToolUse`
    - `toolName`, `toolUseID`, `toolInput: JSONValue`
    - `toolResponse: JSONValue?` (Post only)
    - `cliSessionID`
  - `public struct HookReply: Sendable`, which carries `additionalContext: String?` and nothing else. It encodes as `{"hookSpecificOutput":{"hookEventName":…,"additionalContext":…}}`, or `{}` when there is no context.
  - `LocalServer` gains `setHookHandler(_ handler: @Sendable (HookRequest, MCPCaller) async -> HookReply)`.
  - `Hooks.settingsJSON(url: URL, token: String) -> String`. This is the `--settings` value: a `hooks` object only, with no permissions. It contains PreToolUse and PostToolUse entries, each with matcher `Edit|MultiEdit|Write|NotebookEdit`, `type:"http"`, the URL, the header `Authorization: Bearer <token>`, and `timeout: 3`.
  - `Workspace.launch` sets `extraSettingsJSON` whenever sharing is on and the server is up, and only then.
- **Rules:**
  - The hook routes use the same token auth, so the token identifies the session.
  - A bad token gets 401.
  - A handler that throws or exceeds 1 s replies `{}`.
  - Hooks never return a permission decision.

- [ ] **Step 1:** Write failing tests:
  - `hookRoutesRoundTripWithToken`
  - `hookWithRevokedTokenIs401AndHarmless`
  - `replyNeverCarriesPermissionDecision`, which checks that the encoded JSON has no `permissionDecision`, `decision` or `updatedInput` key
  - `slowHandlerRepliesEmptyWithinBudget`
  - `launchPassesHookSettingsOnlyWithSharingOn`
  - `settingsJSONHasNoPermissionsKey`
- [ ] **Step 2:** Run `swift test --filter "HookServerTests|KnowledgeLaunchTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the focused suite 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5:** Commit `feat(core): PreToolUse/PostToolUse http hooks on the loopback server`.

### Task 2: Proposed changes and the overlap index

**Files:**
- Create: `Sources/AlloyCore/Coordination/OverlapIndex.swift`, `Sources/AlloyCore/Coordination/ProposedChange.swift`
- Test: `Tests/AlloyCoreTests/OverlapIndexTests.swift`

**Interfaces:**
- **Consumes:** `ProjectLedger`/`FileLedger` live edits (authors and line ranges via `lineOwners()` and the edit hunks), `NotePath`/`ProjectLedger.relativePath`, and documents with unsaved typing (`EditorDocument.isDirty`, plus the dirty range from the buffer's edit cursor since `savedVersion`).
- **Produces:**
  - `public struct LineRange: Hashable, Sendable { path: String; lines: ClosedRange<Int> }`.
  - `public struct ProposedChange: Sendable { session: UUID; toolUseID: String; range: LineRange; date: Date; diff: String }`.
  - `ProposedChange.from(toolName:input:currentText:) -> ProposedChange?` maps an Edit, MultiEdit, Write or NotebookEdit input to the lines it would change in the current text:
    - **Edit:** find `old_string`. With `replace_all`, include every match. If there is no match, return nil.
    - **Write:** the whole file, or the changed span against the current text.
  - `OverlapIndex` (an actor), with:
    - `propose(_:)`
    - `resolve(toolUseID:)`, called on PostToolUse or on tool_result
    - `overlaps(for session: UUID, range: LineRange) -> [Overlap]`
  - `Overlap { other: Author; kind: .active(editID) | .proposed(toolUseID) | .userTyping; lines; date; diff }`.
  - Overlap means the same or adjacent lines within `margin`.
  - Line numbers of active edits are re-anchored to current text using the ledger's existing anchors.
- **Rules:**
  - Unsaved user typing counts as a proposed change by `.user`.
  - A session's own edits never overlap with itself.
  - Kept or reverted edits don't count; only live ones do.

- [ ] **Step 1:** Write failing tests:
  - `editMapsToItsLines`
  - `replaceAllMapsEveryMatch`
  - `adjacentWithinThreeLinesOverlaps`
  - `fourLinesApartDoesNot`
  - `ownEditsNeverOverlap`
  - `keptEditsDoNotCount`
  - `unsavedUserTypingCountsAsProposed`
  - `resolveDropsTheProposal`
  - `activeEditReanchorsAfterEarlierLinesChange`
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. The hook path must stay in budget: the current text comes from the ledger and the open buffer in memory, never from disk on the hook path. If a file isn't in memory, skip proposals for it, which is safe because nothing is known to overlap.
- [ ] **Step 4:** Run the focused suite 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5:** Commit `feat(core): proposed changes and the line overlap index`.

### Task 3: Tell the editing session, once

**Files:**
- Create: `Sources/AlloyCore/Coordination/OverlapNotice.swift`
- Modify: `Workspace` (the hook handler, the told-once store `overlapTold.json`)
- Test: `Tests/AlloyCoreTests/OverlapNoticeTests.swift`

**Interfaces:**
- **Consumes:** Tasks 1 and 2, and session names and colours.
- **Produces:**
  - The hook handler for PreToolUse:
    1. Build the proposed change.
    2. Register it.
    3. Look up overlaps.
    4. Return `additionalContext` for those not yet told to this session.
  - On PostToolUse it resolves the proposal.
  - **Message text** (user decision example, exact shape):
    `"<other name>" changed <path> lines <a>–<b> <n> minutes ago:\n<compact diff>`
    - For proposed changes: `"<other name>" is about to change <path> lines <a>–<b>:\n<diff>`.
    - For the user: `The user is editing <path> lines <a>–<b> (unsaved).`
    - Join several overlaps with blank lines. Cap the total at `maxMessageCharacters` with `…and N more`.
  - **Told once:** keyed by (receiving session, other edit id or toolUseID). Persisted. A key counts as untold again after the receiving session's compaction generation changes, reusing 5a's generation.
  - **Chat:** the warning is also shown inline in the editing session's chat. It is a `.warning` notice with the same text.
- **Rules:**
  - Never block.
  - The hook replies within budget. The told-store write goes through the coalesced persist pattern.

- [ ] **Step 1:** Write failing tests:
  - `overlapProducesUserExampleMessage` (the exact format)
  - `toldOnceThenNotAgain`
  - `retoldAfterCompaction`
  - `simultaneousProposalsTellBothOnce`
  - `messageIsCappedUnderFourThousand`
  - `noOverlapRepliesEmpty`
  - `hookReplyIsNeverABlock`
  - `chatShowsTheWarningInline`
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the focused suite 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5:** Commit `feat(core): tell a session about overlapping changes once, never blocking`.

### Task 4: Coordination MCP tools

**Files:**
- Create: `Sources/AlloyCore/Coordination/CoordinationTools.swift`, `Sources/AlloyCore/Coordination/Claims.swift`
- Modify: `Guidance.swift` (append one short paragraph), the launch `allowedTools`, and `AlloySettings` (rename the ask setting's label only; keep the stored key `askBeforeSharedNotes` for compatibility)
- Test: `Tests/AlloyCoreTests/CoordinationToolsTests.swift`

**Interfaces:**
- **Consumes:** `MCPTool` and `MCPServer.checkedArguments` (unknown-argument rejection), the ledger, `OverlapIndex`, and session names.
- **Produces:**
  - **`sessions_changes {}`**: one line per other session with name, status, and its live changed files with line ranges and active claims. Capped.
  - **`send_message {to: string, text: string}`**:
    - `to` is a session name; match it case-insensitively. An unknown or ambiguous name is an error that lists the valid names.
    - `text` is capped at 2,000 characters.
    - The message is delivered as Task 5 describes.
  - **`claim_region {path, startLine, endLine, note?}`**:
    - Records a claim.
    - It is advisory and shows in other sessions' overlap messages ("<name> has claimed lines a–b: <note>").
    - It never blocks.
    - It expires per `Claims.expiry`.
  - **`release_region {path, startLine?, endLine?}`**
  - The guidance gains one paragraph: check `sessions_changes` before large edits, claim a region for multi-step work, release it after.
- **Rules:**
  - All four tools are listed in `allowedTools` next to the notes tools, unless "Ask before sessions use Alloy's tools" is on.
  - Claims and messages refuse paths outside the root, using the 5a path helper.

- [ ] **Step 1:** Write failing tests:
  - `sessionsChangesListsOthersOnly`
  - `sendMessageResolvesNamesCaseInsensitively`
  - `unknownRecipientListsValidNames`
  - `claimShowsInOverlapMessages`
  - `claimExpires`
  - `releaseRemoves`
  - `toolsAreAllowedListedExactly`
  - `askSettingDropsAllAlloyTools`
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the focused suite 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5:** Commit `feat(core): coordination tools: changes, messages, claims`.

### Task 5: Cross-session messages and rate limits

**Files:**
- Create: `Sources/AlloyCore/Coordination/Messages.swift`
- Modify: `Workspace` (delivery through the existing send path with `priority: .next`), chat views (the message bubble style)
- Test: `Tests/AlloyCoreTests/MessagesTests.swift`, `Tests/AlloyKitTests/SessionMessageViewTests.swift`

**Interfaces:**
- **Produces:**
  - `Workspace.deliverSessionMessage(from:to:text:) -> Result<Void, MessageError>`.
  - **The target receives** a user message with priority `.next` and the text `Message from "<sender>" (via Alloy): <text>`.
    - It goes through `send`, so 5a's queueing, dormant wake and told logic apply.
    - The "already read" block is not added to session messages.
  - **Both chats** show it as a distinct message row (id `session-message-<uuid>`):
    - "From <sender>" in the target's chat;
    - "To <target>" in the sender's chat.
    - Both use the sender's session colour and theme tokens.
  - **Rate limits:** `perPairPerMinute` and `perSessionPerMinute`, both on the injected clock. When over the limit, the tool returns isError "Message not sent: rate limited (…); try again in Ns".
  - **Loops:** a message is never delivered to its sender.
- [ ] **Step 1:** Write failing tests:
  - `messageArrivesWithNextPriority`
  - `bothChatsShowTheMessage`
  - `pingPongIsRateLimited`
  - `perSessionLimit`
  - `dormantTargetWakesAndReceives`
  - `noAlreadyReadBlockOnSessionMessages`
  - `cannotMessageSelf`
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the focused suite 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5:** Commit `feat: cross-session messages with rate limits`.

### Task 6: Tug-of-war detection

**Files:**
- Create: `Sources/AlloyCore/Coordination/TugOfWar.swift`
- Modify: `Workspace` (it observes ledger records)
- Test: `Tests/AlloyCoreTests/TugOfWarTests.swift`

**Interfaces:**
- **Consumes:** ledger records with authors and line ranges, overlap via `margin`, and `deliverSessionMessage` (bypassing the rate limit for this system message).
- **Produces:**
  - **Detection:** if the same lines change A → B → A within 10 minutes, Alloy sends the session that made the latest edit, as a `.next` user message, the user-decision text:
    `Lines <a>–<b> of <path> are going back and forth between you and "<other>". Leave them as they are now and move on with the rest of your task.`
  - **Alert:** at the same moment Alloy raises a user alert (Task 7 shows it).
  - **Escalation:** if that session edits those lines again after the stop message, the alert escalates once (`escalated: true`). There is no further messaging, and Alloy never pauses the session.
  - **User edits:** the user's own edits count as a party for detection, but Alloy never sends the user a message. When the user is the latest editor, it alerts only.
- [ ] **Step 1:** Write failing tests:
  - `abaWithinTenMinutesSendsStopToLatest`
  - `abaAfterTenMinutesDoesNot`
  - `ignoredStopEscalatesOnce`
  - `userAsLatestEditorOnlyAlerts`
  - `differentLinesAreNotATug`
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the focused suite 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5:** Commit `feat(core): tug-of-war detection and back-off message`.

### Task 7: User-facing warnings

**Files:**
- Modify: `SidebarView.swift` (⚠ markers on sessions and changed files), `ChatView`/`TranscriptView` (inline warnings, which exist from Task 3; add the tug alert), `RootView` (a small notice when the user is looking at another session)
- Test: `Tests/AlloyKitTests/CoordinationWarningsTests.swift`; ContrastAudit pairs

**Interfaces:**
- **Produces:**
  - **⚠ markers** (spec §6.5 item 8):
    - A ⚠ on the sessions involved (`session-warning-<uuid>`) and on the file in the changed-files list (`changed-file-warning-<path>`).
    - Hover help states the overlap or tug in one line.
  - **Notice:** a dismissible notice strip (`coordination-notice`) when an overlap or tug involves a session other than the selected one. Clicking it selects that session.
  - **Escalation:** an escalated tug uses the error tokens. That is the only red.
  - **Clearing:** markers clear when the overlap resolves (edits kept, reverted or committed) or after 10 minutes without new overlap.
- [ ] **Step 1:** Write failing tests:
  - `overlapMarksBothSessionsAndTheFile`
  - `noticeShowsForOtherSessionAndSelectsIt`
  - `escalationIsTheOnlyRed`
  - `markersClearOnKeep`
  - the contrast audit covering the new pairs
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the focused suite 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5:** Commit `feat(ui): coordination warnings in sidebar, chat and notices`.

### Task 8: Live check and docs

- [ ] **Step 1:** Run `swift build -c release` (0 warnings), `swift test` (all pass, warning-free) and the Bench tests.
- [ ] **Step 2:** Extend the opt-in `LiveKnowledgeTests` (or add `LiveCoordinationTests`, skipped unless `ALLOY_LIVE=1`), using haiku against a scratch repo. Check:
  - the hooks fire and session A's Edit of lines that B is changing gets `additionalContext`, and the transcript shows `hook_additional_context`;
  - the edit is not blocked;
  - `send_message` delivers to B with no permission card;
  - a scripted A→B→A tug sends the stop message.

  Record the results in `docs/protocol-notes-plan5.md`.
- [ ] **Step 3:** Docs:
  - README;
  - the settings label rename;
  - `docs/metalui-gaps.md` if any gap was found;
  - the roadmap: 5b done, pending the user's hands-on check.
- [ ] **Step 4:** Commit `docs: Plan 5b status and protocol notes`.
- [ ] **Step 5 (user hands-on):** two sessions asked to edit the same function:
  - the overlap warning appears in the chat and the sidebar;
  - neither edit is blocked;
  - `send_message` between sessions works;
  - a tug-of-war stop appears.
