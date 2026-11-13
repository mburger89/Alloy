# Alloy LSP Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alloy runs installed language servers and shows their diagnostics, keyboard go-to-definition, semantic-token
colouring for languages with no tree-sitter grammar, and server status, with no measurable performance cost.

**Architecture:** A UI-free `AlloyLSP` target (depends on `AlloyCore` and `MetalUICodeBuffer`) holds the JSON-RPC
connection, server processes, registry, document sync and per-document results. `AlloyKit` wires results into the
code panel through `CodeDecorations` layers and the existing `DiffDecorations` call. All LSP I/O and conversion runs off
the main actor; the main actor only applies finished decorations.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, Swift Testing, MetalUI / MetalUITesting, Foundation `Process`.

**Spec:** `docs/superpowers/specs/2026-11-12-alloy-lsp-design.md` (recon notes with file:line references:
`the session scratchpad (lsp-recon.md, not kept)` —
copy anything you need into your report; the controller pastes relevant lines into each brief).

## Global Constraints

- Never write to `~/.claude` or the project's `.claude/`; Alloy writes only under its data dir (`ALLOY_DATA_DIR` or `<appSupport>/Alloy`). No network access, no server installs.
- `../MetalUI` is read-only. A missing MetalUI capability is reported, never worked around (gap G35 covers phase 2).
- No LSP work on the main actor except applying finished decorations / status; no view body reads LSP state that changes per message (panes are `.equatable()`; LSP stores are `@ObservationIgnored` except `LSPStatusModel`).
- Files over 1 MiB (1_048_576 bytes) are never sent to a server.
- Restart policy: at most 3 restarts per 5 minutes per server, then state `.failed`.
- Request timeout 10 s (`initialize` 30 s); stderr kept as a 64 KiB ring; outgoing queue unbounded only for didChange coalescing per document (see Task 4).
- Semantic-token request debounce 150 ms after the last edit; superseded requests are cancelled with `$/cancelRequest`.
- Files with a tree-sitter grammar (`Language.detect` non-nil) never request semantic tokens.
- Commit trailers on every commit: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and the session link trailer.
- Never `pkill`; kill only processes you started. Never launch the GUI app. Tests run with `swift test` in the repo root; the full suite must stay green.

## Review Focus

1. A server that is not installed: opening a matching file shows "not installed" status once, starts nothing, logs nothing per keystroke (Task 5 test `missingServerIsReportedOnceAndNotRetried`).
2. A server that crashes mid-session or exits on startup: restarts up to the limit, then `.failed`; documents keep editing normally (Task 2 test `crashRestartsThenFails`).
3. Non-ASCII text (emoji, CJK, combining marks) with a UTF-16-only server: diagnostic and definition ranges land on the right characters (Task 4 test `utf16RangesRoundTripNonASCII`, Task 6 test `diagnosticRangeOnEmojiLine`).
4. Rapid typing while a server is slow: didChange events arrive in order and complete; stale diagnostics (older document version) are dropped or mapped, never painted on the wrong text (Task 4 `burstEditsStayOrdered`, Task 6 `staleDiagnosticsAreMappedOrDropped`).
5. A file edited by a Claude session or on disk while open: the server sees the same text as the buffer (Task 4 `externalEditsReachServer`).

---

### Task 1: JSON-RPC connection with Content-Length framing

**Files:**
- Modify: `Package.swift` (new target `AlloyLSP` depending on `AlloyCore`, `MetalUICodeBuffer`; test target `AlloyLSPTests`)
- Create: `Sources/AlloyLSP/Framing.swift`, `Sources/AlloyLSP/JSONRPCConnection.swift`
- Test: `Tests/AlloyLSPTests/FramingTests.swift`, `Tests/AlloyLSPTests/JSONRPCConnectionTests.swift`

**Interfaces:**
- Produces:
  - `struct LSPFrameDecoder { mutating func append(_ data: Data) throws -> [Data] }` — returns complete message bodies; throws `LSPFramingError.badHeader` on a header without `Content-Length`; tolerates `Content-Type` and any header order; handles bodies split across chunks and several bodies in one chunk.
  - `enum LSPFrame { static func encode(_ body: Data) -> Data }`
  - `protocol LSPByteChannel: Sendable { func send(_ data: Data) async throws; var incoming: AsyncStream<Data> { get } ; func close() async }`
  - `actor JSONRPCConnection { init(channel: any LSPByteChannel, requestTimeout: Duration = .seconds(10)); func start(); func request(_ method: String, _ params: JSONValue?, timeout: Duration? = nil) async throws -> JSONValue; func notify(_ method: String, _ params: JSONValue?) async throws; func cancel(id: Int) async; func onNotification(_ handler: @escaping @Sendable (String, JSONValue?) -> Void); func onRequest(_ handler: @escaping @Sendable (String, JSONValue?) async -> Result<JSONValue, JSONRPCError>); func close() async }`
  - `struct JSONRPCError: Error, Equatable { var code: Int; var message: String; var data: JSONValue? }` with `static let requestCancelled = -32800`, `timedOut` (local, code -32001), `connectionClosed` (local, code -32099).
  - Request ids are increasing `Int`s from 1. Responses with unknown ids are ignored. Server requests with no handler get `-32601 MethodNotFound`. A request whose task is cancelled sends `$/cancelRequest` and throws `CancellationError`.

- [ ] **Step 1: Write failing tests** — `FramingTests`: `decodesSplitAndBatchedFrames` (two bodies split across 3 chunks at arbitrary byte boundaries decode to exactly those two bodies), `rejectsMissingContentLength`, `encodeRoundTrips` (UTF-8 body with "é" uses byte length). `JSONRPCConnectionTests` with an in-memory `PairChannel` test helper: `requestGetsMatchingResponse` (out-of-order responses to ids 1 and 2 resolve the right callers), `timeoutThrowsTimedOut` (timeout `.milliseconds(50)`), `cancelSendsCancelRequest` (cancelling the awaiting task writes `{"method":"$/cancelRequest","params":{"id":1}}`), `serverRequestWithoutHandlerGetsMethodNotFound`, `closeFailsPendingRequests` (pending throws `connectionClosed`).
- [ ] **Step 2: Run** `swift test --filter AlloyLSPTests` — expect failures (types missing).
- [ ] **Step 3: Implement** using `JSONValue` (`Sources/AlloyCore/Wire/JSONValue.swift`) for all payloads; encode with `JSONEncoder` (`.withoutEscapingSlashes`).
- [ ] **Step 4: Run** `swift test --filter AlloyLSPTests` — PASS; then full `swift test` — PASS.
- [ ] **Step 5: Commit** `feat(lsp): JSON-RPC connection with Content-Length framing`.

### Task 2: Server process, handshake and restart policy, with a fake server

**Files:**
- Create: `Sources/AlloyLSP/ServerProcess.swift`, `Sources/AlloyLSP/LanguageServer.swift`, `Sources/AlloyFakeLSP/main.swift` (executable target `alloy-fake-lsp`, test-only use)
- Modify: `Package.swift`
- Test: `Tests/AlloyLSPTests/LanguageServerTests.swift`

**Interfaces:**
- Consumes: Task 1 `JSONRPCConnection`, `LSPByteChannel`.
- Produces:
  - `final class ServerProcess: LSPByteChannel` — spawns `executable` + `arguments` with `environment` (PATH from login shell), `currentDirectory` = workspace root; stdout via readabilityHandler → `incoming`; stdin writes serialised with `F_SETNOSIGPIPE` (copy the pattern from `Sources/AlloyCore/Process/ClaudeProcess.swift`); stderr into a 64 KiB ring (`var stderrTail: String`); `var exited: AsyncStream<Int32>`; `func stop(grace: Duration) async` (SIGTERM, then SIGKILL after grace).
  - `struct ServerCapabilities: Sendable { var positionEncoding: PositionEncoding; var sync: TextSyncKind (.none/.full/.incremental); var definition: Bool; var semanticTokens: SemanticTokensLegend?; var semanticTokensDelta: Bool; var pullDiagnostics: Bool; init(json: JSONValue) }`
  - `enum PositionEncoding: String, Sendable { case utf8 = "utf-8", utf16 = "utf-16", utf32 = "utf-32" }`
  - `struct SemanticTokensLegend: Sendable, Equatable { var tokenTypes: [String]; var tokenModifiers: [String] }`
  - `enum ServerState: Sendable, Equatable { case starting, ready, notInstalled(command: String), failed(reason: String), stopped }`
  - `actor LanguageServer { init(config: ServerConfig, root: URL, launcher: @escaping @Sendable () throws -> any LSPByteChannel & ServerExitObserving); var state: ServerState { get }; var stateChanges: AsyncStream<ServerState>; var capabilities: ServerCapabilities? { get }; func start() async; func connection() async throws -> JSONRPCConnection; func shutdown() async; var onNotification: (@Sendable (String, JSONValue?) -> Void)?; var onRestart: (@Sendable () async -> Void)? }` — `start` sends `initialize` (processId, rootUri, workspaceFolders [root], clientInfo `{name:"Alloy"}`, capabilities: `general.positionEncodings ["utf-8","utf-16"]`, `textDocument.synchronization {didSave:true}`, `publishDiagnostics {relatedInformation:false, versionSupport:true}`, `definition {linkSupport:true}`, `semanticTokens {requests:{full:{delta:true}}, tokenTypes:[standard 3.17 list], tokenModifiers:[standard list], formats:["relative"]}`, `diagnostic {}`; `window.workDoneProgress: true`), then `initialized {}`. Answers server requests: `workspace/configuration` → array of `null` per item, `window/workDoneProgress/create` → null, `client/registerCapability` / `unregisterCapability` → null, `workspace/workspaceFolders` → [root]. `shutdown` sends `shutdown`, `exit`, then `stop(grace: .seconds(2))`.
  - `protocol ServerExitObserving { var exited: AsyncStream<Int32> { get } }`
  - Restart: on unexpected exit, restart if fewer than 3 restarts in the last 5 minutes (injectable clock `now: @Sendable () -> ContinuousClock.Instant` for tests), call `onRestart` (document sync re-opens documents), else `.failed(reason:)` with the last stderr line.
  - `alloy-fake-lsp`: reads framed JSON-RPC on stdin; behaviour from env `FAKE_LSP_SCRIPT` (JSON): capabilities to return, diagnostics to publish after `didOpen`/`didChange` (echoing the document version), definition result, semantic tokens result, `crashAfter` (exit 1 after N messages), `delayMs` per response; appends every received message as one JSON line to `FAKE_LSP_LOG` (a temp file path) for assertions.

- [ ] **Step 1: Write failing tests** — `handshakeNegotiatesUTF8` (fake returns `positionEncoding:"utf-8"`; `capabilities.positionEncoding == .utf8`; log shows `initialize` then `initialized`), `defaultsToUTF16WhenServerSilent`, `answersWorkspaceConfigurationWithNulls`, `crashRestartsThenFails` (fake `crashAfter: 1`; with a fake clock, 3 restarts then `.failed`, `onRestart` called 3 times), `shutdownSendsShutdownThenExit` (process exits; no zombie: `exited` yields).
- [ ] **Step 2: Run** `swift build --product alloy-fake-lsp && swift test --filter LanguageServerTests` — FAIL.
- [ ] **Step 3: Implement.** Tests locate the fake via the build products dir (`Bundle(for:)`-free: derive from `#filePath` → `.build/debug/alloy-fake-lsp`; skip with a clear message if missing).
- [ ] **Step 4: Run** filtered then full `swift test` — PASS.
- [ ] **Step 5: Commit** `feat(lsp): server process, handshake, restart policy; fake server for tests`.

### Task 3: Server registry, settings and locator

**Files:**
- Create: `Sources/AlloyLSP/ServerRegistry.swift`
- Modify: `Sources/AlloyCore/Model/AlloySettings.swift` (add `languageServers: [String: ServerConfigOverride]`, lenient `decodeIfPresent`, default `[:]`)
- Test: `Tests/AlloyLSPTests/ServerRegistryTests.swift`, extend the existing AlloySettings tests

**Interfaces:**
- Produces:
  - `struct ServerConfig: Sendable, Equatable, Codable { var id: String; var name: String; var languageID: String; var extensions: [String]; var fileNames: [String]; var command: String; var arguments: [String]; var initializationOptions: JSONValue?; var enabled: Bool }`
  - `struct ServerConfigOverride: Codable, Equatable, Sendable` (in AlloyCore, all fields optional, plus `enabled: Bool?`) — an entry keyed by an unknown id with `command` and `extensions` adds a server.
  - `struct ServerRegistry: Sendable { static let builtIn: [ServerConfig]; init(builtIn: [ServerConfig] = builtIn, overrides: [String: ServerConfigOverride]); func server(forPath path: String) -> ServerConfig?; var all: [ServerConfig] }` — match by file name first, then lowercased extension; disabled servers never match; first built-in wins for a shared extension unless overridden.
  - `struct ServerLocator: Sendable { init(loginPATH: @escaping @Sendable () -> String?, xcrunFind: @escaping @Sendable (String) -> String?); func resolve(_ command: String) -> String? }` — absolute paths checked for executability; bare names searched on the login PATH; `sourcekit-lsp` falls back to `xcrun --find sourcekit-lsp`. Results cached per command.
  - Built-in table (id: command args; extensions): `rust-analyzer` (rs); `sourcekit-lsp` (swift); `typescript-language-server --stdio` (ts tsx js jsx mjs cjs); `pyright-langserver --stdio` (py pyi); `gopls` (go); `clangd` (c h cc cpp cxx hpp hh m mm); `lua-language-server` (lua); `zls` (zig); `ruby-lsp` (rb, fileNames Gemfile Rakefile); `elixir-ls` (ex exs); `bash-language-server start` (sh bash zsh); `yaml-language-server --stdio` (yml yaml); `vscode-json-language-server --stdio` (json jsonc); `vscode-css-language-server --stdio` (css scss less); `vscode-html-language-server --stdio` (html htm); `marksman server` (md markdown); `taplo lsp stdio` (toml); `kotlin-language-server` (kt kts); `jdtls` (java); `ocamllsp` (ml mli); `haskell-language-server-wrapper --lsp` (hs); `dart language-server` (dart); `terraform-ls serve` (tf); `nil` (nix). Language ids per the LSP spec list.

- [ ] **Step 1: Failing tests** — `matchesByExtensionAndFileName` (`src/a.RS` → rust-analyzer, `Gemfile` → ruby-lsp, `notes.txt` → nil), `overrideReplacesCommandAndCanDisable`, `unknownOverrideIdAddsServer`, `locatorSearchesLoginPATHAndCaches` (temp dir with an executable `fake-ls`; a second call does not re-query), `locatorFallsBackToXcrunForSourceKit`, settings `oldSettingsFileWithoutLanguageServersStillLoads` and `languageServersRoundTrip`.
- [ ] **Step 2: Run** filtered — FAIL. **Step 3: Implement.** **Step 4:** filtered + full — PASS.
- [ ] **Step 5: Commit** `feat(lsp): server registry, settings overrides, login-PATH locator`.

### Task 4: Document sync and position conversion

**Files:**
- Create: `Sources/AlloyLSP/Positions.swift`, `Sources/AlloyLSP/DocumentSync.swift`
- Test: `Tests/AlloyLSPTests/PositionsTests.swift`, `Tests/AlloyLSPTests/DocumentSyncTests.swift`

**Interfaces:**
- Consumes: `CodeSnapshot`, `CodeEdit`, `CodeEditCursor` drain results (`.edits([CodeEdit])` / `.resync(CodeSnapshot)`) from MetalUICodeBuffer; Task 2 `LanguageServer`, `ServerCapabilities`.
- Produces:
  - `struct LSPPosition: Codable, Equatable, Sendable { var line: Int; var character: Int }`, `struct LSPRange: Codable, Equatable, Sendable { var start, end: LSPPosition }`
  - `enum Positions { static func lspPosition(utf8Offset: Int, in: CodeSnapshot, encoding: PositionEncoding) -> LSPPosition; static func utf8Offset(of: LSPPosition, in: CodeSnapshot, encoding: PositionEncoding) -> Int; static func utf8Range(of: LSPRange, in: CodeSnapshot, encoding: PositionEncoding) -> Range<Int> }` — clamps past-end lines/characters to the line end; a CRLF line's `\r` is not addressable (character past content clamps before `\r`).
  - `actor DocumentSync { init(server: LanguageServer); func open(uri: URL, languageID: String, snapshot: CodeSnapshot) async; func apply(uri: URL, change: DocumentChange) async; func saved(uri: URL) async; func close(uri: URL) async; func reopenAll() async; func snapshot(for uri: URL, version: Int) -> CodeSnapshot? }` where `enum DocumentChange: Sendable { case edits([CodeEdit], after: CodeSnapshot), resync(CodeSnapshot) }`.
  - LSP document version = the buffer version after the batch. Incremental sync emits one `contentChanges` entry per `CodeEdit`, ranges computed against the snapshot before that edit (keep the previous snapshot per document and advance it; for UTF-16 use `Positions` on that snapshot). Full sync or `.resync` sends the whole text. Changes for one document are sent strictly in order; the actor queues them. Keep the last 8 snapshots per document keyed by version for mapping results (Task 6/8).
  - Files with `snapshot.byteCount > 1_048_576` are never opened (`open` returns without sending; `apply` ignores unknown URIs).

- [ ] **Step 1: Failing tests** — `PositionsTests`: `utf16RangesRoundTripNonASCII` (line `"a😀é\u{301}b"`: UTF-8 offset of `b` ↔ utf16 character 5, utf8 character 8), `clampsPastLineEnd`, `crlfLineEndExcludesCR`. `DocumentSyncTests` with the fake server log: `incrementalChangesMatchEdits` (insert then delete produce two contentChanges with correct ranges, version increments), `fullSyncSendsWholeText` (server sync kind full), `resyncSendsWholeText`, `burstEditsStayOrdered` (200 single-char edits with fake `delayMs: 5` arrive in version order and final server text equals buffer text — fake echoes reconstructed text in its log), `externalEditsReachServer` (an `.external` origin edit is sent like typing), `largeFilesAreNotOpened`, `reopenAllAfterRestartSendsDidOpenWithCurrentText`.
- [ ] **Step 2–4:** run filtered (FAIL) → implement → filtered + full (PASS).
- [ ] **Step 5: Commit** `feat(lsp): document sync with incremental changes and position encodings`.

### Task 5: LSP manager and Workspace wiring

**Files:**
- Create: `Sources/AlloyLSP/LSPManager.swift`, `Sources/AlloyLSP/LSPStatusModel.swift`
- Modify: `Sources/AlloyKit/Code/CodePanel.swift` (`OpenDocumentView` init/observeBuffer/drain/close feed the manager alongside the highlight engine), `Sources/AlloyCore/Model/Workspace.swift` (a save hook: `var onSaved: (@MainActor (String) -> Void)?` called after `markSaved` in `performSave`), `Sources/Alloy/main.swift` / `installWindowShutdown` (shut servers down on quit), `Sources/AlloyCore/Model/Workspace.swift:updateSettings` (restart affected servers when `languageServers` changes), `Package.swift` (AlloyKit depends on AlloyLSP)
- Test: `Tests/AlloyLSPTests/LSPManagerTests.swift`, `Tests/AlloyKitTests/LSPPanelTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4.
- Produces:
  - `actor LSPManager { init(root: URL, registry: ServerRegistry, locator: ServerLocator, launcher: ServerLauncher); func documentOpened(path: String, snapshot: CodeSnapshot) async; func documentChanged(path: String, change: DocumentChange) async; func documentSaved(path: String) async; func documentClosed(path: String) async; func shutdownAll() async; func reload(registry: ServerRegistry) async; nonisolated var results: AsyncStream<LSPResult> }` — one `LanguageServer` per server id, started on the first `documentOpened` for a matching path; not started if the locator cannot resolve the command (status `.notInstalled(command:)`, reported once per server per session).
  - `enum LSPResult: Sendable { case diagnostics(path: String, version: Int?, items: [LSPDiagnostic]); case status(path: String, serverName: String, state: ServerState) }` (Task 6 adds `LSPDiagnostic`; Task 8 adds `semanticTokens`).
  - `@MainActor @Observable final class LSPStatusModel { private(set) var byPath: [String: (name: String, state: ServerState)] }` — the only observable LSP state; updated only on state transitions.
  - `struct ServerLauncher: Sendable { var make: @Sendable (ServerConfig, String /*resolved path*/, URL /*root*/) throws -> any LSPByteChannel & ServerExitObserving }` — production uses `ServerProcess` with the login PATH environment.
  - The workspace owns one `LSPManager` (created lazily on the first matching open; no manager work for files no server matches).

- [ ] **Step 1: Failing tests** — `LSPManagerTests`: `startsServerLazilyOnFirstMatchingOpen` (no process before; one after two opens of `.rs` files), `missingServerIsReportedOnceAndNotRetried` (two opens → one `.notInstalled` status, zero launches), `routesDocumentsToTheirServer` (`.rs` and `.go` go to different fake servers), `shutdownAllStopsServers`, `reloadRestartsChangedServers`. `LSPPanelTests` (MetalUITesting TestWindow, see `Tests/AlloyKitTests/FilePanelTests.swift` for rigs): `typingInPanelReachesServer` (fake server log shows didOpen then didChange with the typed text), `savingSendsDidSave`, `closingTabSendsDidClose`, and `typingDoesNotRerunScreenBodies` stays green (extend `ViewRerunTests` assertion to run with an LSP server active).
- [ ] **Step 2–4:** FAIL → implement → filtered + full PASS.
- [ ] **Step 5: Commit** `feat(lsp): LSP manager wired into documents, saves and quit`.

### Task 6: Diagnostics

**Files:**
- Create: `Sources/AlloyLSP/Diagnostics.swift`, `Sources/AlloyKit/Code/DiagnosticDecorations.swift`
- Modify: `Sources/AlloyKit/Code/DiffDecorations.swift` (merge diagnostic line decorations and virtual rows into its single `setLineDecorations` / `setVirtualRows` call), `Sources/AlloyKit/FilePanelView.swift` (`FilePanelHeader` shows counts), theme keys in `Sources/AlloyKit/Theme*` (`diagnosticError`, `diagnosticWarning`, `diagnosticInfo` with defaults for every built-in theme), the code panel key handling (F8 next problem, ⇧F8 previous)
- Test: `Tests/AlloyLSPTests/DiagnosticsTests.swift`, `Tests/AlloyKitTests/DiagnosticPanelTests.swift`

**Interfaces:**
- Produces:
  - `struct LSPDiagnostic: Sendable, Equatable { var range: Range<Int> /* UTF-8 bytes in the snapshot of `version` */; var severity: Severity (.error,.warning,.information,.hint); var message: String; var source: String? }`
  - `enum DiagnosticMapping { static func map(_ raw: [JSONValue], version: Int?, sync: DocumentSync, uri: URL, current: CodeSnapshot) async -> [LSPDiagnostic]? }` — convert with the snapshot of the reported version; if the server gave no version, use the current snapshot; if the reported version's snapshot is no longer kept, return nil (drop).
  - `@MainActor final class DiagnosticStore` (`@ObservationIgnored` content) keyed by path; `var counts: [String: (errors: Int, warnings: Int)]` is published to the header via a narrow observable (only changes when a count changes).
  - Painting: background tint runs on `.diagnostics` layer `asOf:` the diagnostic version (MetalUI maps forward through later edits); line decoration gutter bar in the severity colour; one virtual row per line with its first error/warning message (`"⚠ message — source"`), at most 200 virtual rows per file.
  - Pull diagnostics (`textDocument/diagnostic`) used only when the server lacks push but advertises `diagnosticProvider`, requested 300 ms after the last change.

- [ ] **Step 1: Failing tests** — `diagnosticRangeOnEmojiLine` (UTF-16 server range lands on the right bytes), `staleDiagnosticsAreMappedOrDropped` (diagnostics for version N arriving after N+2 paint on the mapped range; for an evicted version are dropped), `countsUpdateHeaderOnlyOnChange` (BodyProbe: header re-runs once when counts change, zero for identical republish), `diagnosticsMergeWithDiffDecorations` (a file with a session edit shows both the author bar and the diagnostic row), `nextProblemMovesCaret` (F8 selects the next diagnostic range, wraps), `virtualRowsCappedAt200`.
- [ ] **Step 2–4:** FAIL → implement → filtered + full PASS.
- [ ] **Step 5: Commit** `feat(lsp): diagnostics as tints, gutter bars, message rows and header counts`.

### Task 7: Go to definition (keyboard)

**Files:**
- Create: `Sources/AlloyLSP/Definition.swift`
- Modify: `Sources/AlloyCore/Model/Workspace.swift` (`open(_ path: String, select: Range<Int>)` alongside `open(_:revealLine:)`), the code panel key handling (F12) and the menu (a "Go to Definition" item with F12)
- Test: `Tests/AlloyLSPTests/DefinitionTests.swift`, `Tests/AlloyKitTests/DefinitionPanelTests.swift`

**Interfaces:**
- Produces: `extension LSPManager { func definition(path: String, utf8Offset: Int, snapshot: CodeSnapshot) async -> [DefinitionTarget] }`, `enum DefinitionTarget: Sendable, Equatable { case inWorkspace(path: String, range: LSPRange), external(url: URL, range: LSPRange) }` — accepts `Location`, `Location[]`, `LocationLink[]` (uses `targetSelectionRange`). Panel: first target; in-workspace opens and selects (range converted with the target document's snapshot once loaded); external opens read-only (existing read-only path for outside files; if none exists, show the location in the header status line and file a note in the report). No result: header shows "No definition found" for 2 s.

- [ ] **Step 1: Failing tests** — `parsesLocationLocationArrayAndLinks`, `externalTargetsAreMarkedExternal`, `f12OpensTargetAndSelects` (fake returns a range in another workspace file; panel shows that file with the selection), `noResultShowsMessage`, `requestCancelledWhenCaretMovesAgain` (second F12 before the first answers cancels the first).
- [ ] **Step 2–4:** FAIL → implement → filtered + full PASS.
- [ ] **Step 5: Commit** `feat(lsp): keyboard go-to-definition`.

### Task 8: Semantic-token colouring for languages without a grammar

**Files:**
- Create: `Sources/AlloyLSP/SemanticTokens.swift`, `Sources/AlloyKit/Code/SemanticHighlighter.swift`
- Modify: `Sources/AlloyKit/Code/CodePanel.swift` (`startHighlighting`: when `Language.detect` is nil and the file's server advertises semantic tokens, install `SemanticHighlighter`)
- Test: `Tests/AlloyLSPTests/SemanticTokensTests.swift`, `Tests/AlloyKitTests/SemanticHighlightTests.swift`

**Interfaces:**
- Produces:
  - `enum SemanticTokens { static func decode(_ data: [Int], legend: SemanticTokensLegend, snapshot: CodeSnapshot, encoding: PositionEncoding) -> [(Range<Int>, SyntaxToken)]; static func applyDelta(_ previous: [Int], edits: [JSONValue]) -> [Int]? }`
  - Token type → `SyntaxToken`: keyword/modifier → keyword; string/regexp → string; comment → comment; number → number; type/class/struct/enum/interface/typeParameter → type; function/method/macro → function; variable/parameter → variable; property/enumMember/event → property (enumMember → constant); namespace → type; operator → operator_; decorator → attribute; modifier `readonly`+variable → constant; `defaultLibrary` function/type → builtin. Unknown types are skipped.
  - `@MainActor final class SemanticHighlighter` pushes runs with `decorations.setHighlights(runs, in: wholeDocumentRange, layer: .semantic, asOf: version)` using `SyntaxPalette` styles (as `CodeViewHighlighter.styleID` does); requests debounced 150 ms after the last change, previous request cancelled; uses `semanticTokens/full/delta` with the last `resultId` when offered.
  - `LSPResult.semanticTokens(path: String, version: Int, runs: [(Range<Int>, SyntaxToken)])` (decoding happens off the main actor).

- [ ] **Step 1: Failing tests** — `decodesRelativeTokensUTF16` (two lines with an emoji; known legend; exact byte ranges and kinds), `appliesDeltaEdits`, `unknownTypesSkipped`, `grammarFilesNeverRequestTokens` (a `.rs` file with a fake server advertising tokens: zero `semanticTokens` requests in the log), `zigFileGetsColoured` (a `.zig` file with the fake server: the code view has `.semantic` runs coloured with the keyword palette colour), `typingDebouncesRequests` (20 keystrokes 10 ms apart → at most 2 requests).
- [ ] **Step 2–4:** FAIL → implement → filtered + full PASS.
- [ ] **Step 5: Commit** `feat(lsp): semantic-token colouring for files without a grammar`.

### Task 9: Status in the header and a Settings section; docs; performance check

**Files:**
- Modify: `Sources/AlloyKit/FilePanelView.swift` (`FilePanelHeader`: server name + state: "rust-analyzer starting…", "rust-analyzer", "rust-analyzer not installed", "rust-analyzer failed"; reads only `LSPStatusModel` for its path), `Sources/AlloyKit/SettingsView.swift` (section "Language servers": one row per registry server with name, extensions, Found / Not found, and an on/off Toggle writing `languageServers[id].enabled`; ids `settings-lsp-<id>`), `README.md` (a "Language servers" section: how detection works, the settings keys with a JSON example, privacy: no installs or network), `docs/parity.md` (results of the check below)
- Test: `Tests/AlloyKitTests/LSPStatusTests.swift`

- [ ] **Step 1: Failing tests** — `headerShowsServerStates` (fake launcher drives starting → ready; a missing command shows "not installed"), `settingsToggleDisablesServer` (toggle off → settings saved with `enabled:false`, server shut down, header shows nothing), `headerDoesNotRerunWhileTyping` (BodyProbe: zero header re-runs over 20 keystrokes after ready).
- [ ] **Step 2–4:** FAIL → implement → filtered + full PASS.
- [ ] **Step 5: Performance check** — run `tools/microbench.sh run` (no regression over 10%; do not run `update`), and report. The controller runs the GUI benchmark (typing latency, memory, idle CPU) with and without a real server, since subagents never launch the GUI app.
- [ ] **Step 6: Commit** `feat(lsp): server status, settings section, docs`.
