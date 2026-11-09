# Alloy Plan 5a: Shared Knowledge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sessions stop re-reading files the group already knows. The plan adds three things:
- a fork that starts a session from another's conversation;
- an "already read" note added to outgoing messages;
- shared-notes tools served by Alloy, which also guides every session to check them before reading.

Alongside these, the plan adds a Settings view and a counter of reads the notes could have answered.

**Architecture:**
- **Local server.** A hand-rolled HTTP/1.1 server on `NWListener` (127.0.0.1 only, bearer token) serves the MCP streamable-HTTP JSON-RPC methods and nothing else. Plan 5b adds the hook endpoint to the same server.
- **Read index and notes store.** A read index records every Read a session makes, with the file's `FileStamp` at that moment. A notes store holds session-written summaries tied to the same stamps.
- **Launch-time wiring.** All per-session wiring is passed at launch: `--mcp-config`, `--allowedTools`, `--append-system-prompt` with `--system-prompt-snapshot off`, and `--fork-session`. Nothing is written to the user's Claude settings.

**Tech Stack:** Swift 6 (swift-tools 6.1, strict concurrency), macOS 14, Network.framework, MetalUI (../MetalUI), Swift Testing.

**Spec:**
- `docs/superpowers/specs/2026-11-09-alloy-shared-knowledge-design.md`, the binding spec for this plan.
- `docs/superpowers/specs/2026-11-07-alloy-design.md` §5, §6.3 and §6.5.

**Research the plan relies on** (read-only, in `.superpowers/sdd/plan-5-research/`):
- `cli-probes.md`: live CLI facts. Captures are in `captures/`.
- `mcp-http.md`: the MCP transport and auth.
- `alloy-interfaces.md`: exact Alloy names and file:line references.

Every task names the facts it consumes, so implementers need only the files named in their task.

## Global Constraints

- Alloy uses MetalUI only for UI. Log MetalUI gaps in `docs/metalui-gaps.md` and forward them to the MetalUI session. Stopgaps stay minimal.
- Never write to `~/.claude` or the project's `.claude/`.
- Never pass `--bare`, `--permission-mode` or `--setting-sources`.
- Never send `updatedPermissions` whose destination is `localSettings`, `projectSettings` or `userSettings`. Echoing the CLI's `addRules` suggestion would write `.claude/settings.local.json`.
- Alloy is never branded or named "Claude Code". UI and guidance text say "Claude".
- Every new interactive view gets an `.accessibilityIdentifier`. Keep every existing identifier.
- Colors are `ThemeColorKey` tokens in `Sources/AlloyKit/Theme.swift`, never inline hex in views.
- Fixtures are real CLI stdout, scrubbed with `tools/ccprobe/scrub.py`. Never hand-write a fixture line the CLI has not produced.
- Tests use Swift Testing. Read the printed counts. The release build (`swift build -c release`) and the test output have zero warnings.
- Any async side effect goes through `Workspace.track` or is awaited by `settle()`. Disk I/O and whole-file work stay off the main actor.
- Kill only processes you started. Never use a broad `pkill`.
- **Permission exception (user decision):** the three notes tools are passed in `--allowedTools` unless the setting "Ask before sessions use shared notes" is on. No other tool is pre-approved.
- **Commit trailer:**
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```
  A Co-Authored-By naming the implementing model is accepted.

**Constants** (exact values; later tasks use them by these names):

| Name | Value |
|---|---|
| MCP server name in `--mcp-config` | `alloy` |
| Tool names | `notes_lookup`, `notes_read`, `notes_write` (wire names `mcp__alloy__notes_lookup` etc.) |
| `ReadIndex.servableLimit` | 1_048_576 bytes |
| `NotesStore.noteLimit` | 2_000 characters |
| `NotesStore.staleExpiry` | 7 days |
| `AlreadyRead.maxFiles` | 8 |
| `AlreadyRead.maxCharacters` | 2_000 |
| Supported MCP protocol versions | `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05` |
| Default protocol version when the client sends none | `2025-03-26` |

## Review Focus

1. **A file changed between a session's Read and another session's `notes_read`.** `notes_read` refuses and says "read it fresh". It never serves bytes whose stamp differs from the recorded one. (Task 4 test `notesReadRefusesAChangedFile`)
2. **Paths that escape the project.** Absolute paths outside the root, `..`, and symlinks that point outside are refused by every notes tool. (Task 4 test `notesToolsRefuseOutsidePaths`)
3. **Truncated or partial reads.** A Read cut short by the CLI's token cap, or one with offset and limit, indexes only the lines actually returned. `notes_read` serves only those lines. (Task 3 test `truncatedReadIndexesOnlyReturnedLines`)
4. **Another local process calling the server.** A request without the token gets 401. A bad `Origin` or `Host` gets 403. The server is unreachable on non-loopback interfaces. (Task 2 test `serverRejectsUnauthenticatedAndForeignOrigin`)
5. **A setting change while a session is mid-turn.** The relaunch waits for idle. A turn is never cut off, and queued messages survive the relaunch. (Task 7 test `settingChangeAppliesAtIdleNotMidTurn`)

---

### Task 1: Launch options, decoder fields and fixtures

**Files:**
- Modify: `Sources/AlloyCore/Process/LaunchConfiguration.swift`, `Sources/AlloyCore/Wire/InboundMessage.swift`, `Sources/AlloyCore/Model/Workspace.swift` (`FileStamp` gains `Codable`)
- Create fixtures: `Tests/AlloyCoreTests/Fixtures/fork-init.jsonl`, `subagent-read.jsonl`, `read-truncated.jsonl` and `mcp-tool-call.jsonl`. Scrub each one from the captures `L2fork.jsonl`, `L40sub.jsonl`, `L32trunc.jsonl` and `L12mcp.jsonl` in `.superpowers/sdd/plan-5-research/captures/`, rewriting the project path to `/tmp/alloy-fixture` as the existing fixtures do.
- Test: `Tests/AlloyCoreTests/ClaudeProcessTests.swift`, `Tests/AlloyCoreTests/InboundDecoderTests.swift` (or the existing decoder test file)

**Interfaces:**
- Produces:
  - `LaunchConfiguration` gains `appendSystemPrompt: String?`, `allowedTools: [String]` (default `[]`) and `forkSession: Bool` (default false). `arguments()` appends the following, in this order:
    - `--fork-session` when `forkSession`; this requires `resume`;
    - `--append-system-prompt <text>` followed by `--system-prompt-snapshot off` when `appendSystemPrompt` is set;
    - `--allowedTools <comma-joined>` when the list is non-empty.
  - `ContentBlock.toolUse` and `ToolResultMessage` gain `parentToolUseID: String?`, decoded from the line's `parent_tool_use_id`.
  - `ReadResult` is a new struct: `filePath: String`, `startLine: Int`, `numLines: Int`, `totalLines: Int`, `truncated: Bool` (from `truncatedByTokenCap`). It is decoded from `tool_use_result.file` and exposed as `ToolResultMessage.read: ReadResult?`.
  - `FileStamp: Codable`.

- [ ] **Step 1: Write failing tests.**
  - `launchArgumentsCarryForkPromptAndAllowedTools`: the arguments contain `["--resume", src, "--fork-session"]`, `["--append-system-prompt", "G", "--system-prompt-snapshot", "off"]` and `["--allowedTools", "mcp__alloy__notes_lookup,mcp__alloy__notes_read,mcp__alloy__notes_write"]`. They contain no `--permission-mode` and no `--setting-sources`.
  - `subagentReadCarriesParent`: in `subagent-read.jsonl`, the Read `tool_use` and its result decode with a non-nil `parentToolUseID` equal to the Agent tool_use id.
  - `readResultDecodes`: `read-truncated.jsonl` decodes `truncated == true` with `numLines < totalLines`. The edit-turn Read decodes `startLine == 1` with `truncated == false`.
  - `mcpToolResultContentIsAnArray`: the result in `mcp-tool-call.jsonl` decodes with the text of its single text block.
  - `fileStampRoundTrips`
- [ ] **Step 2: Run** `swift test --filter "ClaudeProcessTests|InboundDecoder"`. Expected: FAIL to compile.
- [ ] **Step 3: Implement.** Make sure `FixturePrivacyTests` passes for the new fixtures.
- [ ] **Step 4: Run the full** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** with `feat(core): fork, guidance and allowed-tools launch options; parent and Read-result decoding`.

### Task 2: Local MCP server

**Files:**
- Create: `Sources/AlloyCore/Coordination/LocalServer.swift` (the HTTP/1.1 listener), `Sources/AlloyCore/Coordination/MCPServer.swift` (JSON-RPC handling and the tool registry)
- Test: `Tests/AlloyCoreTests/MCPServerTests.swift`. It uses real loopback requests through `URLSession`.

**Interfaces:**
- Consumes: `JSONValue` (Wire/JSONValue.swift).
- Produces:
  - `public protocol MCPTool: Sendable`, with:
    - `name: String`
    - `description: String`
    - `inputSchema: JSONValue`, which must be `type: "object"`
    - `func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult`
  - `public struct MCPCaller: Sendable { sessionID: UUID }`
  - `public struct MCPToolResult: Sendable { text: String; isError: Bool }`
  - `public actor LocalServer`:
    - `init(tools: [MCPTool])`
    - `func start() async throws -> URL`, returning `http://127.0.0.1:<port>/mcp`
    - `func stop()`
    - `func token(for session: UUID) -> String`, which gives a random 32-byte, hex, per-session token
    - `func revoke(session: UUID)`
  - `MCPServer.config(url:token:) -> String`, which returns the `--mcp-config` JSON:
    `{"mcpServers":{"alloy":{"type":"http","url":"…","headers":{"Authorization":"Bearer <token>"}}}}`
- Behaviour (from `mcp-http.md` and `cli-probes.md` §4):
  - **Listener:** bind `127.0.0.1` only, on an ephemeral port.
  - **Request size:** read the request by `Content-Length`. Reject chunked bodies with 411. Cap bodies at 4 MB (413).
  - **Auth:**
    - Compare the token in constant time. A missing or bad token gets 401.
    - A request with an `Origin` that is not loopback gets 403.
    - `Host` must be `127.0.0.1:<port>` or `localhost:<port>`; otherwise 403.
    - The token maps to `MCPCaller.sessionID`.
  - **Methods:**
    - POST `/mcp` carries one JSON-RPC message.
    - `initialize`: echo the client's `protocolVersion` if it is supported, otherwise return `2025-11-25`. Return `capabilities: {tools: {}}`.
    - `notifications/*` gets 202 with an empty body.
    - `ping` returns `{}`.
    - `tools/list`
    - `tools/call` returns `{content:[{type:"text",text}], isError}`.
    - An unknown method, including `server/discover`, gets JSON-RPC error -32601. An unknown tool gets -32602.
    - GET `/mcp` and DELETE `/mcp` get 405.
  - Responses are `application/json`, with no SSE and no session id.
  - A missing `mcp-protocol-version` header is treated as `2025-03-26`. An unsupported one gets 400.

- [ ] **Step 1: Write failing tests.**
  - `initializeEchoesSupportedVersion`
  - `toolsListAndCallRoundTrip`: uses an echo test tool and checks that the caller's session is passed through.
  - `notificationsGet202`
  - `unknownMethodIsMethodNotFound`
  - `serverRejectsUnauthenticatedAndForeignOrigin`: covers 401 with no token, 403 for `Origin: https://evil.example`, and 403 for `Host: example.com`.
  - `bodyOverCapIs413`
  - `revokedTokenIs401`
  - `listensOnLoopbackOnly`: the listener's endpoint host is `127.0.0.1`.
- [ ] **Step 2: Run** `swift test --filter MCPServerTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Use `NWListener` with `requiredLocalEndpoint` on 127.0.0.1. Give each connection its own buffer and handle keep-alive. Close the connection after a malformed request.
- [ ] **Step 4: Run** the focused tests 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5: Commit** with `feat(core): loopback MCP server with per-session tokens`.

### Task 3: Read index and redundant-read detection

**Files:**
- Create: `Sources/AlloyCore/Knowledge/ReadIndex.swift`
- Modify: `Workspace.swift`, at the `handle(_:session:)` hook point (alloy-interfaces.md §3) and in persistence beside `persistLedger`
- Test: `Tests/AlloyCoreTests/ReadIndexTests.swift`

**Interfaces:**
- Consumes: `ReadResult`, `parentToolUseID` and `FileStamp` from Task 1, plus `FileStamp.read(_:)`.
- Produces:
  - `public struct ReadEntry: Codable, Sendable, Equatable`:
    - `session: UUID`
    - `path: String` (project-relative)
    - `lines: ClosedRange<Int>?` (nil means the whole file)
    - `stamp: FileStamp`
    - `date: Date`
    - `generation: Int`, the session's compaction generation at read time
  - `public struct ReadIndex: Codable, Sendable`, with:
    - `mutating func record(_ entry: ReadEntry)`
    - `func current(path: String, stamp: FileStamp) -> [ReadEntry]`: entries whose stamp equals `stamp`
    - `func readers(path: String) -> [ReadEntry]`
    - `mutating func copy(from source: UUID, to fork: UUID)`
  - On `Workspace`:
    - `public internal(set) var readIndex: ReadIndex`
    - `compactionGeneration: [UUID: Int]`, bumped on `.compactBoundary` and `.conversationReset`
    - `Session.redundantReads: Int` and `Workspace.redundantReads: Int`, both `public internal(set)`
  - Persistence: `<storeDirectory>/reads.json`, written off main and chained like `persistLedger`, and awaited by `settle()`.
- Rules (spec §6.3 and §6.5):
  - **When an entry is recorded.** Record on a successful Read `tool_result`:
    - The entry carries the result's own `startLine…startLine+numLines-1`, whether the read was an offset/limit read or `truncated`. A full read has `lines` = nil.
    - The stamp is read off main right after the result.
    - Reads whose `parentToolUseID` is non-nil (subagent reads) count as the session's.
    - Paths outside the root are ignored, as is anything that isn't a text read.
  - **When a read counts as redundant.** A read is redundant when, at the moment its `tool_use` arrives, its path has a `current` entry or a current note (Task 4), and both of these hold:
    - the entry is from another session, or
    - it is from the same session with the same `generation`.

    A read from the same session after a compaction or reset doesn't count.

- [ ] **Step 1: Write failing tests.** Build each test from fixtures plus scripted events, following the Harness pattern in WorkspaceTests.
  - `readIsIndexedWithStamp`
  - `truncatedReadIndexesOnlyReturnedLines`
  - `subagentReadCountsForTheSession`
  - `rereadOfUnchangedFileIsRedundant`
  - `rereadAfterCompactionIsNot`: uses the compact.jsonl boundary.
  - `rereadAfterTheFileChangedIsNot`
  - `otherSessionsReadMakesItRedundant`
  - `outsideRootIgnored`
  - `indexSurvivesRestart`
- [ ] **Step 2: Run** `swift test --filter ReadIndexTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the focused tests 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5: Commit** with `feat(core): read index and redundant-read counting`.

### Task 4: Notes store and the three notes tools

**Files:**
- Create: `Sources/AlloyCore/Knowledge/NotesStore.swift`, `Sources/AlloyCore/Knowledge/NotesTools.swift`
- Modify: `Workspace.swift`:
  - start the `LocalServer` when the workspace loads, and stop it in `stopAll`;
  - mint a token per session at launch, and revoke it on stop;
  - mark notes stale from the change signals in alloy-interfaces.md §4: watcher, `appendToLedger`, session edits and saves.
- Test: `Tests/AlloyCoreTests/NotesToolsTests.swift`

**Interfaces:**
- Consumes: `LocalServer`, `MCPTool` (Task 2), `ReadIndex` (Task 3).
- Produces:
  - `public struct Note: Codable, Sendable, Equatable`:
    - `id: UUID`
    - `author: UUID`
    - `subject: NoteSubject`, which is `.file(String)` or `.topic(String)`
    - `text: String`, capped at `noteLimit`
    - `stamp: FileStamp?`, required for `.file`
    - `date: Date`
  - `NotesStore`, persisted at `<storeDirectory>/notes.json`:
    - `func notes(for subject: NoteSubject) -> [Note]`
    - `func isCurrent(_ note: Note, stamp: FileStamp?) -> Bool`
    - `mutating func add(_:)`
    - `mutating func expire(before: Date)`, which drops stale notes older than `staleExpiry`
  - The tool `inputSchema`s:
    - `notes_lookup {path?: string, topic?: string}`: exactly one of the two.
    - `notes_read {path: string, startLine?: integer, endLine?: integer}`
    - `notes_write {path?: string, topic?: string, text: string}`
  - `Workspace.notesTools: [MCPTool]` and `Workspace.notes: NotesStore`.
  - `Workspace.notesServed: Int` (`public internal(set)`). It counts each `notes_lookup` that finds at least one reader or note, and each `notes_read` that serves text. Task 8 displays it.
- Behaviour:
  - **`notes_lookup` text:**
    - who read the file and when;
    - whether its text can be served, meaning a `current` read-index entry exists for the stamp read off main now;
    - each note, labelled `[current]` or `[stale]`.
  - **`notes_read`:**
    - It reads the file fresh off main through `readForEditing`.
    - It serves text only if:
      - the stamp equals a recorded entry's stamp;
      - the file is at or under `servableLimit`;
      - it is not binary.
    - It serves only lines that a current entry covers. A whole-file entry covers every line.
    - Lines are returned as `N\ttext`, in the same style as Read.
    - Otherwise it returns `isError: false` with the text "<path> changed since it was read (or was never read by a session); read it with the Read tool."
  - **`notes_write`:**
    - The stamp is read off main.
    - Text over `noteLimit` is refused with an error that states the limit.
    - The note is attributed to the caller.
  - Every tool resolves `path` against the project root, refuses anything outside it after resolving symlinks, and accepts both absolute and relative paths.

- [ ] **Step 1: Write failing tests.** Call the tools directly and once more through `LocalServer`.
  - `lookupListsReadersAndNotes`
  - `notesReadServesCurrentLines`
  - `notesReadRefusesAChangedFile`
  - `notesReadServesOnlyReturnedLinesOfAPartialRead`
  - `notesReadRefusesBinaryAndHuge`
  - `notesToolsRefuseOutsidePaths`: covers `../x`, an absolute path outside the root, and a symlink pointing out.
  - `writeTiesNoteToStampAndCapsLength`
  - `fileChangeMarksNotesStale`
  - `staleNotesExpireAfterSevenDays`: uses the injected clock.
- [ ] **Step 2: Run** `swift test --filter NotesToolsTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the focused tests 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5: Commit** with `feat(core): shared notes store and MCP tools`.

### Task 5: Launch wiring, guidance and settings model

**Files:**
- Modify:
  - `Workspace.launch`, at the single `LaunchConfiguration` construction (alloy-interfaces.md §1.2);
  - `Sources/AlloyCore/Model/AlloySettings.swift`.
- Create: `Sources/AlloyCore/Knowledge/Guidance.swift`
- Test: `Tests/AlloyCoreTests/KnowledgeLaunchTests.swift`, using Harness `.configs`.

**Interfaces:**
- Consumes: Tasks 1, 2 and 4.
- Produces:
  - `AlloySettings` gains `shareKnowledge: Bool` (default true) and `askBeforeSharedNotes: Bool` (default false). Decoding goes through a custom `init(from:)` with `decodeIfPresent`, so old settings files still load.
  - `Guidance.text: String`, an exact copy of the following (it must not contain "Claude Code"):
    ```
    This project is shared with other sessions through Alloy. Before reading a file, call mcp__alloy__notes_lookup with its path. If the notes say its text can be served, call mcp__alloy__notes_read for just the lines you need instead of reading the file. After reading a file you will rely on, call mcp__alloy__notes_write with a one-to-three-sentence summary of what it does and anything surprising. Treat notes marked [stale] as hints only: the file changed after they were written. If the notes tools fail, read files normally.
    ```
  - Launch rules:
    - When `shareKnowledge` is on, every launch sets:
      - `mcpConfigJSON = MCPServer.config(url:token:)`
      - `appendSystemPrompt = Guidance.text`
      - `allowedTools = ["mcp__alloy__notes_lookup","mcp__alloy__notes_read","mcp__alloy__notes_write"]`, or `[]` when `askBeforeSharedNotes` is on.
    - When `shareKnowledge` is off, none of these is set.
    - `extraSettingsJSON` stays nil.

- [ ] **Step 1: Write failing tests.**
  - `launchPassesNotesServerGuidanceAndAllowRule`
  - `askSettingDropsTheAllowRule`
  - `shareKnowledgeOffPassesNothing`
  - `oldSettingsFileLoadsWithDefaults`
  - `guidanceNeverSaysClaudeCode`
  - `permissionSuggestionIsNeverEchoedToSettings`: a `can_use_tool` for a notes tool, sent while `askBeforeSharedNotes` is on, carries an `addRules … localSettings` suggestion (shape from cli-probes §3). Approving it sends `.allow` with no `updatedPermissions`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the focused tests 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5: Commit** with `feat(core): pass shared-notes server, guidance and allow rule at launch`.

### Task 6: "Already read" notes on outgoing messages

**Files:**
- Create: `Sources/AlloyCore/Knowledge/AlreadyRead.swift`
- Modify:
  - `Workspace.send`: build the wire content once, before the three queue branches (alloy-interfaces.md §2). The bubble keeps the typed text, and the uuid is unchanged.
  - `Sources/AlloyKit/ChatBlockViews.swift` (`UserBubble`).
- Test: `Tests/AlloyCoreTests/AlreadyReadTests.swift`, `Tests/AlloyKitTests/SharedChipTests.swift`

**Interfaces:**
- Consumes: `ReadIndex`, `NotesStore`, `FileStamp` and `Transcript`. To find files named in the message, parse `@path` / `@"path"` tokens with `ComposerModel`'s token rules, plus bare project-relative paths that exist.
- Produces:
  - `AlreadyRead.block(for session: UUID, message: String, recent: [String], index: ReadIndex, notes: NotesStore, stamps: [String: FileStamp?], told: inout [String: FileStamp]) -> (text: String, files: [SharedFile])?`:
    - This is pure, so the caller reads the stamps off main first.
    - `recent` is the paths the session read or edited, newest first, at most 20.
  - `SharedFile { path, reader: UUID, date, changed: Bool, summary: String? }`
  - Persistence:
    - `Workspace.told: [UUID: [String: FileStamp]]`, persisted at `<storeDirectory>/told.json` and copied on fork.
    - `Workspace.sharedFiles: [UUID /* user block id */: [SharedFile]]`, a side table kept so `ChatBlock.user` stays unchanged.
- Rules:
  - Include only files another session read.
  - Notify once per (session, path), and again only when the stamp or the newest current note changes.
  - Cap at `maxFiles` and `maxCharacters`.
  - The block is one line per file, in the spec's format:
    `<path> — read by "<name>" at <HH:mm>, unchanged since. Summary: <s>.`
    or
    `— … changed since (by you | by "<name>" | outside Alloy).`
  - Wrap the lines in a short header line: `Shared by other sessions (via Alloy):`.
  - It is sent as an extra leading text part of the user message.
  - Nothing is added when the master switch is off.
- UI:
  - `UserBubble` shows `Text("shared: N files")` with id `user-shared-<blockID>` in the `.secondary` ink.
  - Tapping it expands a detail block with id `user-shared-detail-<blockID>` that shows the exact lines added. The expand state lives in `SessionUIStore` overrides.

- [ ] **Step 1: Write failing tests.**
  - `notesOtherSessionsReadsOnly`
  - `toldOnceThenAgainAfterChange`
  - `capsAtEightFilesAndTwoThousandChars`
  - `mentionAndRecentFilesTrigger`
  - `bubbleKeepsTypedTextAndUUIDMatchesEcho`
  - `queuedAndLiveSendAgree`
  - `masterSwitchOffAddsNothing`
  - UI: `sharedChipExpandsToExactLines`
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the focused tests 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5: Commit** with `feat: tell sessions which files others already read`.

### Task 7: Fork, apply-at-idle relaunch, and the session menu

**Files:**
- Modify:
  - `Workspace.swift`: add `fork` and `relaunchWhenIdle`;
  - `Sources/AlloyCore/Chat/SlashCommands.swift` and `docs/slash-commands.md`;
  - `Sources/AlloyKit/SidebarView.swift` (`SessionRow` menu).
- Test: `Tests/AlloyCoreTests/ForkTests.swift`, `Tests/AlloyKitTests/SessionMenuTests.swift`

**Interfaces:**
- Consumes: `LaunchConfiguration.forkSession` (Task 1), `ReadIndex.copy` (Task 3), `told` (Task 6).
- Produces:
  - **`Workspace.fork(_ id: Session.ID, name: String?) async -> Session?`.** It returns nil, with a notice, when the source has no conversation.
    - The new session has a new `id`, the name `"<name> (fork)"` or the given name, and the next color.
    - It launches with `resume: true`, `resumeID: source.cliSessionID` and `forkSession: true`, and adopts the fork's `session_id` from `system/init`, as `cliSessionID` already does.
    - It copies the read index and `told` entries.
    - It starts idle and is persisted.
  - **Waiting for idle.** If the source is `.working` or `.awaitingPermission`, the fork waits until the source's next idle. It shows `NoticeKind.commandOutput` "Forking when idle…" in the source's chat.
  - **`/fork [name]`.** It is `SlashRoute.fork(name: String?)`, routed in `Workspace.send`. It is injected into `Session.slashCommands` so it appears in `/` autocomplete, with the description "Start a new session from this conversation".
  - **`Workspace.relaunchWhenIdle(_ id:)`.** When a session reaches idle, Alloy:
    - stops its process;
    - relaunches it with `resume: true` and the current settings;
    - keeps queued messages;
    - appends a notice "Settings applied".

    `updateSettings` calls it for every live session when `shareKnowledge` or `askBeforeSharedNotes` changes.
  - **The session menu in `SessionRow`.** A `Menu` with id `session-menu-<uuid>` holds:
    - Fork, id `fork-<uuid>`, disabled with the tooltip "Nothing to fork yet" when there is no conversation;
    - Rename, which reuses the existing `rename-<uuid>` flow.

- [ ] **Step 1: Write failing tests.**
  - `forkLaunchesWithResumeAndForkSession`: uses the `fork-init.jsonl` fixture and checks the new `cliSessionID` is adopted.
  - `forkCopiesReadsAndTold`
  - `forkOfFreshSessionIsRefused`
  - `forkWaitsForIdle`
  - `slashForkRoutesAndAppearsInSuggestions`
  - `settingChangeAppliesAtIdleNotMidTurn`: queued messages survive, and the relaunch carries the new launch options.
  - UI: `sessionMenuForksAndRenames`
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the focused tests 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5: Commit** with `feat: fork sessions, apply settings at idle, session menu`.

### Task 8: Settings view and the redundant-read display

**Files:**
- Create: `Sources/AlloyKit/SettingsView.swift`
- Modify:
  - `Sources/AlloyKit/SettingsPopover.swift`: remove the popover; the gear opens the view;
  - `RootView` (or AlloyScreen);
  - `SidebarView.swift`, for the row stat and footer line.
- Test: `Tests/AlloyKitTests/SettingsViewTests.swift`, `Tests/AlloyKitTests/SidebarTests.swift`

**Interfaces:**
- Consumes: the `AlloySettings` fields (Task 5) and the redundant-read counters (Task 3).
- Produces:
  - **The Settings view.** The gear (id `settings`) opens a full-panel Settings view over the chat column, with id `settings-view`. It closes with a close button (id `settings-close`) or Esc. It holds:
    - the Claude path field, with Detect and Save, keeping the ids `settings-claude-path`, `settings-detect`, `settings-save`, `settings-env-hint` and `settings-detected`;
    - the MetalUI `Toggle` "Share knowledge between sessions" (`settings-share-knowledge`);
    - the MetalUI `Toggle` "Ask before sessions use shared notes" (`settings-ask-shared-notes`).
  - Toggles save immediately through `updateSettings`. Errors appear inline in the view.
  - **Session row stat.** `SessionRow` shows `"\(n) re-reads"` (id `session-rereads-<uuid>`) beside the tokens, only when n > 0. Check it fits the 62 pt row.
  - **Footer line.** The sidebar footer shows `"Notes answered \(a) · \(b) reads skipped the notes"` (id `knowledge-stats`). `a` is the number of successful `notes_read` and `notes_lookup` calls, counted as `Workspace.notesServed`.
  - Neither number uses a warning style.

- [ ] **Step 1: Write failing tests.**
  - `gearOpensSettingsViewAndEscCloses`
  - `existingSettingsIdsStillWork`: adapt the old popover tests.
  - `togglesPersistAndRelaunchAtIdle`
  - `rereadStatShowsOnlyWhenNonZero`
  - `knowledgeStatsCount`
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the focused tests 3 times, then the full suite. Expected: all pass.
- [ ] **Step 5: Commit** with `feat(ui): Settings view and shared-knowledge stats`.

### Task 9: Live check, docs and docs-of-record

- [ ] **Step 1: Build and test.**
  - `swift build -c release`: expect 0 warnings.
  - `swift test`: all pass, with warning-free output.
  - `swift test --package-path Bench`: all pass.
- [ ] **Step 2: Live protocol check, scripted by the implementer.** Use the real CLI in a scratch repo under the scratchpad, never touching any app. Launch two sessions through Alloy's `ClaudeProcess` with Task 5's options, then confirm:
  - session A reads a file and writes a note;
  - session B's `notes_lookup` and `notes_read` return the note and the lines without a `can_use_tool` request;
  - a fork answers a question about the source conversation;
  - a compaction stops counting re-reads.

  Record the results in `docs/protocol-notes-plan5.md`.
- [ ] **Step 3: Docs.**
  - README feature list.
  - `docs/slash-commands.md` (`/fork`).
  - Add a "Plan 5a" section to `docs/metalui-gaps.md` if any gap was found.
  - In the roadmap, mark 5a done and 5b (Coordination) next.
- [ ] **Step 4: Commit** with `docs: Plan 5a status and protocol notes`.
- [ ] **Step 5: The user's hands-on check.** In Alloy:
  - two sessions, where the second session's message shows the "shared: N files" chip;
  - the notes tools run without permission cards;
  - fork from the menu and with `/fork`;
  - the Settings view toggles;
  - the re-read counts.
