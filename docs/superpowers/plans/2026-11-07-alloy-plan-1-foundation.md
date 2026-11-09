# Alloy Plan 1 — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A runnable Alloy that hosts several Claude Code sessions on one folder, shows each session's chat (text, tool calls, in-chat diffs, Approve/Deny cards), records every edit per session with line attribution, Keep and Revert, and shows a read-only file panel colored by author.

**Architecture:** Three SwiftPM targets. `AlloyCore` is pure logic with no MetalUI dependency: wire protocol, process transport, edit ledger, transcript reducer, and the `@Observable` workspace and session models. `AlloyKit` holds the MetalUI views. `Alloy` is the entry point. Each session is one `claude -p` stream-json subprocess. Every inbound line is decoded into `InboundMessage`, reduced into a `Transcript`, and edit results are fed into a per-file `FileLedger`.

**Tech Stack:** Swift 6 language mode, macOS 14+, MetalUI (path dependency), Swift Testing, MetalUITesting (headless UI tests), Foundation `Process`, and `CollectionDifference` for line diffs.

**Spec:** `docs/superpowers/specs/2026-11-07-alloy-design.md` (read §5, §6.1–6.4 and §6.7). Roadmap: `docs/superpowers/plans/2026-11-07-alloy-roadmap.md`.

## Global Constraints

- macOS 14 minimum; `swiftLanguageModes: [.v6]`. MetalUI is consumed as `.package(path: "../MetalUI")`, a relative path.
- Alloy runs the user's installed `claude` (2.1.319 verified) with the user's existing login. **Never write to `~/.claude` or the project's `.claude/`.** Never pass `--bare`. Never pass `--permission-mode` or `--setting-sources`: permissions follow the user's own Claude Code settings.
- The product name is "Alloy". UI copy says "Claude", never "Claude Code".
- Unit and UI tests never launch the real `claude`. Live tests are gated on `ALLOY_LIVE=1`.
- Tests never sleep. MetalUI tests drive the simulated clock; asynchronous work is awaited with `window.runUntil { … }` or `await` on the model.
- Every MetalUI gap found goes in `docs/metalui-gaps.md` (use case, stopgap, wanted API) and is sent to the MetalUI session. Stopgaps stay minimal and logged.
- Agents kill only processes they started (no `pkill` by name): MetalUI and other sessions share this Mac.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```

## Verified protocol facts (from the 2026-11-07 probe; local probe captures (not committed))

- `system/init` is re-emitted at the **start of every turn**. It carries `tools`, `slash_commands`, `model`, `permissionMode` and `session_id`.
- `stream_event.event` is a raw SSE event. Deltas are `text_delta`, `thinking_delta` (its text is `""` in this mode, carrying `estimated_tokens`), `input_json_delta` and `signature_delta`. `system/thinking_tokens` messages also arrive.
- `assistant` messages arrive **one per content block**, sharing `message.id`.
- A tool result is a `user` message. Its top-level `tool_use_result` is an object on success and a **plain string on failure**. Edit: `{filePath, oldString, newString, originalFile, structuredPatch:[{oldStart,oldLines,newStart,newLines,lines}], userModified, replaceAll}`. Write: `{type:"create"|"update", filePath, content, structuredPatch, originalFile}`. There is no `gitDiff`. It also carries `tool_result_meta`.
- Permission prompts reach the host only with **`--permission-prompt-tool stdio`**. The request is `{"type":"control_request","request_id":…,"request":{"subtype":"can_use_tool","tool_name","display_name","input","description","permission_suggestions","tool_use_id"}}`. Allow is `{"type":"control_response","response":{"subtype":"success","request_id":…,"response":{"behavior":"allow","updatedInput":{…}}}}`; deny uses `{"behavior":"deny","message":…}`. The CLI **echoes the host's own `control_response`**, so ignore it. A `control_cancel_request{request_id}` withdraws a pending request.
- Interrupt is `{"type":"control_request","request_id":…,"request":{"subtype":"interrupt"}}`. The turn ends with `result.subtype:"error_during_execution"` and `terminal_reason:"aborted_tools"`, and the process stays alive.
- `set_permission_mode {mode}` and `set_model {model}` control requests work.
- A user line sent mid-turn with `"priority":"next"` is consumed in the same turn. The replay echo has `isReplay:true`.
- `result` fields: `subtype`, `is_error`, `total_cost_usd`, `usage`, `session_id`, `terminal_reason`, `num_turns`.

## Review Focus

1. **`claude` missing, or the path is wrong.** The session shows a readable error naming the paths tried and the override setting. Nothing crashes. Pinned in Task 4.
2. **The `claude` process exits mid-session** (auth expired, crash, killed). The session status becomes `.exited` with the last stderr lines shown in the chat; other sessions are unaffected. Pinned in Task 5 and Task 9.
3. **Unknown or malformed stdout lines** (a newer CLI adds fields or types). They decode to `.unknown` and are skipped; nothing crashes and later lines still decode. Pinned in Task 3.
4. **An edit result whose `originalFile` does not match the ledger's current text**, because someone changed the file outside Alloy in between. The difference is recorded as an `.outside` edit first, then the session's edit, so line ownership stays right. Pinned in Task 7.
5. **Very large single stdout lines** (a Write of a multi-MB file) and files without a trailing newline or with CRLF endings. The line reader handles lines over 8 MB, and the ledger round-trips text byte-for-byte. Pinned in Tasks 5 and 6.

---

## File Structure

```
Alloy/
  Package.swift                          targets AlloyCore, AlloyKit, Alloy, AlloyTestSupport, tests
  Sources/AlloyCore/
    Wire/JSONValue.swift                 Codable JSON tree
    Wire/InboundMessage.swift            decoded CLI → host messages + InboundDecoder
    Wire/OutboundMessage.swift           host → CLI lines
    Process/LaunchConfiguration.swift    argv builder
    Process/ClaudeLocator.swift          find the claude binary
    Process/SessionTransport.swift       protocol + ProcessEvent
    Process/ClaudeProcess.swift          Process-backed transport, line reader
    Ledger/PatchHunk.swift               hunk type, apply, line diff
    Ledger/FileLedger.swift              per-file edit history, ownership, keep, revert
    Ledger/ProjectLedger.swift           all files + persistence
    Chat/ToolKind.swift                  tool → kind + one-line summary
    Chat/Transcript.swift                ChatBlock + reducer
    Model/Session.swift                  @Observable session
    Model/Workspace.swift                @Observable project: sessions + ledger
    Model/AlloySettings.swift            settings file
  Sources/AlloyTestSupport/ScriptedTransport.swift
  Sources/AlloyKit/
    Theme.swift  RootView.swift  SidebarView.swift  ChatView.swift  ChatBlockViews.swift  ComposerView.swift  FilePanelView.swift
  Sources/Alloy/main.swift
  Tests/AlloyCoreTests/…  Tests/AlloyCoreTests/Fixtures/*.jsonl
  Tests/AlloyKitTests/…
  tools/ccprobe/drive.py                 the protocol probe driver (kept for re-probing new CLI versions)
  docs/protocol-notes.md  docs/metalui-gaps.md
```

---

### Task 1: Scaffold the package

**Files:**
- Create: `Package.swift`, `Sources/Alloy/main.swift`, `Sources/AlloyCore/AlloyCore.swift` (placeholder `public enum AlloyCore {}`), `Sources/AlloyKit/RootView.swift` (the scaffold's `rootView()` moved here), `Sources/AlloyTestSupport/ScriptedTransport.swift` (empty for now), `Tests/AlloyKitTests/SmokeTests.swift` (the scaffold's test, retargeted), `.gitignore`, `README.md`, `Packaging/`, `scripts/`, `docs/metalui-gaps.md`

**Interfaces:**
- Produces: library targets `AlloyCore` (no dependencies), `AlloyTestSupport` (→ AlloyCore), `AlloyKit` (→ AlloyCore, MetalUI), executable `Alloy` (→ AlloyKit), test targets `AlloyCoreTests` (→ AlloyCore, AlloyTestSupport) and `AlloyKitTests` (→ AlloyKit, AlloyTestSupport, MetalUI, MetalUITesting).

- [ ] **Step 1: Generate the scaffold into a temporary folder.** `metalui new` refuses a non-empty destination, and `Alloy/` already holds `docs/` and `.git`.
  Run: `swift run --package-path ../MetalUI metalui new Alloy --path "$TMPDIR/alloy-scaffold" --local ../MetalUI --bundle-id dev.alloy.Alloy`
  Expected: `$TMPDIR/alloy-scaffold/Alloy/` contains `Package.swift`, `Sources/Alloy/{main,ContentView}.swift`, `Tests/AlloyTests/AlloyTests.swift`, `Packaging/`, `scripts/`, `.gitignore` and `README.md`.
- [ ] **Step 2: Copy everything except `.git` into `the repo root`,** leaving the existing `docs/` untouched.
- [ ] **Step 3: Restructure the manifest into the target layout under Interfaces**, following `MetalUI/Examples/Jotter/Package.swift`: tools-version 6.1, `.package(name: "MetalUI", path: "../MetalUI")`, products `.executable(Alloy)` and `.library(AlloyKit)`. Move `ContentView`/`rootView` into `AlloyKit` as `public`. Rename the test target to `AlloyKitTests` and change it to `import AlloyKit`.
- [ ] **Step 4: Create `docs/metalui-gaps.md`** with one section per gap G1–G7 from spec §5, each with status "requested 2026-11-07, accepted by MetalUI session" and the stopgap named in the roadmap.
- [ ] **Step 5: Build and test.**
  Run: `swift build && swift test`
  Expected: the build succeeds; the scaffold's single "Press me" test passes in `AlloyKitTests`.
- [ ] **Step 6: Commit** with message `chore: scaffold Alloy with metalui new; split AlloyCore/AlloyKit/Alloy`.

### Task 2: Finish the protocol probe and record fixtures

**Files:**
- Create: `tools/ccprobe/drive.py` (start from the scratchpad's `drive.py` and `hooksrv.py`), `docs/protocol-notes.md`, `Tests/AlloyCoreTests/Fixtures/{edit-turn,write-create,write-update,permission-allow,permission-deny,interrupt,compact,failed-tool,unknown-lines}.jsonl`

**Interfaces:**
- Produces: fixture files; each is NDJSON, one CLI stdout line per line, with host-written lines removed. Tasks 3, 8 and 9 load them through `Fixture.lines(_ name: String) -> [Data]`, a helper in `Tests/AlloyCoreTests/Fixture.swift` that reads them with `Bundle.module` (declare `resources: [.copy("Fixtures")]` on `AlloyCoreTests`).

- [ ] **Step 1: Copy the scratchpad probe driver into `tools/ccprobe/`.** Make its scratch-directory and model choices arguments, defaulting to a fresh temp git repo and `haiku`.
- [ ] **Step 2: Close the NOT TESTED items** against `claude` 2.1.319, each with one run:
  - (a) **Thinking text.** Find a setting or flag that makes thinking text non-empty in stream-json, passed only via `--settings` inline JSON or a CLI flag. Try `--model sonnet` with thinking-provoking prompts, inline settings keys related to thinking display or summaries (search `claude --help` and the settings docs at https://code.claude.com/docs/en/settings.md), and an env var if one is documented.
  - (b) The AskUserQuestion round trip (expected: a control request; record its subtype and the answer shape).
  - (c) `--resume <id>` after the process exits: what is replayed on stdout.
  - (d) Plan mode: what ExitPlanMode looks like on the wire.
  - (e) `updatedPermissions` in an allow response (e.g. accepting the `setMode acceptEdits` suggestion).
- [ ] **Step 3: Write `docs/protocol-notes.md`.** List every verified message shape (the facts above plus the Step 2 results) with one trimmed sample each, and mark anything still unverified. **If (a) found no way to get thinking text, say so at the top. The executing session must tell the user**, who asked to see thinking; Plan 3 then shows thinking as a collapsed "Thinking · N tokens" block.
- [ ] **Step 4: Save the fixtures** listed under Files from real runs (trim each file to a single turn; `unknown-lines.jsonl` holds two real lines, one invented `{"type":"brand_new_thing"}` line and one truncated line `{"type":"assist`).
- [ ] **Step 5: Commit** with message `docs: protocol notes and recorded stream-json fixtures for claude 2.1.319`.

### Task 3: JSON tree and inbound decoding

**Files:**
- Create: `Sources/AlloyCore/Wire/JSONValue.swift`, `Sources/AlloyCore/Wire/InboundMessage.swift`
- Test: `Tests/AlloyCoreTests/InboundDecoderTests.swift`

**Interfaces:**
- Produces:
```swift
public enum JSONValue: Codable, Sendable, Equatable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
  public subscript(key: String) -> JSONValue? { get }; public var stringValue: String? { get }; public var intValue: Int? { get } }

public struct PatchHunk: Codable, Sendable, Equatable { public var oldStart, oldLines, newStart, newLines: Int; public var lines: [String] }  // lines prefixed " ", "-", "+"

public enum InboundMessage: Sendable, Equatable {
  case systemInit(SystemInit)                                   // model, permissionMode, sessionID, tools: [String], slashCommands: [String]
  case delta(StreamDelta)
  case assistantBlock(messageID: String, block: ContentBlock)
  case toolResult(ToolResultMessage)
  case userEcho(text: String, isReplay: Bool)
  case result(TurnResult)
  case controlRequest(ControlRequest)
  case controlCancel(requestID: String)
  case permissionDenied(toolName: String, toolUseID: String, message: String)
  case compactBoundary(preTokens: Int?, postTokens: Int?)
  case thinkingTokens(Int)
  case ignored(type: String)                                    // known-but-unused, incl. echoed control_response, hook events
  case unknown(type: String)                                    // unrecognised or malformed ("<malformed>")
}
public enum StreamDelta: Sendable, Equatable { case blockStart(index: Int, kind: String), text(index: Int, String), thinking(index: Int, String, estimatedTokens: Int?), toolInput(index: Int, partialJSON: String), blockStop(index: Int) }
public enum ContentBlock: Sendable, Equatable { case text(String), thinking(String), toolUse(id: String, name: String, input: JSONValue) }
public struct ToolResultMessage: Sendable, Equatable { public var toolUseID: String; public var isError: Bool; public var text: String; public var result: ToolUseResult }
public enum ToolUseResult: Sendable, Equatable {
  case edit(filePath: String, originalFile: String?, hunks: [PatchHunk])
  case write(filePath: String, isCreate: Bool, content: String, originalFile: String?, hunks: [PatchHunk])
  case message(String)          // the string form (failures)
  case other(JSONValue)
  case none
}
public struct TurnResult: Sendable, Equatable { public var subtype: String; public var isError: Bool; public var costUSD: Double; public var inputTokens, outputTokens: Int; public var sessionID: String; public var terminalReason: String? }
public struct ControlRequest: Sendable, Equatable { public var requestID: String; public var kind: Kind
  public enum Kind: Sendable, Equatable { case canUseTool(toolName: String, input: JSONValue, description: String?, toolUseID: String?, suggestions: [JSONValue]), other(subtype: String, body: JSONValue) } }
public enum InboundDecoder { public static func decode(_ line: Data) -> InboundMessage }   // never throws
```

- [ ] **Step 1: Write the failing tests** in `InboundDecoderTests`:
  - `editTurnDecodesToolUseThenEditResult`: decoding `edit-turn.jsonl` yields (in order, ignoring `.delta` and `.systemInit`) an `.assistantBlock` with `.toolUse(name: "Edit")`, then a `.toolResult` whose `.result` is `.edit` with non-empty `hunks`, `originalFile != nil`, and `filePath` ending in `login.swift`, then a `.result` with `costUSD > 0`.
  - `writeCreateHasNilOriginalAndContent`: `write-create.jsonl` → `.write(isCreate: true, originalFile: nil, hunks: [])` with `content` non-empty.
  - `failedToolResultIsStringForm`: `failed-tool.jsonl` → `.toolResult` with `isError == true` and `.result == .message(_)` starting with `"Error"`.
  - `canUseToolDecodes`: `permission-allow.jsonl` contains `.controlRequest` with `.canUseTool(toolName: "Edit", …)` and a non-empty `requestID`. The echoed `control_response` decodes to `.ignored(type: "control_response")`.
  - `interruptEndsWithAbortedTools`: `interrupt.jsonl` contains `.controlCancel` and a `.result` with `terminalReason == "aborted_tools"` and `isError == true`.
  - `unknownAndMalformedLinesNeverThrow`: `unknown-lines.jsonl` → `.unknown(type: "brand_new_thing")` and `.unknown(type: "<malformed>")`, and the real lines around them still decode correctly.
  - `systemInitEveryTurnIsDecodedEachTime`: `compact.jsonl` (two turns) contains two `.systemInit` values, and the `.compactBoundary` has non-nil `preTokens`.
- [ ] **Step 2: Run them to confirm they fail.**
  Run: `swift test --filter InboundDecoderTests`
  Expected: compile failure; the types don't exist yet.
- [ ] **Step 3: Implement `JSONValue` and `InboundDecoder.decode`.** Parse the line into a `JSONValue` with `JSONDecoder`, then switch on `type` and `subtype`, reading fields through `JSONValue` subscripts so new fields never break decoding. For `user` messages: a `tool_result` content block makes a `.toolResult` (`tool_use_result` may be an object or a string); otherwise make a `.userEcho` (`isReplay` from the top level).
- [ ] **Step 4: Run the tests to confirm they pass.**
  Run: `swift test --filter InboundDecoderTests`
  Expected: 7 tests pass.
- [ ] **Step 5: Commit** with message `feat(core): decode claude stream-json into InboundMessage`.

### Task 4: Outbound lines, launch arguments, locating `claude`

**Files:**
- Create: `Sources/AlloyCore/Wire/OutboundMessage.swift`, `Sources/AlloyCore/Process/LaunchConfiguration.swift`, `Sources/AlloyCore/Process/ClaudeLocator.swift`
- Test: `Tests/AlloyCoreTests/OutboundTests.swift`, `Tests/AlloyCoreTests/LocatorTests.swift`

**Interfaces:**
- Consumes: `JSONValue` (Task 3).
- Produces:
```swift
public enum OutboundMessage: Sendable, Equatable {
  case user(text: String, uuid: UUID, priority: Priority?)      // Priority: .now, .next, .later → "now"/"next"/"later"
  case allow(requestID: String, updatedInput: JSONValue)
  case deny(requestID: String, message: String)
  case control(requestID: String, ControlSubtype)                // .interrupt, .setPermissionMode(String), .setModel(String)
  public func line() -> Data                                     // compact JSON + "\n"
}
public struct LaunchConfiguration: Sendable, Equatable {
  public var executable: URL; public var projectDirectory: URL; public var sessionID: UUID; public var resume: Bool
  public var extraSettingsJSON: String?; public var mcpConfigJSON: String?   // nil in Plan 1; used by Plan 5
  public func arguments() -> [String]
}
public enum ClaudeLocator {
  public static func locate(override: String?, loginShellLookup: () -> String?, isExecutable: (String) -> Bool, home: String) throws -> URL
  public static func loginShellLookup() -> String?              // runs `/bin/zsh -lc 'command -v claude'` (5 s timeout)
}
public struct ClaudeNotFound: Error, Equatable { public var tried: [String] }
```

- [ ] **Step 1: Write the failing tests.**
  - `userLineShape`: `.user(text: "hi", uuid: u, priority: .next).line()`, decoded back as JSON, equals `{"type":"user","message":{"role":"user","content":"hi"},"parent_tool_use_id":null,"uuid":"<u>","priority":"next"}` and ends with `\n`. With `priority: nil` the key is absent.
  - `allowAndDenyShapes`: allow → `{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"behavior":"allow","updatedInput":{"a":1}}}}`; deny → the same envelope with `{"behavior":"deny","message":"no"}`.
  - `controlShapes`: interrupt → `{"type":"control_request","request_id":"r2","request":{"subtype":"interrupt"}}`; `setModel("sonnet")` → `request:{"subtype":"set_model","model":"sonnet"}`; `setPermissionMode("plan")` → `request:{"subtype":"set_permission_mode","mode":"plan"}`.
  - `launchArgumentsNewSession`: `arguments()` equals exactly `["-p","--input-format","stream-json","--output-format","stream-json","--verbose","--include-partial-messages","--replay-user-messages","--permission-prompt-tool","stdio","--session-id","<uuid>"]`, contains none of `--bare`, `--permission-mode` or `--setting-sources`, and appends `["--settings", json]` / `["--mcp-config", json]` when those are set.
  - `launchArgumentsResume`: with `resume: true`, `--session-id <uuid>` is replaced by `--resume <uuid>`.
  - `locatorPrefersOverride`, `locatorUsesLoginShellThenFallbacks`: the order is override (if executable) → login-shell result → `~/.local/bin/claude` → `/opt/homebrew/bin/claude` → `/usr/local/bin/claude`.
  - `locatorReportsEverythingTried`: when nothing is executable, it throws `ClaudeNotFound(tried:)` listing every candidate in that order.
- [ ] **Step 2: Run them to confirm they fail.**
  Run: `swift test --filter 'OutboundTests|LocatorTests'`
  Expected: compile failure.
- [ ] **Step 3: Implement** to the interfaces above. `line()` uses `JSONSerialization` with `.sortedKeys` and `.withoutEscapingSlashes`.
- [ ] **Step 4: Run the tests to confirm they pass.**
  Run: `swift test --filter 'OutboundTests|LocatorTests'`
  Expected: all pass.
- [ ] **Step 5: Commit** with message `feat(core): outbound messages, launch arguments, claude locator`.

### Task 5: Process transport and scripted test transport

**Files:**
- Create: `Sources/AlloyCore/Process/SessionTransport.swift`, `Sources/AlloyCore/Process/ClaudeProcess.swift`, `Sources/AlloyTestSupport/ScriptedTransport.swift`
- Test: `Tests/AlloyCoreTests/ClaudeProcessTests.swift`, `Tests/AlloyCoreTests/Fixtures/fake-claude.sh`

**Interfaces:**
- Consumes: `InboundDecoder`, `OutboundMessage`, `LaunchConfiguration`.
- Produces:
```swift
public enum ProcessEvent: Sendable, Equatable { case message(InboundMessage), exited(status: Int32, stderrTail: String) }
public protocol SessionTransport: Sendable {
  func start() async throws -> AsyncStream<ProcessEvent>
  func send(_ message: OutboundMessage) async throws
  func terminate() async                                        // SIGINT, then SIGTERM after 2 s
}
public actor ClaudeProcess: SessionTransport { public init(configuration: LaunchConfiguration, environment: [String: String] = ProcessInfo.processInfo.environment) }
// AlloyTestSupport
public actor ScriptedTransport: SessionTransport {
  public init()
  public func emit(_ message: InboundMessage)                   // pushes .message
  public func emit(fixture lines: [Data])                       // decodes and pushes each
  public func exit(status: Int32, stderr: String)
  public var sent: [OutboundMessage] { get }
}
```

- [ ] **Step 1: Write the failing tests** using `fake-claude.sh`, a shell script that echoes its argv as one JSON line, cats a fixture file named by `$FAKE_FIXTURE`, then echoes each stdin line back as `{"type":"echo","line":…}`. With `FAKE_BIG=1` it first prints a 9 MB single-line `{"type":"assistant",…}`.
  - `streamsDecodedLinesInOrder`: the fixture `edit-turn.jsonl` comes out as `.message` events in file order.
  - `sendWritesOneLine`: after `send(.user(text: "hi", …))`, an `.unknown(type: "echo")` event arrives (the echo carries the exact line).
  - `handlesNineMegabyteLine`: with `FAKE_BIG=1` the first event is `.message(.assistantBlock…)`.
  - `exitReportsStatusAndStderrTail`: a script that writes `boom` to stderr and exits 3 → the last event is `.exited(status: 3, stderrTail: "boom\n")`. Keep the last 4 KB of stderr.
- [ ] **Step 2: Run them to confirm they fail.**
  Run: `swift test --filter ClaudeProcessTests`
  Expected: compile failure.
- [ ] **Step 3: Implement `ClaudeProcess`.** Use `Process` with three `Pipe`s and `currentDirectoryURL = projectDirectory`. Read stdout through `FileHandle.bytes.lines`-free buffering: accumulate `Data` from `readabilityHandler` and split on `\n`, so lines of any length work. `terminate()` sends SIGINT, then SIGTERM after 2 s, to **this process's own PID only**. Implement `ScriptedTransport` with an `AsyncStream.makeStream()` continuation.
- [ ] **Step 4: Run the tests to confirm they pass.**
  Run: `swift test --filter ClaudeProcessTests`
  Expected: 4 pass.
- [ ] **Step 5: Commit** with message `feat(core): ClaudeProcess transport and ScriptedTransport for tests`.

### Task 6: Hunks — apply and line diff

**Files:**
- Create: `Sources/AlloyCore/Ledger/PatchHunk.swift` (move `PatchHunk` here from Task 3)
- Test: `Tests/AlloyCoreTests/PatchHunkTests.swift`

**Interfaces:**
- Produces:
```swift
public struct TextLines: Sendable, Equatable, Codable {            // lossless split
  public init(_ text: String); public var lines: [String]; public var lineEnding: String /* "\n" or "\r\n" */; public var hasTrailingNewline: Bool
  public var text: String { get }                                   // round-trips the input byte-for-byte
}
public enum Patch {
  public static func apply(_ hunks: [PatchHunk], to lines: [String]) throws -> [String]   // throws PatchMismatch if " " or "-" lines don't match
  public static func diff(old: [String], new: [String], context: Int = 3) -> [PatchHunk] // built on `new.difference(from: old)`
  public static func reversed(_ hunk: PatchHunk) -> PatchHunk                            // swaps +/-, old/new ranges
}
public struct PatchMismatch: Error, Equatable { public var hunkIndex: Int; public var line: Int }
```

- [ ] **Step 1: Write the failing tests.**
  - `textLinesRoundTrip`: these round-trip byte-for-byte: `"a\nb\n"`, `"a\nb"`, `"a\r\nb\r\n"`, `""`, `"\n"`.
  - `applyRecordedEditHunk`: apply the hunks of the `edit-turn.jsonl` Edit result to `originalFile` and check the output equals the file content the fixture's later Read shows (or the `newString` substitution of `oldString` in `originalFile`).
  - `diffThenApplyRoundTrips`: for 200 seeded random line-array pairs (`SystemRandomNumberGenerator` replaced by a seeded generator), `apply(diff(old,new), to: old) == new`.
  - `diffMatchesStructuredPatchShape`: `diff(["a","b","c"], ["a","B","c"])` equals `[PatchHunk(oldStart:1, oldLines:3, newStart:1, newLines:3, lines:[" a","-b","+B"," c"])]`.
  - `applyDetectsMismatch`: applying a hunk whose `-` line is not present throws `PatchMismatch(hunkIndex: 0, …)`.
- [ ] **Step 2: Run them to confirm they fail.**
  Run: `swift test --filter PatchHunkTests`
  Expected: compile failure.
- [ ] **Step 3: Implement** to the interfaces. Hunk line numbers are 1-based, as in `structuredPatch`.
- [ ] **Step 4: Run the tests to confirm they pass.**
  Run: `swift test --filter PatchHunkTests`
  Expected: all pass.
- [ ] **Step 5: Commit** with message `feat(core): lossless text lines, hunk apply and line diff`.

### Task 7: File ledger — a text CRDT for attribution, Keep, Revert, anchors, persistence

Per spec §6.4, the ledger is a small sequence CRDT modeled on Zed's text buffer, without networking. It is used for permanent span identity, not merging: edits are applied one at a time.

**Files:**
- Create: `Sources/AlloyCore/Ledger/EditHistory.swift` (the CRDT), `Sources/AlloyCore/Ledger/FileLedger.swift` (the public facade), `Sources/AlloyCore/Ledger/ProjectLedger.swift`
- Test: `Tests/AlloyCoreTests/EditHistoryTests.swift`, `Tests/AlloyCoreTests/FileLedgerTests.swift`, `Tests/AlloyCoreTests/ProjectLedgerTests.swift`

**Interfaces:**
- Consumes: `TextLines`, `Patch`, `PatchHunk`.
- CRDT model (`EditHistory`, internal):
  - The document is an ordered array of **fragments**. Each fragment holds a run of text inserted by one insertion `InsertionID(edit: UUID?, offset: Int)` (`edit == nil` is the baseline), plus `deletedBy: Set<UUID>` (the edits that deleted it).
  - A fragment is **visible** iff its inserting edit is not `.reverted` and no non-reverted edit in `deletedBy` exists.
  - Applying an edit splits fragments at the operation's visible offsets, inserts new fragments tagged with the edit, and adds the edit id to the `deletedBy` of the deleted fragments.
  - Offsets are counted in Unicode scalars of the visible text.
  - A plain fragment array is enough for v1, since edits arrive per tool call and not per keystroke. Add a comment noting that a B-tree (Zed's SumTree) is the upgrade if Plan 6 benchmarks show ledger time.
- Turning a hunk into operations: for each hunk, take its old and new line blocks and run a **character-level** `CollectionDifference` between the two blocks' joined text. This yields minimal delete and insert operations at visible offsets, so an edit claims only the characters it actually changed.
- Produces:
```swift
public enum Author: Hashable, Codable, Sendable { case session(UUID), user, outside }
public struct EditRecord: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID; public var author: Author; public var path: String /* project-relative */; public var date: Date
  public var toolUseID: String?; public var hunks: [PatchHunk]; public var state: State   // .live, .kept, .reverted
}
public struct AttributedRun: Equatable, Sendable { public var text: String; public var edit: UUID? }   // nil = baseline or kept
public struct Anchor: Codable, Hashable, Sendable { /* InsertionID + bias */ }
public enum DiffLine: Equatable, Sendable { case context(text: String, line: Int), added(text: String, line: Int, edit: UUID, runs: [AttributedRun]), removed(text: String, edit: UUID) }
public enum RevertOutcome: Equatable, Sendable { case reverted(newText: String), conflict(reason: String) }
public struct FileLedger: Codable, Sendable {
  public init(path: String, baseline: String)
  public var text: TextLines { get }                          // visible text
  public private(set) var edits: [EditRecord]
  @discardableResult public mutating func applyPatch(author: Author, originalFile: String?, hunks: [PatchHunk], toolUseID: String?, date: Date) -> [EditRecord]
  @discardableResult public mutating func applyFullText(author: Author, newText: String, toolUseID: String?, date: Date) -> EditRecord?
  public func runs() -> [AttributedRun]                       // the visible text as attribution runs (adjacent same-edit runs merged)
  public func lineOwners() -> [UUID?]                         // per current line: the latest-dated live edit with a visible character on it; nil if none
  public func diffLines() -> [DiffLine]                       // live edits only, in display order; removed = tombstones of live edits, at their position
  public func anchor(atOffset: Int, bias: Anchor.Bias) -> Anchor   // .left / .right
  public func offset(of: Anchor) -> Int                       // current visible offset; a deleted anchor resolves to its nearest visible position
  public mutating func keep(_ id: UUID)
  public mutating func keepAll(where: (EditRecord) -> Bool)    // used for git-commit reset in Plan 4
  public mutating func revert(_ id: UUID, date: Date) -> RevertOutcome
}
public struct ChangedFile: Equatable, Sendable { public var path: String; public var authors: [Author] /* distinct, order of first live edit */ }
public struct ProjectLedger: Codable, Sendable {
  public init(projectRoot: URL)
  public var files: [String: FileLedger]
  public mutating func record(_ result: ToolUseResult, author: Author, toolUseID: String?, date: Date) -> [EditRecord]  // ignores paths outside the root, .message/.other/.none
  public func changedFiles() -> [ChangedFile]                  // files with ≥1 live edit, sorted by path
  public static func storeURL(projectRoot: URL, appSupport: URL) -> URL   // <appSupport>/Alloy/Projects/<sha256(projectRoot.path) hex prefix 16>/ledger.json
  public func save(to url: URL) throws; public static func load(from url: URL) throws -> ProjectLedger
}
```
- Behavior rules, which the tests pin:
  - `applyPatch` with `originalFile != text.text` first records an `.outside` edit (`diff(current → originalFile)`), then the session's edit. With `originalFile == nil` (Write create), the baseline is empty and the edit owns every character.
  - Before applying, `applyPatch` verifies the hunks against the visible text (`Patch.apply` must not throw). On mismatch, it records the change as a full-text `.outside` edit followed by an `applyFullText` for the session's result, so attribution degrades gracefully and nothing throws.
  - `keep(id)`: the edit's inserted fragments become baseline (`edit = nil`), its tombstones are physically removed, and its state becomes `.kept`.
  - `revert(id)`: **by identity, no search.**
    - It is a conflict if any other `.live` edit has inserted inside this edit's inserted fragments (between two of its fragments, with no baseline in between) or has deleted any of them. In that case it returns `.conflict(reason:)` naming the other edit's author, and changes nothing.
    - Otherwise it records a new `.user` edit whose hunks are the resulting text diff (the revert is the user's action), sets the target to `.reverted` (its insertions become invisible and its tombstones visible again), and returns `.reverted(newText:)`. The caller writes the file.
  - Anchors: an anchor at an offset names the fragment character there plus a bias. `offset(of:)` follows that character through later edits. If the character is deleted, the anchor resolves to the nearest visible position on its bias side.

- [ ] **Step 1: Write the failing tests** in `FileLedgerTests`. A = `.session(a)`, B = `.session(b)`; `e`/`f` are their edit ids.
  - `sessionEditOwnsChangedLine`: baseline `"1\n2\n3\n"`. A's hunk replaces line 2 with `X`. `lineOwners()` is `[nil, e, nil]`; `diffLines()` is `[.context("1",1), .removed("2",e), .added("X",2,e,…), .context("3",3)]`.
  - `twoSessionsSameLineBothAttributed`: baseline `"let value = 1\n"`. A changes it to `"let value = 10\n"`, then B changes it to `"var value = 10\n"` → `runs()` is `[("var", f), (" value = 1", nil), ("0", e), ("\n", nil)]`. (Exact runs follow from the character diffs: A inserts `0`, B replaces `let` with `var` — assert that A's `0` and B's `var` are attributed to their own edits.) `lineOwners()` gives the line to B, the later one.
  - `staleOriginalRecordsOutsideEditFirst` (Review Focus 4): the ledger text is `"1\n2\n3\n"`, but A's result says `originalFile = "1\n2\n3\n4\n"` → `applyPatch` returns `[.outside, A]` in that order, and line 4's owner is the outside edit.
  - `mismatchedHunkDegradesToFullText`: hunks that don't match `originalFile` → no throw; the final text equals the hunk result applied as full text, and an `.outside` record precedes the session's.
  - `writeCreateOwnsEverything`: `FileLedger(path:, baseline: "")` then `applyFullText(author: A, newText: "a\nb\n")` → `lineOwners()` is `[e, e]`. (`ProjectLedger.record` routes `.write(isCreate: true)` this way.)
  - `keepFoldsIntoBaseline`: after `keep(e)`, `diffLines()` has no `.added` or `.removed` lines for `e`, `runs()` has no `e` runs, and `ProjectLedger.changedFiles()` no longer lists the file.
  - `revertSurvivesShiftedLines`: A changes line 2, then B inserts 100 lines above it → `revert(e)` returns `.reverted`, the original line-2 text is restored at its new position, and B's 100 lines are intact.
  - `revertRestoresDeletedText`: A deletes lines 3–5 → `revert(e)` brings them back exactly, in place.
  - `revertConflictWhenLaterEditTouchesInsertedText`: A inserts `"hello"`, then B changes it to `"help"` → `revert(e)` returns `.conflict` mentioning B, and `text` is unchanged.
  - `revertIsAUserEdit`: after a successful revert, `edits.last?.author == .user` and `edits.first(where: { $0.id == e })?.state == .reverted`.
  - `anchorsTrackEdits`: an anchor at A's inserted `X` (offset 2) → after B inserts `"abc\n"` at the start, `offset(of:)` is 6; after A's edit is reverted, it resolves to the nearest visible position.
  - `crlfFileStaysCRLF` (Review Focus 5): a baseline with `\r\n` and an A edit → `text.text` still uses `\r\n` everywhere.
  - `largeFileSingleEditIsCheap`: a 100 000-line baseline with one edit applied → `edits.count == 1` and the fragment count is ≤ 3 (assert through an `internal var fragmentCount` read by `@testable import`).
- [ ] **Step 2: Write the failing tests** in `ProjectLedgerTests`:
  - `recordIgnoresPathsOutsideRoot`: an `/etc/hosts` edit → returns `[]`.
  - `recordUsesRelativePaths`: a `<root>/Sources/a.swift` edit is stored as `"Sources/a.swift"`.
  - `changedFilesListsDistinctAuthorsInOrder`: A, then B, then A edit a file → `authors == [A, B]`.
  - `saveLoadRoundTrip`: save to a temp URL and load → the result equals the original; `storeURL` is deterministic for the same root and differs for another root.
  - `saveLoadPreservesIdentity`: after edits by A and B, a save/load round trip, then `revert(e)` → the same result as reverting without the round trip. Fragments, tombstones and anchors are persisted, not just the text.
- [ ] **Step 3: Write the failing tests** in `EditHistoryTests`, the CRDT invariants:
  - `randomEditSequencesMatchPlainText`: across 300 seeded random sequences of 1–20 edits by 3 authors, after each edit `text.text` equals the result of applying the same full-text changes to a plain `String`.
  - `revertThenTextMatchesWithoutThatEdit`: for seeded sequences where the revert is not a conflict, the text after reverting edit k equals replaying every edit except k on the baseline (where that replay applies cleanly).
- [ ] **Step 4: Run them to confirm they fail.**
  Run: `swift test --filter 'EditHistoryTests|FileLedgerTests|ProjectLedgerTests'`
  Expected: compile failure.
- [ ] **Step 5: Implement** `EditHistory`, `FileLedger` and `ProjectLedger` to the model and rules above. `ProjectLedger.record` reads a file's baseline from disk the first time the file is seen, then for `.edit` uses `originalFile` (falling back to the disk read).
- [ ] **Step 6: Run the tests to confirm they pass.**
  Run: `swift test --filter 'EditHistoryTests|FileLedgerTests|ProjectLedgerTests'`
  Expected: all pass.
- [ ] **Step 7: Commit** with message `feat(core): CRDT edit history with character attribution, revert by identity, anchors, persistence`.

### Task 8: Transcript reducer and tool kinds

**Files:**
- Create: `Sources/AlloyCore/Chat/ToolKind.swift`, `Sources/AlloyCore/Chat/Transcript.swift`
- Test: `Tests/AlloyCoreTests/TranscriptTests.swift`

**Interfaces:**
- Consumes: `InboundMessage`, `EditRecord`.
- Produces:
```swift
public enum ToolKind: String, Sendable, CaseIterable { case read, search, shell, edit, write, web, subagent, todo, question, plan, mcp, other
  public static func classify(_ toolName: String) -> ToolKind }
public enum ToolSummary { public static func line(toolName: String, input: JSONValue, projectRoot: URL) -> String }
public struct ToolBlock: Sendable, Equatable { public var toolUseID: String; public var name: String; public var kind: ToolKind; public var summary: String
  public var status: Status /* .running, .succeeded, .failed, .denied, .interrupted */; public var resultText: String; public var editIDs: [UUID] }
public struct PermissionBlock: Sendable, Equatable { public var requestID: String; public var toolName: String; public var summary: String; public var input: JSONValue
  public var state: State /* .pending, .allowed, .denied, .cancelled */ }
public enum ChatBlock: Identifiable, Sendable, Equatable {
  case user(id: UUID, text: String)
  case assistantText(id: String, text: String)                 // id = "<messageID>#<index>"
  case thinking(id: String, text: String, estimatedTokens: Int)
  case tool(ToolBlock)                                         // id = toolUseID
  case permission(PermissionBlock)                             // id = "perm-<requestID>"
  case notice(id: UUID, kind: NoticeKind, text: String)        // .compacted, .interrupted, .exited, .error, .modelChanged
  public var id: String { get }
}
public struct Transcript: Sendable, Equatable {
  public private(set) var blocks: [ChatBlock]
  public mutating func appendUser(text: String, id: UUID)
  public mutating func apply(_ message: InboundMessage)
  public mutating func attach(editIDs: [UUID], toToolUseID: String)
  public mutating func resolvePermission(requestID: String, allowed: Bool)
}
```
- Classification: `Read`, `NotebookRead` → `.read`; `Grep`, `Glob`, `LS` → `.search`; `Bash`, `BashOutput`, `KillShell` → `.shell`; `Edit`, `MultiEdit`, `NotebookEdit` → `.edit`; `Write` → `.write`; `WebFetch`, `WebSearch` → `.web`; `Agent`, `Task` → `.subagent`; `TodoWrite` → `.todo`; `AskUserQuestion` → `.question`; `ExitPlanMode` → `.plan`; `mcp__*` → `.mcp`; anything else → `.other`.
- Summaries: Read, Edit and Write → the project-relative `file_path`; Bash → `command`, truncated to 120 characters; Grep → `pattern` (plus ` in <path>` when a path is given); Glob → `pattern`; WebFetch → `url`; WebSearch → `query`; Agent → `description`; anything else → the tool name.

- [ ] **Step 1: Write the failing tests.**
  - `streamingTextGrowsOneBlock`: a `.delta(.blockStart(0,"text"))` followed by three `.text` deltas, then an `.assistantBlock(.text(full))` → exactly one `.assistantText` block whose text is `full` (the final block replaces the streamed text and never duplicates it).
  - `editTurnProducesToolBlockSucceeded`: the `edit-turn.jsonl` fixture → a `.tool` block with `kind == .edit`, `summary == "login.swift"` and `status == .succeeded`.
  - `permissionLifecycle`: in `permission-allow.jsonl`, the `.controlRequest` adds a `.permission(.pending)` before the tool block resolves; `resolvePermission(allowed: true)` makes it `.allowed`. A `.controlCancel` for a pending request makes it `.cancelled`.
  - `deniedAndFailedTools`: `permission-deny.jsonl` → the tool's status is `.denied`; `failed-tool.jsonl` → `.failed` with `resultText` starting with `"Error"`.
  - `interruptAddsNotice`: `interrupt.jsonl` → running tools become `.interrupted`, and a `.notice(.interrupted)` appears.
  - `compactAddsNotice`: `compact.jsonl` → a `.notice(.compacted)` whose text contains the pre and post token counts.
  - `replayEchoDoesNotDuplicateUser`: `appendUser("hi")` followed by `.userEcho("hi", isReplay: true)` → only one `.user` block.
  - `classifyTable`: every name in the classification list maps as specified; `"mcp__alloy__send_message"` → `.mcp`.
- [ ] **Step 2: Run them to confirm they fail.**
  Run: `swift test --filter TranscriptTests`
  Expected: compile failure.
- [ ] **Step 3: Implement** to the interfaces above.
- [ ] **Step 4: Run the tests to confirm they pass.**
  Run: `swift test --filter TranscriptTests`
  Expected: all pass.
- [ ] **Step 5: Commit** with message `feat(core): transcript reducer, tool kinds and summaries`.

### Task 9: Session and Workspace models

**Files:**
- Create: `Sources/AlloyCore/Model/Session.swift`, `Sources/AlloyCore/Model/Workspace.swift`, `Sources/AlloyCore/Model/AlloySettings.swift`
- Test: `Tests/AlloyCoreTests/WorkspaceTests.swift`

**Interfaces:**
- Consumes: everything above; `ScriptedTransport` in tests.
- Produces:
```swift
public enum SessionStatus: Equatable, Sendable { case starting, idle, working, awaitingPermission, exited(status: Int32, message: String), failedToLaunch(String) }
@MainActor @Observable public final class Session: Identifiable {
  public let id: UUID; public var name: String; public let colorIndex: Int          // 0..<8, assigned round-robin
  public private(set) var status: SessionStatus; public private(set) var transcript: Transcript
  public private(set) var costUSD: Double; public private(set) var inputTokens: Int; public private(set) var outputTokens: Int
  public private(set) var model: String?; public private(set) var permissionMode: String?
}
public struct AlloySettings: Codable, Equatable, Sendable { public var claudePath: String?
  public static func load(appSupport: URL) -> AlloySettings; public func save(appSupport: URL) throws }   // <appSupport>/Alloy/settings.json; env ALLOY_CLAUDE_PATH overrides claudePath
public typealias TransportFactory = @Sendable (LaunchConfiguration) -> any SessionTransport
@MainActor @Observable public final class Workspace {
  public init(projectRoot: URL, appSupport: URL, settings: AlloySettings, locate: @escaping (String?) throws -> URL = { try ClaudeLocator.locate(override: $0, loginShellLookup: ClaudeLocator.loginShellLookup, isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }, home: NSHomeDirectory()) }, makeTransport: @escaping TransportFactory = { ClaudeProcess(configuration: $0) }, now: @escaping () -> Date = Date.init)
  public let projectRoot: URL
  public private(set) var sessions: [Session]
  public private(set) var ledger: ProjectLedger
  public var selectedSessionID: Session.ID?
  public var changedFiles: [ChangedFile] { get }
  @discardableResult public func newSession(name: String) async -> Session
  public func send(_ text: String, to id: Session.ID) async
  public func answerPermission(session id: Session.ID, requestID: String, allow: Bool) async
  public func interrupt(_ id: Session.ID) async
  public func stop(_ id: Session.ID) async
  public func keep(edit: UUID, path: String)
  public func revert(edit: UUID, path: String) async -> RevertOutcome   // writes the file on success
  public func restore() async        // loads sessions.json + ledger.json and resumes each session with resume: true
}
```
- Rules:
  - Allow sends `updatedInput` equal to the request's `input`, unchanged.
  - Status changes: `.systemInit` and `.assistantBlock` → `.working`; a pending `can_use_tool` → `.awaitingPermission`; `.result` → `.idle` (adding cost and tokens); `.exited` → `.exited` plus a `.notice(.exited)` holding the stderr tail. A locate failure → `.failedToLaunch("claude not found. Tried: … Set a path in Alloy settings or ALLOY_CLAUDE_PATH.")`.
  - The ledger is saved after every change. `sessions.json` (id, name, colorIndex) sits beside `ledger.json`.

- [ ] **Step 1: Write the failing tests** with a `ScriptedTransport` factory and a temp `appSupport`:
  - `newSessionLaunchesWithOwnIDAndColor`: two sessions → distinct ids, `colorIndex` values 0 and 1, and each `LaunchConfiguration.sessionID` equals its `Session.id`.
  - `editFlowsIntoLedgerAttributed`: feeding `edit-turn.jsonl` into session A's transport → `changedFiles == [ChangedFile(path: "login.swift", authors: [.session(A.id)])]`, and the tool block's `editIDs` holds the new record's id. (Write the fixture's `originalFile` into a temp project root first.)
  - `approveSendsAllowWithOriginalInput`: a `can_use_tool` request, then `answerPermission(allow: true)` → `transport.sent.last == .allow(requestID: r, updatedInput: input)`, and the block is `.allowed`.
  - `processExitShowsNoticeAndOthersContinue` (Review Focus 2): A's transport exits with status 1 and stderr `"auth expired"` → A is `.exited(1, …)` with a notice containing `"auth expired"`, while B still receives and shows messages.
  - `claudeNotFoundIsReadable` (Review Focus 1): a `locate` that throws `ClaudeNotFound(tried: ["/x"])` → `.failedToLaunch` whose message contains `"/x"` and `"ALLOY_CLAUDE_PATH"`.
  - `revertWritesFileAndRecordsUserEdit`: after the edit flow, `revert` writes the original content back to disk and the ledger gains a `.user` edit.
  - `restoreResumesSessions`: a second `Workspace` on the same `appSupport` → `restore()` recreates the sessions by id and name, each launched with `resume == true`, and the ledger matches.
- [ ] **Step 2: Run them to confirm they fail.**
  Run: `swift test --filter WorkspaceTests`
  Expected: compile failure.
- [ ] **Step 3: Implement.** Each session's transport stream is consumed in a `Task` that hops to `@MainActor` per event. Tool results go to `ledger.record`, and the returned ids go to `transcript.attach`.
- [ ] **Step 4: Run the tests to confirm they pass.**
  Run: `swift test --filter WorkspaceTests`
  Expected: all pass.
- [ ] **Step 5: Commit** with message `feat(core): Session and Workspace models with ledger wiring and restore`.

### Task 10: Theme, root layout and sidebar

**Files:**
- Create: `Sources/AlloyKit/Theme.swift`, `Sources/AlloyKit/SidebarView.swift`; Modify: `Sources/AlloyKit/RootView.swift`
- Test: `Tests/AlloyKitTests/SidebarTests.swift`, `Tests/AlloyKitTests/Support.swift`

**Interfaces:**
- Consumes: `Workspace`, `Session`, `ChangedFile`.
- Produces:
  - `public func rootView(workspace: Workspace) -> some Element`.
  - `ThemeColorKey` tokens, each a `Color(light:dark:)` pair using the mockup values (`docs/mockups/chat-detail.html`) for dark:
    - block tints: `Color.thinkingTint`, `.readTint`, `.shellTint`, `.editAddTint`, `.editRemoveTint`, `.errorTint`, `.warningTint`
    - surfaces: `.sidebarFill`, `.chatFill`, `.panelFill`
  - `Color.sessionColor(_ index: Int)`: 8 distinct hues starting blue `#5aa9ff`, orange `#f2a65a`, green `#8bd17c`, with index taken mod 8.
  - Test helper `alloyWindow(_ workspace: Workspace) throws -> TestWindow` (1200×800).
  - Accessibility identifiers: `"session-row-<uuid>"`, `"new-session"`, `"changed-file-<path>"`.

- [ ] **Step 1: Write the failing tests** (`@MainActor`, using `ScriptedTransport`):
  - `newSessionButtonAddsRow`: clicking `"new-session"` → `runUntil` sees `workspace.sessions.count == 1`, and the element `"session-row-<id>"` exists with the session's name as its label.
  - `selectingRowSelectsSession`: two sessions; clicking the second row → `workspace.selectedSessionID == second.id`.
  - `changedFilesShowOneDotPerAuthor`: after A and B edit `login.swift` → the element `"changed-file-login.swift"` exists and has two descendant elements with identifiers `"author-dot-0"` and `"author-dot-1"`.
  - `exitedSessionShowsStatus`: after an exit → the row contains text `"Exited"`.
- [ ] **Step 2: Run them to confirm they fail.**
  Run: `swift test --filter SidebarTests`
  Expected: compile failure.
- [ ] **Step 3: Implement.**
  - `rootView` is an `HSplitView` of sidebar, chat and file panel, with `.splitViewAutosaveName("alloy-main")`. The chat and file panel are placeholders until Tasks 11 and 12.
  - The sidebar is a `Column`:
    - a sessions `List(selection:)` whose rows show the color dot, name, a status word (`Starting`, `Idle`, `Working`, `Needs approval`, `Exited`, `Can't start`) and the cost as `$0.00`
    - a `"New session"` button with `.keyboardShortcut("n")`
    - a "Changed files" section
  - The new-session name is `"Session N"`; renaming comes in Plan 3.
- [ ] **Step 4: Run the tests to confirm they pass.**
  Run: `swift test --filter SidebarTests`
  Expected: all pass.
- [ ] **Step 5: Commit** with message `feat(ui): theme tokens, three-pane root, sessions and changed-files sidebar`.

### Task 11: Chat view — blocks, in-chat diffs, permission cards, composer

**Files:**
- Create: `Sources/AlloyKit/ChatView.swift`, `Sources/AlloyKit/ChatBlockViews.swift`, `Sources/AlloyKit/ComposerView.swift`
- Test: `Tests/AlloyKitTests/ChatTests.swift`

**Interfaces:**
- Consumes: `Session.transcript`, `Workspace.send/answerPermission/interrupt/keep/revert`, `FileLedger.diffLines()`, the theme tokens.
- Produces: `ChatView(workspace:)`, wired into `rootView`. Identifiers: `"block-<ChatBlock.id>"`, `"approve-<requestID>"`, `"deny-<requestID>"`, `"keep-<editID>"`, `"revert-<editID>"`, `"composer"`, `"send"`.

- [ ] **Step 1: Write the failing tests:**
  - `userAndAssistantTextAppear`: type `"hello"` into `"composer"` and press `.return` with `.primary` → the transport received `.user(text: "hello", …)`. Emitting an assistant text `"Hi there"` → `element(label: "Hi there")` exists.
  - `toolBlockShowsKindAndSummary`: replaying `edit-turn.jsonl` → the block `"block-<toolUseID>"` exists and contains the text `"Edit login.swift"`, plus the diff's removed and added line texts.
  - `approveButtonSendsAllow`: a `can_use_tool` request → clicking `"approve-<id>"` → the transport's last message is `.allow`; the card shows `"Allowed"`.
  - `denyButtonSendsDeny`: the same with `"deny-<id>"` → `.deny(requestID:, message: "Denied in Alloy")`.
  - `escapeInterrupts`: pressing `.escape` while focus is in the composer and the session is `.working` → the transport's last message is `.control(_, .interrupt)`.
  - `revertButtonRevertsEdit`: clicking `"revert-<editID>"` → the file on disk is restored and the button area shows `"Reverted"`.
- [ ] **Step 2: Run them to confirm they fail.**
  Run: `swift test --filter ChatTests`
  Expected: compile failure.
- [ ] **Step 3: Implement.**
  - **Layout:** `ScrollView` + `LazyVStack` over `selectedSession.transcript.blocks`. Scroll to the last block with `ScrollViewReader.scrollTo` when blocks change (stopgap until MetalUI G6 `defaultScrollAnchor(.bottom)`; log it in `docs/metalui-gaps.md`). The session color is a 4 px leading stripe on the chat column.
  - **User and assistant text:** user text is a right-inset bubble; assistant text uses `Text` with inline markdown (block markdown is Plan 3 / G2).
  - **Tool blocks:** a header row with a kind label (text such as `Edit`, `Read`, `$`; icons are Plan 3 / G3), the summary and the status, tinted by kind via the theme tokens.
    - Edit/Write blocks expand to their `diffLines()` restricted to the block's `editIDs`, monospaced, with Keep and Revert buttons.
    - Shell blocks show `resultText` in a monospaced box capped at 20 lines with "Show all".
  - **Permission cards:** an amber card with the tool name and summary plus Approve and Deny buttons.
  - **Composer:** a `TextEditor` plus a Send button. ⌘↩ sends; Esc interrupts.
- [ ] **Step 4: Run the tests to confirm they pass.**
  Run: `swift test --filter ChatTests`
  Expected: all pass.
- [ ] **Step 5: Commit** with message `feat(ui): chat with tool blocks, in-chat diffs, permission cards, composer`.

### Task 12: Read-only file panel, app entry, live smoke run

**Files:**
- Create: `Sources/AlloyKit/FilePanelView.swift`; Modify: `Sources/Alloy/main.swift`, `Sources/AlloyKit/RootView.swift`, `Sources/AlloyKit/SidebarView.swift` (clicking a changed file opens it), `README.md`
- Test: `Tests/AlloyKitTests/FilePanelTests.swift`

**Interfaces:**
- Consumes: `Workspace.ledger`, `FileLedger.diffLines()` and `lineOwners()`.
- Produces:
  - `Workspace.openFilePath: String?`, an added `@Observable` property.
  - `FilePanelView(workspace:)`.
  - Command line: `Alloy <project-dir> [<file-to-open>]`. Without arguments it uses the current directory. A file argument sets `openFilePath` at launch, which Plan 2's harness relies on.
  - Identifiers: `"file-line-<n>"` for current lines and `"gutter-<n>"` for gutter bars.

- [ ] **Step 1: Write the failing tests:**
  - `clickingChangedFileOpensPanel`: after an A edit, clicking `"changed-file-login.swift"` → `openFilePath == "login.swift"`, and `"file-line-1"` exists.
  - `gutterColoredByAuthor`: the line owned by A's edit has a `"gutter-<n>"` element; lines owned by nobody have none.
  - `removedLinesShownInline`: a removed line's text appears between its neighbors.
  - `fileWithoutLedgerShowsPlainText`: opening an untouched file shows all its lines and no gutters.
- [ ] **Step 2: Run them to confirm they fail.**
  Run: `swift test --filter FilePanelTests`
  Expected: compile failure.
- [ ] **Step 3: Implement.** This is a stopgap until MetalUI G1 `CodeView` (log it in `docs/metalui-gaps.md`): a `ScrollView` + `LazyVStack` of rows built from `diffLines()`, or plain lines for untouched files. Each row has a line number, a 3 px gutter bar in `sessionColor(colorIndex)` of the owning edit's author (or a fixed color for `.user` and `.outside`), and a monospaced `Text`; added and removed lines are tinted. `main.swift` parses arguments, builds `Workspace(projectRoot:appSupport:settings:)` with `appSupport` from `FileManager.urls(for: .applicationSupportDirectory)`, calls `restore()`, and opens a 1400×900 window.
- [ ] **Step 4: Run the full suite.**
  Run: `swift test`
  Expected: every AlloyCore and AlloyKit test passes; read the printed counts, not the exit status.
- [ ] **Step 5: Live smoke run, by hand (not automated).** Run `swift run Alloy /path/to/a/scratch/git/repo`, start two sessions, and ask each to edit the same small file. Expected:
  - Both chats stream.
  - The edits appear as in-chat diffs.
  - Permission cards appear if the user's settings ask, and Approve works.
  - The changed-files row shows two dots.
  - The file panel shows both authors' gutter colors.
  - Revert restores a hunk.

  Record the outcome and any defects in the task report. **Use a scratch repo, never one of the user's projects.**
- [ ] **Step 6: Commit** with message `feat(ui): read-only author-colored file panel; command-line project and file`.
