# Remote Workspaces — Plan 1: Host Seam (Phase 0) + Wire & Daemon Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put every project-machine touch behind a `Host` seam, with zero change for local projects. In parallel, build the server-independent foundation: the mux wire protocol, replay rings, and an `alloy-host` daemon skeleton.

**Architecture:** Track A adds `Host`, `HostFileSystem` and `HostProcesses` in AlloyCore, with `LocalHost`, which is today's code moved behind the seam. It then migrates every site and proves it with a path-translating test host whose virtual root doesn't exist on disk. Track B adds a new `AlloyRemote` library (frames, mux, replay ring) and an `alloy-host` executable (daemon, bridge, stop, idle state). It touches no existing code, so it runs alongside Track A.

**Tech Stack:** Swift 6, Swift Testing, Foundation, POSIX (`stat`, `rename`, Unix sockets), the existing AlloyRPC `JSONRPCConnection` and `RPCByteChannel`.

**Spec:** `docs/superpowers/specs/2026-11-27-remote-workspaces-design.md` (approved 2026-11-27).

## Parallel layout

```
Track A:  A1 ──┬─ A2 documents ───────┐
               ├─ A3 index/tree/search┤
               ├─ A4 git              ├─ A8 tripwire + guard + perf parity
               ├─ A5 agents/ACP       ┤
               ├─ A6 terminal + LSP   ┤
               └─ A7 services/store   ┘
Track B:  B1 frames+mux ── B2 replay ring ── B3 alloy-host skeleton      (starts at once, independent of A)
```

- A1 is first, alone. A2 to A7 then run in parallel, each in its own worktree branched from A1's merge.
- Merge A2 to A7 one at a time, rebasing each on the last. They own disjoint files apart from the regions of `Workspace.swift` listed per task. A8 goes last.
- B1 to B3 run serially on their own branch, concurrently with all of Track A.

## Global Constraints

- **Local behaviour:** local projects behave and perform exactly as today. `LocalHost` calls today's code directly, with no extra hop, queue or copy. The full suite stays green, and frame and perf guards are unchanged. Never raise a guard or timeout, and never weaken an assertion.
- **Disk access:** after A8, no project-path disk or process access exists outside `Sources/AlloyCore/Host/Local*.swift`, except the allowlisted app-local sites below.
- **App-local, never through Host:**
  - `AlloySettings`;
  - Themes (`ThemeStore`, `ThemeLibrary`, `ThemeSkillInstaller`, `BackgroundImage`, `ThemeController`);
  - AlloyPlugins installer, catalog and state;
  - `KnowledgePool` (SQLite);
  - `SessionLaunchFiles`;
  - `FrameTimingRecorder`;
  - `ProjectChoice`;
  - `Alloy/main.swift`;
  - `ui-state.json`.
- **No secrets:** never store keys, passwords or tokens in files or plaintext.
- **Repos:**
  - MetalUI (`../MetalUI`) is read-only. Forward MetalUI gaps to the MetalUI session; never build workarounds.
  - Worktrees go in the shared `worktrees/alloy/<task>` folder beside the repo. Never use `isolation: "worktree"`.
- **Tests:**
  - Run with `swift test --no-parallel --filter …`.
  - Terminal tests use `ScriptedPtySpawner()`.
  - Temp paths come from `TempFiles` or `TempDir` (AlloyTestSupport).
  - No broad pkill.
- **Track B and `$HOME`:** never write the real `~/.alloy` from tests. The daemon honours `ALLOY_HOST_HOME`, and tests set it to a `TempDir`.
- **Commits** end with the session's attribution trailers, given in each task's dispatch.

## Review Focus

1. **A missed direct disk call** reads the laptop's same-named path. This is pinned by A8 `tripwireFlows` and `noDirectDiskAccessOutsideHost`.
2. **The save race.** A write that lands between the temp-file write and the rename must still win, and the mode must be kept. Pinned by A1 `replaceAbortsWhenStampMoved` and `replaceKeepsMode`.
3. **A symlinked project root** (for example `/var` and `/private/var`). Paths the Host returns must keep today's root form. Pinned by A1 `realpathKeepsVirtualRootForm`.
4. **Sync calls that become async** reorder UI state, for example a tree expand or a file-exists check on the main actor. Pinned by the existing suites in A3 and A7 staying green unchanged.
5. **Local performance regression** in open, save and search. Pinned by A8 `perfParity`.

---

## Track A — Host seam (Phase 0)

### Task A1: Host protocols, LocalHost, TranslatingHost, Workspace injection

**Files:**
- Create:
  - `Sources/AlloyCore/Host/Host.swift`
  - `Sources/AlloyCore/Host/HostTypes.swift` (move `FileStamp` and `EditorFileRead` here from `Workspace.swift`)
  - `Sources/AlloyCore/Host/LocalHost.swift`
  - `Sources/AlloyCore/Host/LocalFileSystem.swift`
  - `Sources/AlloyCore/Host/LocalProcesses.swift`
  - `Sources/AlloyTestSupport/TranslatingHost.swift`
- Modify:
  - `Sources/AlloyCore/Model/Workspace.swift`: the init at 616-640, the `FileStamp` and `EditorFileRead` move, and the bodies of `replaceAtomically` and `readForEditing` (2043-2090, 2256-2290), which move into `LocalFileSystem`.
- Test:
  - `Tests/AlloyCoreTests/LocalHostTests.swift`
  - `Tests/AlloyCoreTests/TranslatingHostTests.swift`

**Interfaces (Produces):**
```swift
public enum HostID: Hashable, Sendable, Codable { case local; case remote(alias: String) }

public protocol Host: Sendable {
    var id: HostID { get }
    var fs: any HostFileSystem { get }
    var processes: any HostProcesses { get }
    func changes(root: URL) -> any FileChangeSource   // LocalHost: FSEventsSource(root:)
    /// Shared per-project store (sessions.json, ledger, notes, …). LocalHost: ProjectLedger.storeURL(projectRoot:appSupport:)
    func projectStore(root: URL, appSupport: URL) -> URL
}

public struct HostDirEntry: Sendable, Equatable { public var name: String; public var isDirectory: Bool; public var isSymlink: Bool }
public enum ReplaceOutcome: Sendable, Equatable { case wrote(FileStamp); case moved(current: FileStamp) }

public protocol HostFileSystem: Sendable {
    func readForEditing(_ url: URL, limit: Int) async -> EditorFileRead
    func read(_ url: URL, limit: Int?) async throws -> Data
    func stamp(_ url: URL) async -> FileStamp?                       // follows symlinks, like FileStamp.read(_:)
    func lstamp(_ url: URL) async -> FileStamp?                      // does not follow
    /// Temp beside target, keep POSIX mode, rename(2). Returns .moved without touching target if the stamp
    /// differs from `unlessMovedFrom` (checked before writing AND right before the rename). nil = no check.
    func replaceAtomically(_ data: Data, at url: URL, unlessMovedFrom expected: FileStamp?) async throws -> ReplaceOutcome
    func write(_ data: Data, to url: URL, mode: Int?) async throws   // plain create/overwrite (new files, save-as)
    func list(_ dir: URL) async throws -> [HostDirEntry]
    func kind(_ url: URL) async -> HostPathKind                      // .missing / .file / .directory / .other
    func isExecutable(_ url: URL) async -> Bool
    func remove(_ url: URL) async throws
    func move(_ from: URL, to: URL) async throws
    func createDirectory(_ url: URL) async throws                    // intermediate dirs, no error if exists
    func realpath(_ url: URL) async -> URL                           // FSEventsSource.realPath semantics
}
public enum HostPathKind: Sendable, Equatable { case missing, file, directory, other }

public struct HostRun: Sendable {   // mirrors GitResult
    public var status: Int32; public var stdout: Data; public var stderr: Data; public var timedOut: Bool
}
public protocol HostProcesses: Sendable {
    var home: URL { get }
    func loginPATH() async -> String?
    /// Resolves `name` on the host: override path, then login PATH, then `extraDirectories`.
    func locate(_ name: String, override: String?, extraDirectories: [URL]) async -> URL?
    /// Run to completion; SIGTERM after terminateAfter, SIGKILL after killAfter (GitProcess semantics).
    func run(_ executable: URL, _ args: [String], cwd: URL, stdin: Data?, environment: [String: String]?,
             terminateAfter: Double, killAfter: Double) async -> HostRun
    func git(_ args: [String], in root: URL, stdin: Data?, readOnly: Bool,
             terminateAfter: Double, killAfter: Double) async -> HostRun   // LocalProcesses: GitProcess.run
}

// AlloyTestSupport
public final class TranslatingHost: Host {   // wraps LocalHost; maps virtualRoot <-> realRoot on every URL in and out
    public init(virtualRoot: URL, realRoot: URL)
    public static func make() -> (host: TranslatingHost, virtualRoot: URL, realRoot: URL)
    // virtualRoot = /alloy-remote-test/<uuid>/proj (never exists); realRoot = TempFiles.directory("alloy-tripwire")
}
```
`Workspace.init` gains `host: any Host = LocalHost()`. The `writeFile`, `changes` and `locate` parameters become optionals defaulting to `nil`. A `nil` falls back to `host`, because Swift defaults can't refer to other parameters. Explicit injections, including the one test that passes `writeFile` and the six that pass `changes`, keep working. `Workspace` exposes `public let host: any Host`.

- [ ] **Step 1: Write failing tests** in `LocalHostTests`:
  - `replaceKeepsMode`: a file with mode 0o750 is replaced, and the mode is still 0o750.
  - `replaceAbortsWhenStampMoved`: rewrite the file after taking `expected`. The result is `.moved`, and the content is unchanged.
  - `replaceWritesWhenStampMatches`: the result is `.wrote` with the new size.
  - `readForEditingRejectsBinary`, using a NUL in the first 8 KiB.
  - `readForEditingTruncatesAtLimit`: the result is `truncated: true`, cut on a scalar boundary.
  - `gitRunsWithReadOnlyLocks`: `git config --get` in `makeRepo()`, status 0.
  - `locateFindsShOnPATH`.

  Then write them in `TranslatingHostTests`:
  - `virtualRootNeverExistsOnDisk`: `FileManager.default.fileExists(atPath: virtualRoot.path) == false`.
  - `writesLandInRealRoot`.
  - `listReturnsVirtualNames`.
  - `realpathKeepsVirtualRootForm`: realpath of `virtualRoot/sub/../a.txt` equals `virtualRoot/a.txt`.
  - `changesEmitVirtualPaths`: touch `realRoot/x`. The batch contains `virtualRoot.path + "/x"`.
  - `gitCwdIsTranslated`.
- [ ] **Step 2:** Run `swift test --no-parallel --filter "LocalHostTests|TranslatingHostTests"`. Expected: FAIL, with the types missing.
- [ ] **Step 3: Implement** the types above. `LocalFileSystem` carries today's `replaceAtomically` and `readForEditing` code verbatim. The `Workspace` statics call it synchronously through a `nonisolated` helper, so local saves keep today's thread and timing. `LocalProcesses.git` calls `GitProcess.run`, and `locate` wraps `ClaudeLocator` and `CommandLocator`. `TranslatingHost` translates by prefix-replacing the path, both on inputs and on every URL or path in outputs, including watcher batches.
- [ ] **Step 4:** Run the two suites, then the full `swift test --no-parallel --filter AlloyCoreTests`. Expected: PASS, and no other test changes.
- [ ] **Step 5:** Commit `feat(host): Host seam with LocalHost and TranslatingHost`.

### Task A2: Documents through the Host

**Files:**
- Modify:
  - `Sources/AlloyCore/Model/Workspace.swift`: `open` (1812-1880), `save` and `write` (1953-2090), revert (2358-2460).
  - `Sources/AlloyCore/Model/Workspace+Panes.swift` (151-212).
  - `Sources/AlloyCore/Model/Workspace+EditApply.swift`.
- Test: `Tests/AlloyCoreTests/HostDocumentsTests.swift`

**Interfaces:** consumes A1's `host.fs.readForEditing`, `replaceAtomically`, `write`, `stamp` and `realpath`. Produces nothing new.

- [ ] **Step 1: Failing tests,** each on a `Workspace` built with `TranslatingHost.make()` and `projectRoot: virtualRoot`:
  - `openReadsThroughHost`: the open file's text equals the content of `realRoot/a.swift`.
  - `saveWritesThroughHost`: edit, save, and `realRoot/a.swift` has the new text.
  - `saveRaceStillDetected`: rewrite the file in `realRoot` mid-save. The result is the existing `.changed` outcome.
  - `saveAsAndRenameThroughHost`.
  - `revertThroughHost`.
- [ ] **Step 2:** Run with `--filter HostDocumentsTests`. Expected: FAIL, because the reads hit the non-existent virtual path.
- [ ] **Step 3:** Replace every `FileManager`, `FileHandle`, `Data(contentsOf:)`, `.write(to:)`, `resolvingSymlinksInPath` and `Darwin.rename` use in the listed regions with `host.fs` calls. The `WriteOutcome` and `.changed(text:…)` logic stays in `Workspace`. On `.moved` it reads the current text with `host.fs.read`.
- [ ] **Step 4:** Run `HostDocumentsTests`, then every suite that matches `Save|Open|Revert|Panes|EditApply|Autosave|OutsideEdits`. Expected: PASS.
- [ ] **Step 5:** Commit `refactor(host): documents open/save/revert through Host`.

### Task A3: File index, tree and search through the Host

**Files:**
- Modify:
  - `Sources/AlloyCore/Model/FileIndex.swift`
  - `Sources/AlloyCore/Search/SearchEngine.swift` (the file read at 223-230)
  - `Sources/AlloyCore/Model/Workspace+Search.swift` (68-80)
  - `Sources/AlloyCore/Model/Workspace+FileTree.swift`
  - `Sources/AlloyCore/Model/Workspace+UIState.swift` (86-89)
- Test: `Tests/AlloyCoreTests/HostIndexSearchTests.swift`

**Interfaces:**
- `FileIndex.init(root: URL, host: any Host)`.
- `SearchEngine.init(root: URL, fs: any HostFileSystem, limits: SearchLimits = SearchLimits())`.
- The `git ls-files` call goes through `host.processes.git`, the `lstat` through `fs.lstamp`, and the enumerator fallback through `fs.list`. Search reads use `fs.read(url, limit: limits.maxFileBytes)`. Keep the 16 MB skip and the NUL-in-8 KiB skip.

- [ ] **Step 1: Failing tests** on a `TranslatingHost` workspace:
  - `indexListsRealFilesUnderVirtualRoot`: works with and without git.
  - `treeExpandListsThroughHost`.
  - `searchFindsMatchInRealRoot`.
  - `searchOverlayStillWinsOverDisk`.
  - `restoredFolderExistenceThroughHost`.
- [ ] **Step 2:** Run with `--filter HostIndexSearchTests`. Expected: FAIL.
- [ ] **Step 3:** Migrate the listed sites. The main-actor file-exists checks become `await host.fs.kind`. Keep the call order so UI state is published in the same frame as today.
- [ ] **Step 4:** Run `HostIndexSearchTests` plus suites matching `FileIndex|FileTree|Search|UIState`. Expected: PASS, with the existing tests unchanged.
- [ ] **Step 5:** Commit `refactor(host): index, tree and search through Host`.

### Task A4: Git through the Host

**Files:**
- Modify:
  - `Sources/AlloyCore/Git/GitService.swift` (106), `GitService+Write.swift` (124-137), `GitStatus.swift` (16)
  - `Sources/AlloyCore/Git/GitBaseline.swift` (37, 72-75, 136-146)
  - `Sources/AlloyCore/Model/OutsideEdits.swift` (480)
  - `Workspace.readBranchName`
  - `Sources/AlloyKit/Git/GitTabActions.swift` (30)
- Test: `Tests/AlloyCoreTests/HostGitTests.swift`

**Interfaces:**
- `GitService.init(root: URL, host: any Host)`.
- `GitBaseline` takes `host: any Host`.
- All runs go through `host.processes.git`, and file checks and reads (HEAD, rebase markers, `index.lock`) through `host.fs`.
- `GitBaseline`'s external git-dir watcher uses `host.changes(root:)`.
- `GitProcess.run` stays as `LocalProcesses`' implementation.

- [ ] **Step 1: Failing tests** on a `TranslatingHost` repo (`makeRepo` in realRoot):
  - `statusThroughHost`.
  - `branchNameThroughHost`.
  - `stageAndCommitThroughHost`.
  - `staleIndexLockRemovedThroughHost`.
  - `rebaseMarkerSeenThroughHost`.
  - `baselineRetryStillRetriesOnTimeout`: a scripted `HostProcesses` returns `timedOut` twice, then status 0, which shows the `attempts = 3` behaviour is kept.
- [ ] **Step 2:** Run with `--filter HostGitTests`. Expected: FAIL.
- [ ] **Step 3:** Migrate the listed sites.
- [ ] **Step 4:** Run `HostGitTests` plus suites matching `Git|Baseline|OutsideEdits|Blame|Hunks`. Expected: PASS.
- [ ] **Step 5:** Commit `refactor(host): git through Host`.

### Task A5: Agents, ACP files and transcripts through the Host

**Files:**
- Modify:
  - `Sources/AlloyCore/Model/Workspace+ACPFiles.swift` (65-144)
  - `Sources/AlloyCore/Agents/ACPPathPolicy.swift` (96-114)
  - `Sources/AlloyACP/ACPTranslator.swift` (48-50)
  - `Sources/AlloyCore/Agents/AgentDetector.swift`
  - `Sources/AlloyCore/Process/ClaudeLocator.swift`
  - `Sources/AlloyCore/Chat/TranscriptFile.swift`
  - `Workspace.swift` (986, 1042, the launch region at about 1080-1115)
  - `Workspace+ACP.swift` (`launchACP`, the `acp-history` path)
  - `Sources/AlloyCore/Agents/ACPHistory.swift`
- Test: `Tests/AlloyCoreTests/HostAgentsTests.swift`

**Interfaces:**
- `ACPPathPolicy.resolve` takes `fs: any HostFileSystem` and is async.
- `ACPTranslator` gets a `read: @Sendable (URL) async -> Data?` closure, which the workspace supplies as `host.fs.read`.
- `AgentDetector` and `ClaudeLocator` resolve through `host.processes.locate` and `loginPATH`.
- `ACPHistory` reads and appends through `host.fs`. Add `HostFileSystem.append(_ data: Data, to url: URL, mode: Int) async throws` (0600), with `LocalFileSystem` using today's `FileHandle` append. **A5 owns this addition to A1's protocol.**

- [ ] **Step 1: Failing tests** on a `TranslatingHost` workspace with `AlloyFakeACP`, whose cwd is translated:
  - `acpReadServesDiskThroughHost`.
  - `acpReadPrefersOpenBuffer`.
  - `acpWriteThroughHostRecordsLedger`.
  - `acpProtectedPathStillAsks`.
  - `pathPolicyRejectsEscapeThroughSymlink`: a symlink in realRoot points outside. The result is rejected.
  - `acpHistoryAppendsThroughHost`: the file is in realRoot's store with mode 0600.
  - `claudeTranscriptReadThroughHost`.
- [ ] **Step 2:** Run with `--filter HostAgentsTests`. Expected: FAIL.
- [ ] **Step 3:** Migrate the listed sites.
- [ ] **Step 4:** Run `HostAgentsTests` plus suites matching `ACP|Agent|Claude|Transcript|Fork|Permission`. Expected: PASS.
- [ ] **Step 5:** Commit `refactor(host): agents, ACP files and transcripts through Host`.

### Task A6: Terminal and LSP through the Host

**Files:**
- Modify:
  - `Sources/AlloyTerminal/TerminalManager.swift` (the spawn checks)
  - `Sources/AlloyTerminal/TerminalLaunch.swift` (`TerminalLaunchPlanner`: the shell checks and home)
  - `Sources/AlloyKit/Terminal/LinkDetector.swift` (103-116)
  - `Sources/AlloyKit/Terminal/TerminalPanelStore.swift` (165)
  - `Sources/AlloyLSP/ServerRegistry.swift` (`ServerLocator`, `runTool`)
  - `Sources/AlloyLSP/References.swift` (86)
  - `Sources/AlloyLSP/ConfigProbe.swift` (12-17)
- Test: `Tests/AlloyKitTests/HostTerminalLSPTests.swift`

**Interfaces:**
- `TerminalManager.init(projectRoot:spawner:fs:)` takes `fs: any HostFileSystem`.
- `ServerLocator` takes `processes: any HostProcesses`.
- `References` and `ConfigProbe` defaults read through `fs`.
- `PtySpawner` and `ServerLauncher` are unchanged in this plan; remote implementations come in Plan 3.

- [ ] **Step 1: Failing tests,** all with `ScriptedPtySpawner()` and `FakeServer`:
  - `terminalCwdCheckedThroughHost`: a virtual cwd is accepted, and a missing one falls back.
  - `terminalLinkResolvesThroughHost`.
  - `serverLocatorUsesHostPATH`: a scripted `HostProcesses` returns a fake path, and the locator returns it.
  - `configProbeReadsThroughHost`.
- [ ] **Step 2:** Run with `--filter HostTerminalLSPTests`. Expected: FAIL.
- [ ] **Step 3:** Migrate the listed sites.
- [ ] **Step 4:** Run `HostTerminalLSPTests` plus suites matching `Terminal|LSP|Link|Rename|References`. Expected: PASS.
- [ ] **Step 5:** Commit `refactor(host): terminal and LSP through Host`.

### Task A7: Services, knowledge, coordination and project store through the Host

**Files:**
- Modify:
  - `Sources/AlloyKit/Code/RenameService.swift` (130), `CodeActionService.swift` (123)
  - `Sources/AlloyKit/Plugins/PluginCoordinator+Project.swift` (35-58)
  - `Sources/AlloyCore/Plugins/PluginWriteRefusal.swift` (33-42)
  - `Sources/AlloyKit/Chat/ComposerModel.swift` (146)
  - `Sources/AlloyCore/Knowledge/NotesTools.swift`
  - `Sources/AlloyCore/Coordination/OverlapHook.swift`, `Claims.swift`, `SharedContext.swift`
  - `Sources/AlloyCore/Ledger/ProjectLedger.swift` (110-122)
  - `Workspace.swift` (the `storeDirectory`, `persistSessions` and `ensureLoaded`/`loadFile` region at 2494-2590)
  - `Workspace+Pool.swift` (331)
  - `UIState.swift`
- Test: `Tests/AlloyCoreTests/HostStoreServicesTests.swift`

**Interfaces:**
- `Workspace.storeDirectory` returns `host.projectStore(root: projectRoot, appSupport: appSupport)`.
- Shared store files (sessions, ledger, claims, overlap, told, notes, reads, generations) are read and written through `host.fs`.
- `ui-state.json` keeps its local path and plain `FileManager`, since it's app-local per spec.
- Note stamps go through `fs.stamp` and `fs.realpath`.

- [ ] **Step 1: Failing tests:**
  - `sharedStoreWritesThroughHost`: on a `TranslatingHost` whose `projectStore` is under realRoot, the sessions and ledger land there.
  - `uiStateStaysLocal`: `ui-state.json` sits under `appSupport`, not the host store.
  - `pluginProjectWriteThroughHost`.
  - `pluginWriteRefusalUsesHostRealpath`.
  - `composerAttachmentReadThroughHost`.
  - `noteStampsThroughHost`.
  - `renameEditsThroughHost`.
- [ ] **Step 2:** Run with `--filter HostStoreServicesTests`. Expected: FAIL.
- [ ] **Step 3:** Migrate the listed sites. `loadFile`'s rule that moves a corrupt file aside goes through `fs.move`.
- [ ] **Step 4:** Run `HostStoreServicesTests` plus suites matching `Ledger|Claims|Overlap|Notes|Knowledge|Plugin|Composer|Rename|CodeAction|Sessions|UIState`. Expected: PASS.
- [ ] **Step 5:** Commit `refactor(host): services, coordination and project store through Host`.

### Task A8: Disk tripwire, static guard, perf parity

**Files:**
- Create:
  - `Tests/AlloyKitTests/TripwireFlowTests.swift`
  - `Tests/AlloyCoreTests/HostBoundaryGuardTests.swift`
- Modify: whatever the guard flags.

**Interfaces:** consumes everything from A1 to A7.

- [ ] **Step 1: `tripwireFlows`.** Build a full `alloyWindow` on a `TranslatingHost` workspace with `ScriptedPtySpawner()` and `AlloyFakeACP`. Then, in order:
  - open a file, edit it and save it;
  - expand the tree, search and open a result;
  - read git status and stage a file;
  - run an agent turn that reads and writes a file, accept its permission prompt, and check the ledger;
  - open a terminal;
  - quit and restore.

  Each step asserts that the effect landed in realRoot or in the window. Any bypass hits the non-existent virtual root and fails.
- [ ] **Step 2: `noDirectDiskAccessOutsideHost`.** Scan `Sources/AlloyCore`, `AlloyKit`, `AlloyACP`, `AlloyLSP` and `AlloyTerminal` for `FileManager.default`, `FileHandle(`, `Data(contentsOf`, `String(contentsOf`, `.write(to:`, `Process()`, `Darwin.rename`, `resolvingSymlinksInPath` and `realpath(`. Fail on any hit outside `Sources/AlloyCore/Host/Local*.swift` and the allowlist of app-local files named in Global Constraints. The allowlist lives in the test file with one comment per entry.
- [ ] **Step 3:** Run both tests. Fix any hit by moving it behind the Host, or add it to the allowlist only if the spec lists it as app-local.
- [ ] **Step 4: `perfParity`.**
  - Run on master and on this branch: `CodeModePerformanceTests`, `TranscriptRowRerunTests`, `ACPFrameGuardTests`, `CommandPalettePerformanceTests`, and the open/save timings in `FrameTimingTests`, each 3 runs, `--no-parallel`.
  - Expected: every counter is identical and every timing is within run-to-run noise.
  - Append one `host-seam-parity` line to `Bench/results/perf-history.jsonl`.
- [ ] **Step 5:** Run the full suite, `swift test --no-parallel`, on master and the branch, and compare failures. Expected: no new failures.
- [ ] **Step 6:** Commit `test(host): disk tripwire, boundary guard and perf parity`.

---

## Track B — Wire and daemon foundation (independent; start immediately)

### Task B1: Frames and mux

**Files:**
- Create:
  - `Sources/AlloyRemote/Frame.swift`
  - `Sources/AlloyRemote/Mux.swift`
- Modify: `Package.swift` (new library `AlloyRemote`, depending on `AlloyCore` and `AlloyRPC`; test target `AlloyRemoteTests`).
- Test: `Tests/AlloyRemoteTests/FrameTests.swift`, `MuxTests.swift`

**Interfaces (Produces):**
```swift
public enum FrameKind: UInt8, Sendable { case json = 0, binary = 1, control = 2 }
public struct Frame: Sendable, Equatable { public var channel: UInt32; public var kind: FrameKind; public var payload: Data }
// Wire: channel UInt32 BE | kind UInt8 | length UInt32 BE | payload. Max payload 1 MiB (Frame.maxPayload = 1 << 20).
public struct FrameDecoder { public mutating func append(_ data: Data) throws -> [Frame] }  // throws FrameError.oversized / .badKind
public enum FrameError: Error, Equatable { case oversized(UInt32), badKind(UInt8) }

public actor Mux {
    public init(send: @escaping @Sendable (Data) async throws -> Void, incoming: AsyncStream<Data>)
    public func open(_ channel: UInt32) -> MuxChannel        // channel 0 reserved for control
    public func close()
}
public final class MuxChannel: RPCByteChannel, Sendable {   // conforms to AlloyRPC's RPCByteChannel
    public func sendBinary(_ data: Data) async throws        // chunked to Frame.maxPayload
    public var binary: AsyncStream<Data> { get }
}
// Flow: per-channel credit, initial 256 KiB; receiver grants credit back via control frames as it consumes.
```

- [ ] **Step 1: Failing tests:**
  - `frameRoundTrip`.
  - `decoderHandlesSplitAndCoalescedChunks`.
  - `oversizedFrameThrows`, with a length of 2 MiB.
  - `badKindThrows`.
  - `jsonRPCOverMuxChannel`: a `JSONRPCConnection` pair over a channel pair answers a request.
  - `largeBinaryDoesNotStarveJSON`: send 64 MiB of binary on channel 2. A JSON ping on channel 1 arrives after at most 2 frames of channel 2.
  - `creditStopsSenderUntilGranted`.
- [ ] **Step 2:** Run `swift test --no-parallel --filter AlloyRemoteTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. The scheduler takes channels round-robin, one frame per channel per turn.
- [ ] **Step 4:** Run with `--filter AlloyRemoteTests`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(remote): frames and multiplexed channels`.

### Task B2: Replay ring

**Files:**
- Create: `Sources/AlloyRemote/ReplayRing.swift`
- Test: `Tests/AlloyRemoteTests/ReplayRingTests.swift`

**Interfaces (Produces):**
```swift
public struct ReplayRing: Sendable {
    public init(byteCap: Int)                       // spec caps: agent 32 MB, terminal 8 MB (ReplayRing.agentCap / .terminalCap)
    public mutating func append(_ payload: Data) -> UInt64   // returns seq, starting at 1
    public mutating func acknowledge(through seq: UInt64)    // frees entries ≤ seq
    public func resume(after seq: UInt64) -> ReplayResume
    public var lastSeq: UInt64 { get }
}
public enum ReplayResume: Sendable, Equatable { case items([(UInt64, Data)]) ; case gapTooLarge(oldest: UInt64) }
```
`ReplayResume` needs a manual `Equatable` because it holds a tuple array; use a small struct `Entry` instead if that's simpler. That one's the implementer's call.

- [ ] **Step 1: Failing tests:**
  - `resumeReturnsGapExactly`.
  - `evictsOldestPastByteCap`.
  - `resumeBeforeOldestIsGapTooLarge`.
  - `acknowledgeFreesMemory`: `byteCount` drops.
  - `seqIsMonotonicAcrossEviction`.
- [ ] **Step 2:** Run with `--filter ReplayRingTests`. Expected: FAIL.
- [ ] **Step 3:** Implement as a deque of entries with a running byte count.
- [ ] **Step 4:** Run with `--filter ReplayRingTests`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(remote): bounded replay ring`.

### Task B3: `alloy-host` skeleton (daemon, bridge, stop, handshake, idle state)

**Files:**
- Create:
  - `Sources/AlloyHost/main.swift`
  - `Sources/AlloyHost/Daemon.swift`
  - `Sources/AlloyHost/Bridge.swift`
  - `Sources/AlloyHost/Idle.swift`
  - `Sources/AlloyRemote/Handshake.swift`
- Modify: `Package.swift` (executable `alloy-host` depending on `AlloyRemote` only; no MetalUI, AppKit or AlloyKit).
- Test: `Tests/AlloyRemoteTests/HostDaemonTests.swift`

**Interfaces (Produces):**
```swift
public struct Handshake: Codable, Sendable, Equatable {
    public static let protocolMajor = 1
    public var protocolMajor: Int; public var appVersion: String; public var role: Role
    public enum Role: String, Codable, Sendable { case client, daemon }
}
// CLI:  alloy-host daemon | bridge | stop | --version
// Paths: $ALLOY_HOST_HOME (default ~/.alloy/host)/<appVersion>/host.sock ; dir mode 0700, socket owner-only.
// bridge: connect to the socket (start `daemon` detached via setsid if absent, wait up to 5 s), then pipe stdin/stdout <-> socket.
// stop: sends control "stop" to the daemon; daemon exits 0.
// The daemon never exits on its own (spec: persistent). Idle = no client && nothing running →
//   IdleState.enter(): drop registered caches (Idle.register(_ drop: @Sendable () -> Void)),
//   then malloc_zone_pressure_relief(nil, 0) (macOS) / malloc_trim(0) (Linux).
// Control RPC on channel 0: "ping" → "pong"; "stop".
```

- [ ] **Step 1: Failing tests.** Each one starts the built `alloy-host` with `ALLOY_HOST_HOME` set to a `TempDir` and tracks its PID to kill it in `defer`.
  - `bridgeStartsDaemonAndPings`.
  - `secondBridgeReusesDaemon`: the daemon PID is the same.
  - `bridgeExitDoesNotStopDaemon`.
  - `stopEndsDaemon`.
  - `socketDirIsOwnerOnly`: mode 0700.
  - `handshakeRejectsOtherMajor`: the reply says so and the bridge exits non-zero.
  - `idleDaemonUnder15MB`: after the last bridge closes and Idle is entered, the daemon's resident size (`proc_pid_rusage` or `ps -o rss`) is under 15 MB, and CPU over 2 s is 0.
- [ ] **Step 2:** Run `swift build --product alloy-host && swift test --no-parallel --filter HostDaemonTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Unix socket via POSIX (`socket`, `bind`, `listen`). The daemon detaches with `setsid` here. The launchd and systemd install is Plan 2.
- [ ] **Step 4:** Run with `--filter HostDaemonTests`. Expected: PASS. Append an `alloy-host-idle` line (RSS and CPU) to perf-history.
- [ ] **Step 5:** Commit `feat(host): alloy-host daemon skeleton with bridge, stop and idle state`.

---

## Later plans (outline; each written when its predecessor is merged)

- **Plan 2: Phase 1, connect and remote files (Mac mini).**
  - `RemoteHost`: `HostFileSystem` and `HostProcesses` over the mux, plus a remote `FileChangeSource`.
  - `alloy-host` serving the file system, watcher, index, search and git.
  - The SSH bridge launcher (`ssh -o BatchMode=yes`) with fail-fast dialogs.
  - Install and update over SSH, with SHA-256 checks.
  - The launchd GUI-session agent and the "log in once" fallback.
  - Reconnect with backoff, wake and network-change triggers.
  - Read-only disconnected mode, the banner and autosave pause.
  - The "Connect to Server…" menu item and the remote folder browser.
  - Recents and the window host badge.
  - Takeover with "open on <other Mac>".
- **Plan 3: Phase 2, terminals and agents on the server.**
  - Remote `PtySpawner` with byte-ring replay.
  - Server-side ACP and Claude transports, with sequenced `ProcessEvent` streams.
  - `ACPFileHandling` forwarding, plus the detached disk mode with a while-away log.
  - Pending permission prompts.
  - stdio MCP and command hooks over the Unix socket.
  - The Stop Server Sessions and Stop Server commands.
- **Plan 4: Phase 3, language servers on the server.** Remote `ServerLauncher` over a mux channel, server-side `ServerLocator`, and a restart on reconnect.
- **Plan 5: Phase 4, Linux server.**
  - inotify `FileChangeSource`.
  - POSIX listener, replacing `Network` in AlloyCore's host path.
  - swift-crypto or a small SHA-256 in place of CryptoKit.
  - Darwin guards.
  - systemd `--user` unit with an offer to enable linger.
  - Static Linux SDK cross-builds bundled in Alloy.app.

Plans 2 to 5 parallelise the same way as this one: one foundation task, then disjoint tracks.
