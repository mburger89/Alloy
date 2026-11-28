# Remote Workspaces — Plan 2: Connect and Remote Files (Phase 1, Mac mini) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From the laptop, open a project that lives on a Mac server over SSH. You can edit, save, browse, search and use git there. You get a "reconnecting…" read-only window when the link drops, and a takeover notice when another Mac opens the same project.

**Architecture:**
- **Daemon:** `alloy-host` (Plan 1 skeleton) gains RPC services. They serve the server's `LocalFileSystem` and `LocalProcesses`, a file watcher, and a search engine over the mux. Small calls are JSON-RPC on channel 1; file bytes go on a blob channel (channel 2).
- **Client:** the app spawns `ssh <alias> …/alloy-host bridge` and wraps it as `RemoteHost: ProjectHost`, the Plan 1 seam. It hands that host to `Workspace(host:)`.
- **Connection life:** a connection manager reconnects with backoff. The workspace goes read-only while disconnected.
- **UI:** a Connect window, recents, a title badge and a window banner.

**Tech Stack:** Swift 6, Swift Testing, Foundation, POSIX, `/usr/bin/ssh`, launchd (server side), AlloyRemote (`Mux`, `ReplayRing`, `Handshake`) and AlloyRPC (`JSONRPCConnection`).

**Spec:** `docs/superpowers/specs/2026-11-27-remote-workspaces-design.md`, sections 1–3 and 7, phases 1. Builds on Plan 1, `docs/superpowers/plans/2026-11-27-remote-plan-1-host-seam-and-wire.md`, which is merged on `release/0.2`.

## Parallel layout

```
P0a mux close-ack + socket fix + content-hash version ─┐
P0c host-path URL helper + guard pattern ──────────────┤
P0b RPC schema + blob channel ─────────────────────────┤
                                                       ├─ D1 daemon fs/proc/info/attach ─┐
                                                       ├─ D2 daemon watch + search ──────┤
                                                       ├─ C1 ssh link + installer ───────┼─ C2 RemoteHost + conformance ─┬─ C3 connection manager ─┬─ C4 workspace offline + takeover ─┐
                                                       ├─ K1 bundle + launchd + stop ────┘                               │                         └─ U2 window wiring + banner + gating ┴─ F end-to-end + acceptance
                                                       └─ U1 connect window + recents + remote arg (fakes only) ────────┘
```

- **P0a, P0b and P0c** run in parallel; they touch different files.
- **D1, D2, C1, K1 and U1** run in parallel once both P0s merge.
- **C2** needs D1, D2 and C1.
- **C3** needs C2.
- **C4 and U2** run in parallel after C3.
- **F** is last.
- Every merge into `release/0.2` is followed by `swift build --build-tests` before the next dispatch. That is a Plan 1 lesson.

## Global Constraints

- **Plan 1 rules all carry over.**
  - Local projects behave and perform exactly as today.
  - There are no silent local fallbacks: no `= LocalHost()` or `fs: … = nil` defaults on production parameters.
  - No new `await` between a guard and its state on the local path.
  - Shared `HostFileSystem` contracts are only added to, never changed.
  - The A8 boundary guard stays green.
- **Spec:** "No TCP port is opened on the server, not even loopback." The daemon is reachable only over ssh plus its 0700 Unix socket.
- **Spec:** "Alloy stores any key, password or token in a file or in plaintext" is an anti-goal. SSH sign-in is handled by ssh, ssh-agent, the Keychain and Tailscale SSH. Alloy stores only host aliases.
- **Spec:** v1 is key-based sign-in only. Alloy always runs `ssh -o BatchMode=yes`. Password or 2FA prompts and unknown or changed host keys fail fast with a dialog; nothing hangs on a hidden prompt.
- **Spec:** the daemon is persistent and never exits on its own. It stops only on Stop Server or `alloy-host stop`. On macOS it is a launchd agent in the user's GUI session with `KeepAlive`. When idle it stays under 15 MB resident at 0% CPU.
- **Spec:** "There's no unbounded buffering anywhere on either side."
- **Spec:** the window is read-only while disconnected. The chat composer drafts are kept but Send is disabled. Autosave pauses. Unsaved edits are kept in memory and saved on reconnect, going through the outside-edit conflict flow if the disk changed.
- **Spec:** only one client is attached to a project at a time. A second connection takes over, and the first Mac goes read-only with "This project is open on <other Mac>".
- **Spec:** shared store on the host. `ui-state.json` is per Mac. Notes and the read index stay in the laptop-local KnowledgePool (user decision, 2026-11-28).
- **Phase 1 scope:** a remote window has no agents, terminals, language servers or plugin processes. Those arrive in Plans 3 and 4. Until then they are disabled in remote windows, so nothing runs on the laptop against remote paths.
- **Server platform:** macOS arm64 only (Plan 5 adds Linux). Any other `uname -sm` gets "This server isn't supported yet (<uname>)".
- **Test rules:**
  - Tests never write the real `~/.alloy`, `~/.ssh` or `~/Library/LaunchAgents`. Set `ALLOY_HOST_HOME` and `ALLOY_SSH` to a fake ssh, and `ALLOY_HOST_LAUNCHD=0`.
  - Kill only PIDs you started.
  - Run with `--no-parallel`, and use `TempFiles`/`TempDir`.
  - Never raise timeouts or guards.
- **MetalUI** is read-only. Forward any gap to the MetalUI session.
- **Worktrees** go in the shared `worktrees/alloy/<task>` folder. Commits end with the session's attribution trailers.

## Review Focus

1. **A dropped connection during a save never marks the document saved.** The save errors, the edit is kept, and it is retried after reconnect. Tested in C4 `dropDuringSaveKeepsTheEdit`.
2. **Hostile or odd aliases and paths reach ssh as data, never as options or shell code.** For example an alias starting with `-`, or paths with spaces, quotes, unicode or `$(…)`. Tested in C1 `aliasAndPathAreNeverOptionsOrShell` and U1 `remoteArgumentRoundTripsOddPaths`.
3. **After the laptop sleeps for hours, the watcher's replay ring has overflowed.** The client gets a "rescan root" and the tree and open documents re-sync. Tested in D2 `watchGapBecomesRootRescan` and C3 `resumeAfterGapRescans`.
4. **Takeover while the first Mac sleeps.** When the first Mac wakes, it sees "open on <other Mac>", goes read-only, and never writes stale state. Tested in C4 `takenOverClientNeverWrites`.
5. **A remote window launches nothing on the laptop.** No agent, terminal, LSP or plugin process starts for a remote window. Tested in F `remoteWindowSpawnsNothingLocally`.

---

### Task P0a: Mux close-ack, socket path safety, content-hash version

**Files:**
- Modify: `Sources/AlloyRemote/Mux.swift`, `Sources/AlloyRemote/HostSocket.swift`
- Test: `Tests/AlloyRemoteTests/MuxTests.swift`, `Tests/AlloyRemoteTests/HostSocketTests.swift`

**Interfaces (Produces):**
- **Close-ack.** A channel closed locally that never sent data is reclaimed once the peer acknowledges. The fix is a close-ack control frame: a 5-byte payload of channel ID plus 1 byte. The peer acks every close it receives, including closes for unknown IDs, and acks are never themselves acked. So `open(id)` after `close()` works whether or not data flowed. This is a Plan 1 final-review item.
- **`UnixSocket.withAddress` no longer changes directory.** It used a process-wide `chdir`, which is unsafe in the multi-threaded app.
  - `UnixSocket.listen`/`connect` throw `HostSocketError.pathTooLong` for paths of 104 bytes or more.
  - `HostPaths` guarantees short paths: when `<home>/<version>/host.sock` is too long, it falls back to `/tmp/alloy-host-<uid>/<version-prefix-12>.sock` in a 0700 directory owned by the user. The directory's owner and mode are verified before use.
- **`HostPaths.version` is a content hash.** It is the first 16 hex characters of the SHA-256 of the running `alloy-host` binary (`Bundle.main.executablePath`), computed once. The `ALLOY_HOST_APP_VERSION` environment variable still overrides it, for tests. `Handshake.appVersion` carries it.
- **Stable layout, so a newer app attaches to an older running daemon** (spec: "A newer laptop app attaches to an older daemon whenever the protocol major matches … The daemon binary is replaced only when it has nothing running … re-execs into the new binary"):
  - The binaries live in `<home>/<version>/alloy-host`.
  - The socket is `<home>/host.sock`. It is no longer per version.
  - The pid and lock files are `<home>/daemon.pid` and `<home>/daemon.lock`.
  - `<home>/current` is a symlink to the version directory that should run.
  - New helpers: `HostPaths.current(home:)` and `HostPaths.setCurrent(version:home:) throws`, which swaps the symlink atomically via a temp link plus `rename`.
  - The bridge of any version relays to whatever daemon is listening.
- **Plan 1 final review: wire decisions to settle before protocol major 1 freezes:**
  - **Channel IDs are never reused.** Use monotonic IDs, with odd IDs opened by the client and even IDs by the daemon. Channels 0, 1 and 2 are reserved. Plan 3's dynamic pty and agent channels need this anyway. A close-ack only frees state, so a late close can never hit a reopened channel.
  - **Control frames are typed.** A type byte first: 1 = grant, 2 = close, 3 = close-ack. Control frames no longer rely on payload length. An unknown type is a protocol violation, never silently ignored.
  - **`close()` and `failAll` clear `handles`.** That fixes the retain cycle that leaks one Mux per reconnect in the persistent daemon.
  - **`onClose` carries a reason** (`MuxCloseReason`: clean, decode error, protocol violation, send failure), so C3 can choose between reconnecting and failing.
  - **The daemon closes a connection's fd only after the FDReader thread has ended** (its `onEnd`). That closes the read-side fd-reuse window.
  - **Single consumer per channel stream** is documented, and a second iterator is a precondition failure.
- **Pending Plan 1 minors that live in these lines:**
  - cap `pendingGrants` at 4096 frames, with a protocol violation past that;
  - add `onClose` coverage via `failAll` with a test.

- [ ] **Step 1: Write failing tests.**
  - `channelIDsAreNeverReused`
  - `lateCloseNeverHitsAReopenedChannel`
  - `unknownControlTypeFailsMux`
  - `closeReleasesHandles`: a weak reference to a channel is nil after `close()`.
  - `onCloseCarriesReason`
  - `fdClosedOnlyAfterReaderEnds`
  - `socketIsVersionIndependent`
  - `setCurrentSwapsAtomically`
  - `localCloseWithoutDataIsReclaimedAfterAck`
  - `idReopensAfterCloseWithNoData`
  - `ackIsNeverAcked`, which counts frames to show there is no ping-pong
  - `pendingGrantsCapFailsMux`
  - `failAllRunsOnClose`
  - `longSocketPathFallsBackToShortTmp`, which checks mode 0700 and the owner
  - `pathTooLongThrows`
  - `withAddressNeverChangesCwd`, which records `getcwd` before and after on a background thread while another thread calls `connect`
  - `versionIsContentHashOfBinary`, which hashes a temp copy of the built `alloy-host`
- [ ] **Step 2:** run `swift test --no-parallel --filter 'MuxTests|HostSocketTests'`. Expected: FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** run `swift test --no-parallel --filter 'AlloyRemoteTests'`. Expected: PASS, with the existing daemon tests unchanged.
- [ ] **Step 5:** commit `feat(remote): close-ack, chdir-free sockets, content-hash version`.

### Task P0b: RPC schema and blob channel

**Files:**
- Create: `Sources/AlloyRemote/HostRPC.swift`, `Sources/AlloyRemote/Blob.swift`
- Modify: `Sources/AlloyCore/Host/ProjectHost.swift` and `HostTypes.swift`, to add `Codable` to `HostDirEntry`, `HostPathKind`, `HostRun`, `EditorFileRead` and `ReplaceOutcome`
- Test: `Tests/AlloyRemoteTests/HostRPCTests.swift`, `BlobTests.swift`

**Interfaces (Produces).** This is the single wire contract that D1, D2, C2 and C3 build on.
```swift
public enum HostRPC {
    public static let blobChannel: UInt32 = 2          // binary only; channel 1 = JSON-RPC (Handshake.controlChannel)
    public enum Method: String, Codable, Sendable, CaseIterable {
        // info / session
        case hello = "host.hello"              // HelloParams → HelloResult
        case attach = "project.attach"         // AttachParams → AttachResult
        // fs (HostFileSystem 1:1)
        case readForEditing = "fs.readForEditing", read = "fs.read", readBytes = "fs.readBytes",
             existingFiles = "fs.existingFiles", walkFiles = "fs.walkFiles", stamp = "fs.stamp", lstamp = "fs.lstamp",
             replaceAtomically = "fs.replaceAtomically", write = "fs.write", append = "fs.append", list = "fs.list",
             kind = "fs.kind", isExecutable = "fs.isExecutable", remove = "fs.remove", move = "fs.move",
             createDirectory = "fs.createDirectory", realpath = "fs.realpath"
        // processes
        case loginPATH = "proc.loginPATH", locate = "proc.locate", run = "proc.run", git = "proc.git"
        // streams
        case watch = "watch.start", watchAck = "watch.ack", watchResume = "watch.resume", watchStop = "watch.stop"
        case search = "search.start", searchCancel = "search.cancel"
        // lifecycle
        case stop = "stop", ping = "ping", upgrade = "host.upgrade"   // UpgradeParams → UpgradeResult
    }
    public enum Notification: String, Codable, Sendable {
        case watchBatch = "watch.batch"        // WatchBatch
        case searchBatch = "search.batch"      // SearchBatchMessage
        case takenOver = "project.takenOver"   // TakenOver
    }
    public struct HelloParams: Codable, Sendable { public var clientID: UUID; public var clientName: String }   // clientName = Mac's computer name
    public struct HelloResult: Codable, Sendable { public var home: String; public var storeRoot: String; public var os: String; public var arch: String; public var version: String; public var agentsAvailable: Bool }  // agentsAvailable: running as a launchd GUI-session agent
    public struct UpgradeParams: Codable, Sendable { public var version: String }   // a version dir already installed under <home>
    public struct UpgradeResult: Codable, Sendable { public var state: String }     // "now" (idle: current repointed, daemon exits; launchd restarts it) | "deferred" (busy: done when work reaches 0) | "same"
    public struct AttachParams: Codable, Sendable { public var root: String }
    public struct AttachResult: Codable, Sendable { public var takenOverFrom: String? }   // previous client's name, if any
    public struct TakenOver: Codable, Sendable { public var root: String; public var by: String }
    public struct BlobRef: Codable, Sendable, Equatable { public var id: UInt64; public var size: Int }
    public struct WatchBatch: Codable, Sendable { public var watchID: UInt64; public var seq: UInt64; public var paths: [String] }   // "<root>/" = rescan
    public struct SearchBatchMessage: Codable, Sendable { public var searchID: UInt64; public var batch: SearchBatch }  // SearchBatch made Codable here
    // One Params/Result struct per Method, named <Method>Params / <Method>Result, fields = the HostFileSystem/HostProcesses
    // signature's parameters/return; every Data-typed field is a BlobRef instead.
    public enum ErrorCode: Int { case hostUnavailable = -33001, blobMissing = -33002, notAttached = -33003, takenOver = -33004 }
}

/// Blob framing on channel 2: [u64 id BE][u32 length BE][bytes], a blob split across Frame.maxPayload chunks and reassembled.
public actor BlobStore {
    public init(cap: Int = 64 << 20)                          // outstanding (sent-not-claimed + received-not-claimed) bytes
    public func send(_ data: Data, over channel: MuxChannel) async throws -> BlobRef
    public func receive(from channel: MuxChannel)            // runs the reassembly loop; past `cap` → MuxError.protocolViolation
    public func claim(_ ref: BlobRef, timeout: Double = 30) async throws -> Data   // throws HostRPCError.blobMissing on timeout
}
```

**Plan 1 final review: throughput.**
- The handshake carries the receive window: `Handshake.window`, default 256 KiB for channel 1 and 4 MiB for the blob channel.
- Grants are coalesced: send one when at least half the window has been consumed, not one per frame.
- Any result that can be large (`walkFiles`, `existingFiles` and `list` with more than 1,000 entries, plus every `run`/`git` stdout and stderr) travels as a blob, so a multi-MB answer never blocks small calls on channel 1.
- Process output is always raw bytes. Fixes A4's `cat-file blob` note.

- [ ] **Step 1: Write failing tests.**
  - `largeListResultTravelsAsBlobAndSmallCallsAreNotBlocked`
  - `grantsAreCoalesced`
  - `windowNegotiatedInHandshake`
  - `everyMethodHasParamsAndResultRoundTrip`: one JSON round trip per `Method` case.
  - `searchBatchIsCodable`
  - `blobRoundTripsAcrossChunks`: a 5 MiB blob over a mux pair.
  - `blobsInterleaveByID`
  - `blobOverCapFailsConnection`
  - `unclaimedBlobTimesOut`
  - `emptyBlob`
- [ ] **Step 2:** run `swift test --no-parallel --filter 'HostRPCTests|BlobTests'`. Expected: FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** run the same command. Expected: PASS. Run `swift build --build-tests`.
- [ ] **Step 5:** commit `feat(remote): host RPC schema and blob channel`.

### Task P0c: Host-path URL helper and guard pattern (Plan 1 final review I3)

**Files:**
- Create: `Sources/AlloyCore/Host/HostPathURL.swift`
- Modify: every remote-branch site in the list below, plus `Tests/AlloyCoreTests/HostBoundaryGuardTests.swift`
- Test: the guard itself, plus `HostPathURLTests`

**Interfaces (Produces):**
- **The constructors:** `URL.hostPath(_ path: String, isDirectory: Bool = false) -> URL` and `URL.appendingHostPath(_ component: String, isDirectory: Bool = false) -> URL`. They are built on `URL(filePath:directoryHint:)` and `appending(path:directoryHint:)`, so they never stat. Every URL built from a path that may be remote uses them.
- **The guard pattern:** `URL(fileURLWithPath:` and `.appendingPathComponent(` count as boundary hits and need a `// host-local:` marker. Sites that are fully lexical and app-local are allowlisted with a reason.
- **Sites to convert,** from the review:
  - `NotesTools.swift:83,89,499,504`
  - `GitBaseline.swift:82,187`
  - `TerminalManager.swift:172,175`
  - `TerminalPanelStore.swift:173`
  - `SharedContext.swift:146`
  - `KnowledgeScope.swift:22` (the remote arm)
  - `OutsideEdits.swift:178`
  - `PluginCoordinator+Tasks.swift:71`
  - `LSPManager.swift:1084`
  - `ConfigProbe.swift:50`
  - `ServerRegistry.swift:246-247`
  - `LinkDetector.swift:107,112`
  - `CodeActionService.swift:170`
  - `ACPHistory.swift:17`
  - `Workspace.swift:2547,2588`
  - `hostResolved` in Workspace+Panes

  Grep the tree for each, since line numbers may have moved. Local branches keep today's calls under a marker.

- [ ] **Step 1:** add the pattern. Run the guard. Expected: FAIL, listing the sites.
- [ ] **Step 2:** write `HostPathURLTests`. `hostPathNeverStats`: build a URL for a path under `/private/tmp` that exists, and assert `hasDirectoryPath` follows only the hint.
- [ ] **Step 3:** convert the sites.
- [ ] **Step 4:** run the guard and `--filter 'AlloyCoreTests|AlloyKitTests'`. Expected: PASS, with local behaviour unchanged. Re-run the 4 perf suites.
- [ ] **Step 5:** commit `refactor(host): stat-free URLs for host paths and a guard pattern for them`.

P0c runs alongside P0a and P0b, since it touches different files. C2 depends on it.

### Task D1: Daemon fs, processes, hello, attach and takeover

**Files:**
- Create:
  - `Sources/AlloyHost/Services/FSService.swift`
  - `Sources/AlloyHost/Services/ProcService.swift`
  - `Sources/AlloyHost/Services/Projects.swift`
- Modify: `Sources/AlloyHost/Daemon.swift` (route RPC methods; open the blob channel), `Package.swift` (AlloyHost may depend on AlloyCore for `LocalFileSystem` and `LocalProcesses`)
- Test: `Tests/AlloyRemoteTests/HostServicesTests.swift`

**Interfaces:**
- **Consumes:** P0b `HostRPC` and `BlobStore`. P0a version.
- **Produces:** the daemon answers every `fs.*`, `proc.*`, `host.hello` and `project.attach` method by calling `LocalFileSystem` and `LocalProcesses` on the server.
  - `storeRoot` is `<ALLOY_HOST_HOME>/projects`.
  - `Projects` maps a root to its current client ID. `attach` from a different client records the new owner, sends `project.takenOver` to the previous client's connection, and returns `takenOverFrom`.
  - Any `fs` write method from a client that isn't the current owner of the root it touches fails with `ErrorCode.takenOver`. This guards against stale writes after a takeover.
  - **`host.upgrade {version}`:**
    - The same version answers `"same"`.
    - If `Idle` has no work, it calls `HostPaths.setCurrent`, replies `"now"`, then exits 0. launchd's KeepAlive starts `current`. Without launchd, the next bridge spawns it.
    - Otherwise it replies `"deferred"`, and performs the switch when the work count reaches 0.
    - It refuses versions whose directory or binary is missing.
  - The daemon marks work in `Idle` while requests are in flight. `Idle.enter` runs under the lock.
  - **Writes and concurrency (Plan 1 final review I6):**
    - Each connection gets one writer thread with a bounded queue (16 MiB). The Mux `send` closure enqueues; it never does a blocking `fdWriteAll` on a cooperative-pool thread.
    - fs RPCs run on a dedicated bounded executor (8 concurrent), not the cooperative pool.
    - The handshake read gets a 10 s timeout.
  - The daemon holds no per-project caches yet.

- [ ] **Step 1: Write failing tests.** Each spawns the built daemon with a temp `ALLOY_HOST_HOME`, connects over its socket and performs the handshake, the same way the existing HostDaemonTests do.
  - `everyFSMethodMatchesLocalFileSystem`: the same calls go to the daemon and to `LocalFileSystem` on a temp tree, and the results must be equal.
  - `replaceAtomicallyThroughDaemonKeepsModeAndDetectsMove`
  - `readOfFifoReturnsNilWithoutBlocking`
  - `gitThroughDaemon`
  - `helloReportsHomeStoreAndVersion`
  - `secondClientAttachTakesOverAndNotifiesFirst`
  - `writeFromTakenOverClientIsRefused`
  - `idleMarkerReturnsAfterRequests`
  - `upgradeWhenIdleSwitchesCurrentAndExits`
  - `upgradeWhenBusyDefers`
  - `upgradeToMissingVersionRefused`
  - `slowReaderDoesNotStallOtherConnections`
  - `handshakeTimesOut`
- [ ] **Step 2:** run `swift build --product alloy-host && swift test --no-parallel --filter HostServicesTests`. Expected: FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** run the same command, then `--filter AlloyRemoteTests`. Expected: PASS.
- [ ] **Step 5:** commit `feat(host): serve fs, processes, hello and project attach`.

### Task D2: Daemon watch and search

**Files:**
- Create: `Sources/AlloyHost/Services/WatchService.swift`, `Sources/AlloyHost/Services/SearchService.swift`
- Modify: `Sources/AlloyHost/Daemon.swift`, plus a `SearchBatch` Codable extension if P0b left it out
- Test: `Tests/AlloyRemoteTests/HostStreamsTests.swift`

**Interfaces:**
- **Consumes:** P0b. `FSEventsSource` and `SearchEngine` from AlloyCore.
- **Produces:**
  - **`watch.start {root}`** returns `{watchID}`. It then streams `watch.batch` notifications. Each watch has a `ReplayRing(byteCap: 1 << 20)`. The client sends `watch.ack {watchID, through}`. `watch.resume {watchID, after}` replays the batches after `after`. If the ring has dropped them (`gapTooLarge`), it sends one batch `[root + "/"]`, meaning rescan.
  - **Restart epochs (Plan 1 final review I5):** each watch has an `epoch`, a random UInt64 picked per watch. `watch.start` returns `{watchID, epoch}`, and `watch.resume {watchID, epoch, after}`:
    - An unknown watchID or a different epoch (after a daemon restart or re-exec) is answered with a rescan batch.
    - `ReplayRing.resume(after:)` reports `gapTooLarge` when `after > lastSeq`. That's a Plan 1 fix in this task.
  - **Watch lifetime:** watches stop when no client has the root attached for 60 s. That uses a one-shot timer per detach, which the spec allows ("no timers beyond that one"). The ring is freed then.
  - **`search.start`** has fields `{root, query: SearchQuery, paths, exclude, indexTruncated, maxResults}`. It returns `{searchID}` and streams `search.batch` until a batch has `finished == true`. `search.cancel` stops it. The engine runs on the server through `SearchEngine(root:fs: LocalFileSystem())`.

- [ ] **Step 1: Write failing tests.**
  - `watchStreamsBatchesForTouchedFiles`
  - `watchResumeReplaysAfterSeq`
  - `watchGapBecomesRootRescan`: overflow the ring, then resume from an old seq.
  - `resumeAcrossDaemonRestartRescans`: same watchID, different epoch.
  - `resumeAheadOfLastSeqIsAGap`
  - `watchStopsAfterDetachGrace`, with an injectable grace, 0.2 s in tests.
  - `searchStreamsBatchesAndFinishes`
  - `searchCancelStopsWork`
  - `searchExcludesGivenPaths`
- [ ] **Step 2:** run `swift build --product alloy-host && swift test --no-parallel --filter HostStreamsTests`. Expected: FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** run the same command. Expected: PASS.
- [ ] **Step 5:** commit `feat(host): watch and search streams`.

### Task C1: SSH link and installer

**Files:**
- Create: `Sources/AlloyRemote/SSHLink.swift`, `Sources/AlloyRemote/HostInstaller.swift`
- Create: `Tests/AlloyRemoteTests/Support/fake-ssh`, an executable script. It ignores ssh options, takes the alias, and runs the remote command with `sh -c` locally, with `HOME` set to `$FAKE_SSH_HOME`.
- Test: `Tests/AlloyRemoteTests/SSHLinkTests.swift`, `HostInstallerTests.swift`

**Interfaces:**
- **Consumes:** P0a (version, Handshake) and P0b (`BlobStore`, channel IDs).
- **Produces:**
```swift
public struct SSHTarget: Sendable, Hashable, Codable {       // validated: alias nonempty, no leading "-", no whitespace/control chars
    public let alias: String
    public init(_ alias: String) throws                       // throws SSHError.badAlias
}
public enum SSHError: Error, Equatable, Sendable {
    case badAlias, authFailed(String), hostKey(String), unreachable(String), notInstalled, unsupported(String),
         versionMismatch(String), bridgeRefused(String), exited(Int32, String)
}
public final class SSHLink: Sendable {                        // one live connection
    /// argv: [ssh, "-T", "-o","BatchMode=yes", "-o","ServerAliveInterval=15", "-o","ServerAliveCountMax=3",
    ///        "-o","ConnectTimeout=10", "--", alias, remoteCommand]; ssh = $ALLOY_SSH ?? "/usr/bin/ssh".
    public static func open(_ target: SSHTarget, remoteBinary: String, clientID: UUID, clientName: String) async throws -> SSHLink
    public var rpc: JSONRPCConnection { get }                 // channel 1
    public var blobs: BlobStore { get }                       // channel 2
    public var hello: HostRPC.HelloResult { get }
    public var closed: AsyncStream<SSHError?> { get }         // one element when the link ends (nil = clean)
    public func close() async
}
public enum HostInstaller {
    /// One ssh probe: `uname -sm` + `test -x <bin> && <bin> --version`; installs if missing: upload over the same ssh
    /// (`umask 077; mkdir -p <dir> && cat > <dir>/.alloy-host.tmp`), verify `shasum -a 256`, `chmod 0755`, `mv`.
    /// Remote dir = ~/.alloy/host/<version>/ ; version = HostPaths.version of `localBinary`.
    public static func ensureInstalled(_ target: SSHTarget, localBinary: URL) async throws -> String   // returns remote binary path
}
// After SSHLink.open: if hello.version != local version (protocol major already matched in the handshake), send
// host.upgrade(local version). "now" → reconnect once; "deferred" → keep using the running (older, compatible) daemon.
// A protocol-major mismatch → SSHError.versionMismatch ("N sessions… are running on the old server" wording arrives in Plan 3).
```
- **Error classification:** ssh exits 255 and its stderr says why.
  - "Permission denied" → `authFailed`
  - "Host key verification failed" or "REMOTE HOST IDENTIFICATION HAS CHANGED" → `hostKey`, with the fingerprint line kept
  - "Could not resolve", "Connection refused" or "timed out" → `unreachable`
  - exit 127 → `notInstalled`
  - the uname isn't `Darwin arm64` → `unsupported(uname)`
- **Shell safety:** the remote command is built only from the validated version and fixed strings. User paths never enter the remote shell command. Paths only travel inside RPC JSON.

- [ ] **Step 1: Write failing tests.** All of them use fake-ssh, a temp `FAKE_SSH_HOME` and the built `alloy-host`.
  - `openPerformsHandshakeAndHello`
  - `authFailureIsClassified`: fake-ssh with `FAKE_SSH_FAIL=auth` prints "Permission denied (publickey)." and exits 255.
  - `hostKeyFailureKeepsFingerprint`
  - `unreachableIsClassified`
  - `aliasAndPathAreNeverOptionsOrShell`: aliases `-oProxyCommand=x` and `a b` are rejected by `SSHTarget.init`. A project path `/tmp/x'; touch /tmp/pwn; '` is only ever used in RPC, and the test asserts `/tmp/pwn` never appears.
  - `installerUploadsVerifiesAndReuses`: the first call uploads, the second reuses, and a hash mismatch fails.
  - `unsupportedPlatformIsReported`: fake uname output is `Linux x86_64`.
  - `linkClosedStreamReportsExit`
  - `newerAppAttachesToOlderCompatibleDaemonAndUpgradesWhenIdle`
- [ ] **Step 2:** run `swift build --product alloy-host && swift test --no-parallel --filter 'SSHLinkTests|HostInstallerTests'`. Expected: FAIL.
- [ ] **Step 3:** implement. The ssh child follows `ServerProcess`'s pipe and exit handling. Read the handshake reply line before starting the `Mux`.
- [ ] **Step 4:** run the same command. Expected: PASS.
- [ ] **Step 5:** commit `feat(remote): ssh link and host installer`.

### Task K1: Bundle `alloy-host`, launchd agent, Stop Server

**Files:**
- Modify: `scripts/bundle-macos.sh`, `scripts/release-macos.sh` (verify the helper is signed)
- Create: `Sources/AlloyHost/LaunchAgent.swift`
- Modify: `Sources/AlloyHost/Bridge.swift`, `Sources/AlloyHost/main.swift`
- Test: `Tests/AlloyRemoteTests/LaunchAgentTests.swift`, `Tests/ReleaseScriptTests/*` (helper present and signed)

**Interfaces (Produces):**
- **Bundling:** `Alloy.app/Contents/Helpers/alloy-host`. It is built with `swift build -c release --arch arm64 --product alloy-host`, build rpaths are stripped, and it is signed with Developer ID and hardened runtime before the app. A dry run signs it ad hoc.
- **Lookup:** `HostInstaller`'s `localBinary` comes from `Bundle.main.url(forAuxiliaryExecutable: "alloy-host")`, falling back to `.build/<config>/alloy-host` in dev builds.
- **Launchd plist:** `LaunchAgent.plist(home:) -> Data` builds label `dev.alloy.host`, which is version-independent. ProgramArguments are `[<home>/current/alloy-host, "daemon"]`, with KeepAlive true and RunAtLoad true.
- **`bridge`:** if the socket is absent and `ALLOY_HOST_LAUNCHD` isn't `0` and a GUI session exists (`launchctl print gui/<uid>` succeeds), it writes the plist to `~/Library/LaunchAgents/` and runs `launchctl bootstrap gui/<uid> <plist>`. Otherwise it falls back to today's setsid spawn.
- **`stop`:** runs `launchctl bootout gui/<uid>/dev.alloy.host` when that label is loaded, so KeepAlive can't restart the daemon. Then it stops the daemon as today.
- **When the daemon isn't launchd-started:** D1 reports that through `host.hello` as `HelloResult.agentsAvailable == false`. K1 supplies the check `LaunchAgent.isRunningUnderLaunchd() -> Bool`. The client uses it later to show "Log in at <host> once to enable agents" (Plan 3). Here it is only reported.

- [ ] **Step 1: Write failing tests.**
  - `plistHasKeepAliveAndArgs`
  - `bridgeFallsBackToSetsidWhenLaunchdDisabled`
  - `stopBootsOutWhenAgentLoaded`: launchctl is injected as a fake command via `ALLOY_LAUNCHCTL`.
  - Release script test: `bundleContainsSignedHelper`, using the dry run.
- [ ] **Step 2:** run `swift test --no-parallel --filter 'LaunchAgentTests|ReleaseScriptTests'`. Expected: FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** run the same command, then `scripts/release-macos.sh 0.0.1 --dry-run`. Expected: `Contents/Helpers/alloy-host` exists and `codesign --verify` passes. Delete the dry-run output afterwards.
- [ ] **Step 5:** commit `feat(host): bundle alloy-host, launchd agent, stop boots out`.

### Task U1: Connect window, ssh-config hosts, recents, remote launch argument

**Files:**
- Create: `Sources/AlloyCore/Model/RemoteTarget.swift`, `Sources/AlloyCore/Model/SSHConfigHosts.swift`, `Sources/AlloyKit/Remote/ConnectWindow.swift`
- Modify:
  - `Sources/AlloyCore/Model/ProjectChoice.swift`
  - `Sources/AlloyCore/Model/AlloySettings.swift` (`recentProjects`)
  - `Sources/AlloyKit/LauncherView.swift` (recents in `ChooseProjectView`)
  - `Sources/AlloyKit/Commands/BuiltinCommands.swift`
- Test: `Tests/AlloyCoreTests/RemoteTargetTests.swift`, `Tests/AlloyKitTests/ConnectWindowTests.swift`

**Interfaces:**
- **Consumes:** nothing from the remote tasks. The connect window uses a protocol that U2 fills with the real link:
```swift
public struct RemoteTarget: Hashable, Codable, Sendable { public var alias: String; public var path: String }
extension RemoteTarget {
    public var argument: String                         // "alloy-remote://<alias-percent-encoded><path-percent-encoded>"
    public init?(argument: String)
}
public enum ProjectChoice { case open(root: URL, file: String?), openRemote(RemoteTarget), askUser }   // resolveDetailed parses the remote form first
public enum SSHConfigHosts { public static func parse(_ text: String) -> [String] }  // Host lines; skips wildcard/negated patterns; Include not followed
public struct RecentProject: Codable, Hashable, Sendable { public var local: String?; public var remote: RemoteTarget?; public var opened: Date }
// AlloySettings.recentProjects: [RecentProject], newest first, max 12, decodeIfPresent
@MainActor public protocol RemoteBrowsing: AnyObject {    // U2 provides the live one over SSHLink+RemoteHost
    func connect(alias: String) async throws -> String   // returns remote home path
    func list(_ path: String) async throws -> [HostDirEntry]
}
```
- **The command:** `file.connect`, "Connect to Server…", shortcut ⌃⌘K, on the File menu with `menuID: "file-connect"` and `enabled: { true }`. It opens `ConnectWindow`.
- **The window:**
  - **Hosts:** a host list from `~/.ssh/config` plus the aliases from `recentProjects`, and a free-text field for `user@host` or a Tailscale name.
  - **Connecting:** Connect shows progress, then a folder browser starting at the remote home.
  - **Browser:** double-click enters a folder, the path bar goes up, and "Open" opens the selected folder.
  - **Opening:** Open launches a new Alloy process with `RemoteTarget.argument`, as `openOutsideProject` does with a path.
  - **Errors:** each `SSHError` case gets a sentence. Key setup errors point to the README. The host-key message shows the fingerprint and an "Open Terminal" button that runs `ssh <alias>` in Terminal.app.
- **Recents:** `ChooseProjectView` lists recents with remote ones marked with a server icon. Both local and remote opens record a recent entry.

- [ ] **Step 1: Write failing tests.**
  - `remoteArgumentRoundTripsOddPaths`: spaces, quotes, unicode, `#`, `%`, `?`, and a leading `-` in the path.
  - `projectChoiceParsesRemoteArgument`
  - `sshConfigParsesHostsSkipsWildcards`
  - `recentsCapAndOrder`
  - `connectWindowListsHostsAndBrowses`: a fake `RemoteBrowsing` and a headless `TestWindow`.
  - `connectWindowShowsHostKeyFingerprint`
  - `connectCommandWorksWithoutWorkspace`
- [ ] **Step 2:** run `swift test --no-parallel --filter 'RemoteTargetTests|ConnectWindowTests'`. Expected: FAIL.
- [ ] **Step 3:** implement. For layout, follow `SettingsWindow`'s `app.openWindow` pattern. Use the existing palette styling.
- [ ] **Step 4:** run the same command, then `--filter AlloyKitTests`. Expected: PASS.
- [ ] **Step 5:** commit `feat(remote): connect window, ssh-config hosts, recents, remote argument`.

### Task C2: RemoteHost and host conformance suite

**Files:**
- Create: `Sources/AlloyRemote/RemoteHost.swift`, `Tests/AlloyRemoteTests/HostConformanceTests.swift`
- Modify: `Sources/AlloyCore/Host/ProjectHost.swift` (add search), `LocalHost.swift`, `Sources/AlloyTestSupport/TranslatingHost.swift`, `Sources/AlloyCore/Model/Workspace+Search.swift`

**Interfaces:**
- **Consumes:** C1's `SSHLink`, D1, D2, P0b and P0c. Every URL built from a host path uses P0c's helpers.
- `RemoteFileSystem.isLocal` and `RemoteProcesses.isLocal` are false. The Plan 1 fix wave added `isLocal` to both protocols, and every local/remote predicate derives from it.
- **Produces:**
```swift
// ProjectHost gains (additive; LocalHost runs today's SearchEngine; TranslatingHost translates):
func search(root: URL, query: SearchQuery, paths: [String], exclude: [String], indexTruncated: Bool, maxResults: Int) -> AsyncStream<SearchBatch>

public final class RemoteHost: ProjectHost {
    public init(target: SSHTarget, link: SSHLink)                 // id = .remote(alias: target.alias)
    public func attach(root: URL) async throws -> String?         // project.attach; returns takenOverFrom
    public var takenOver: AsyncStream<String> { get }             // project.takenOver for any attached root → by-name
    public func replace(link: SSHLink) async                      // C3 swaps links on reconnect; resumes watches
}
```
- **Behaviour of every `fs`/`processes` call:**
  - It maps 1:1 to `HostRPC`, with `Data` going over blobs.
  - On a transport failure, `kind` returns `.other` and never `.missing`. This is a Plan 1 A7 note: the unreadable-store guard depends on it.
  - Throwing methods throw `HostUnavailable`, a new public error in AlloyCore.
  - Non-throwing methods return their "unknown" value: `stamp` returns nil, `existingFiles` returns `[]` and logs, and `walkFiles` returns `([], true)`.
- **`changes(root:)`** opens a watch. Its stream survives `replace(link:)`, resuming from the last acked seq.
- **`projectStore(root:appSupport:)`** returns `<hello.storeRoot>/<sha256(root.path) first 16 hex>`.
- **Search:** remote search runs on the server with overlay paths excluded. The caller (`Workspace+Search`) searches the overlays locally with today's engine, then merges the results in path order.

- [ ] **Step 1: Write failing tests.** `HostConformanceTests` runs one parameterized behaviour suite against `LocalHost`, `TranslatingHost` and `RemoteHost`. `RemoteHost` reaches a local daemon over fake-ssh with a temp home.
  - every `HostFileSystem` method on a fixture tree, including the fifo, symlink-escape, missing, mode-keep and move-race cases
  - `git` and `run`
  - `changes` batches
  - search batches
  - `projectStore` shape
  - `kindIsOtherOnTransportFailure`: kill the link and check.
  - `searchMergesOverlaysWithRemoteResults`
- [ ] **Step 2:** run `swift build --product alloy-host && swift test --no-parallel --filter HostConformanceTests`. Expected: FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** run the same command, then `--filter 'AlloyCoreTests'`. Expected: PASS, with local behaviour unchanged.
- [ ] **Step 5:** commit `feat(remote): RemoteHost and host conformance suite`.

### Task C3: Connection manager

**Files:**
- Create: `Sources/AlloyRemote/RemoteConnection.swift`
- Test: `Tests/AlloyRemoteTests/RemoteConnectionTests.swift`

**Interfaces:**
- **Consumes:** C1 and C2.
- **Produces:**
```swift
public enum ConnectionState: Equatable, Sendable { case connecting, connected, reconnecting(attempt: Int), failed(SSHError) }
@MainActor @Observable public final class RemoteConnection {
    public init(target: SSHTarget, localBinary: URL, clientID: UUID, clientName: String,
                clock: any AutosaveClock = SystemAutosaveClock(), network: any NetworkEvents = SystemNetworkEvents())
    public private(set) var state: ConnectionState
    public private(set) var host: RemoteHost?                 // set once first connect succeeds; same instance across reconnects
    public func start() async                                // install-if-needed, open, hello
    public func retryNow()
    public func stop() async                                 // window closing: detach, never stops the daemon
    public func stopServer() async                           // "Stop Server": rpc stop, then close
}
public protocol NetworkEvents: Sendable { func events() -> AsyncStream<Void> }   // wake (NSWorkspace.didWakeNotification) + path change (NWPathMonitor)
```
- **Backoff:** 1, 2, 4, 8, 16, 30 s, then 30 s every time after that.
- **Immediate attempts:** a network event, a wake or `retryNow()` triggers an attempt at once and resets the backoff.
- **Errors that never retry:** `authFailed`, `hostKey`, `unsupported` and `badAlias` go straight to `.failed`.
- **Reconnect:** `RemoteHost.replace(link:)` re-attaches every root and resumes watches.

- [ ] **Step 1: Write failing tests.** They use fake-ssh and an injectable clock.
  - `connectsAndReportsConnected`
  - `dropTriggersBackoffSequence`, with a scripted clock.
  - `wakeEventRetriesImmediately`
  - `authFailureDoesNotRetry`
  - `resumeAfterGapRescans`: kill the link, overflow the watch ring on the server, reconnect, and expect a root rescan batch.
  - `stopDetachesButDaemonStaysUp`
  - `stopServerEndsDaemon`
- [ ] **Step 2:** run `swift test --no-parallel --filter RemoteConnectionTests`. Expected: FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** run the same command. Expected: PASS.
- [ ] **Step 5:** commit `feat(remote): connection manager with backoff, wake and network triggers`.

### Task C4: Workspace offline mode and takeover

**Files:**
- Modify: `Sources/AlloyCore/Model/Workspace.swift` (a new `remoteAvailability` state), `Sources/AlloyCore/Editor/Autosave.swift` (pause), `Sources/AlloyCore/Editor/OutsideEdits.swift` (reconnect re-sync)
- Create: `Sources/AlloyCore/Model/Workspace+Remote.swift`
- Test: `Tests/AlloyCoreTests/WorkspaceRemoteTests.swift`

**Interfaces:**
- **Consumes:** C3 `ConnectionState` (mirrored, so AlloyCore doesn't import AlloyRemote) and C2 `HostUnavailable`.
- **Produces:**
```swift
public enum RemoteAvailability: Equatable, Sendable { case local, online, offline(reason: String), takenOver(by: String) }
extension Workspace {
    public internal(set) var remoteAvailability: RemoteAvailability   // .local for LocalHost, never changes
    public func setRemoteAvailability(_ a: RemoteAvailability)         // U2 calls on state changes
}
// Autosave gains `paused: Bool` (no timers fire while paused; scheduled paths are kept and flushed on resume).
```
- **Going offline or taken over:**
  - Every editable document moves to `.readOnly(reason:)`. The reason is "Reconnecting to <host>…" or "This project is open on <other Mac>". The document's previous state is remembered.
  - Autosave pauses.
  - Saves, reverts and git actions refuse with that reason.
  - Unsaved buffers are kept.
- **Coming back online:** previous states are restored and the root is rescanned. Each open document's stamp is compared, and a moved file goes through the existing outside-edit conflict flow. Autosave resumes and flushes.
- **Suspending work while offline or taken over (Plan 1 final review I10):**
  - Index refresh, outside-edit processing (`handleDeleted`/`refresh`), restore filtering (`Workspace.existing`) and store loading are all suspended. A transport failure must never read as "file gone" or "empty project".
  - The work that was suspended runs once on reconnect.
  - `ensureLoaded` merges rather than replaces, once a store is loaded.
- **Takeover:** `takenOver` stays read-only until the user re-opens the project. U2 offers "Reopen here", which re-attaches and takes the project back.

- [ ] **Step 1: Write failing tests.** These run against `TranslatingHost` plus a scripted availability.
  - `offlineMakesEditorsReadOnlyAndRestores`
  - `autosavePausesAndFlushesOnResume`
  - `dropDuringSaveKeepsTheEdit`: a scripted `HostUnavailable` from `replaceAtomically`, then reconnect, and the save succeeds.
  - `reconnectWithChangedDiskUsesConflictFlow`
  - `takenOverClientNeverWrites`: after `takenOver`, no `fs` write is attempted. A recording fs asserts it.
  - `localWorkspaceIgnoresAvailability`
  - `offlineNeverDeletesTabsOrEmptiesTree`: while offline, index and kind calls fail. The tabs and the tree stay as they were, and nothing is marked deleted.
- [ ] **Step 2:** run `swift test --no-parallel --filter WorkspaceRemoteTests`. Expected: FAIL.
- [ ] **Step 3:** implement. The local path is unchanged, and `remoteAvailability` is `.local` for it.
- [ ] **Step 4:** run the same command, then `--filter AlloyCoreTests` and `--filter AlloyKitTests`. Expected: PASS.
- [ ] **Step 5:** commit `feat(remote): workspace offline mode and takeover`.

### Task U2: Remote window wiring, banner, badge, feature gating

**Files:**
- Modify:
  - `Sources/Alloy/main.swift`, adding an `.openRemote` branch: `RemoteConnection` → `Workspace(host: connection.host)` → attach → restore
  - `Sources/AlloyKit/Islands/TitleIsland.swift` (host badge)
  - `Sources/AlloyKit/RootView.swift` (window banner)
  - `Sources/AlloyKit/Commands/BuiltinCommands.swift` (Stop Server; gating)
  - `Sources/AlloyKit/LSP/LSPCoordinator.swift`, `Sources/AlloyKit/Terminal/TerminalPanelStore.swift` and plugin coordinators, to gate them off for remote windows
- Create: `Sources/AlloyKit/Remote/RemoteBanner.swift`, `Sources/AlloyKit/Remote/LiveRemoteBrowser.swift`
- Test: `Tests/AlloyKitTests/RemoteWindowTests.swift`

**Interfaces:**
- **Consumes:** U1, C3 and C4.
- **Produces:**
  - **Badge:** the title island shows `<alias>` with a server icon, id `title-host`, for remote windows.
  - **Banner:** `RemoteBanner`, id `remote-banner`, shows the state:
    - "Reconnecting to <host>…" with "Retry now";
    - "Can't connect: <reason>";
    - "This project is open on <other Mac>" with "Reopen here".
    - It is tied to `RemoteConnection.state` and `Workspace.remoteAvailability`.
  - **Window title:** the OS window title becomes `<alias>: <folder>`.
  - **New commands:** `remote.stopServer` ("Stop Server", File menu, remote windows only, with a confirmation alert). `LiveRemoteBrowser: RemoteBrowsing` is backed by `SSHLink` and `RemoteHost` for U1.
  - **Gating:** in remote windows, New Session, agents, the terminal panel, LSP and plugin processes (tasks, scripted plugins, plugin language servers) are off. Each shows "Available for remote projects in a later update" where the user would reach for it. Themes and declarative plugin parts still apply.
  - **Composer:** Send is disabled while the window is offline or taken over, and drafts are kept.
  - **App-local state is keyed by host as well as path (Plan 1 final review I8):**
    - `localStoreDirectory` (`ui-state.json`, `plugin-state`) hashes `HostID` plus the root, so a remote project never shares state with a local project at the same path.
    - KnowledgePool rows and KnowledgeScope roots are keyed the same way.
    - Local keys stay byte-identical to today, so existing data is found.
  - **Refusal at each factory, not just in the UI (Plan 1 final review I9).** When `host.id != .local`, the factories refuse:
    - the terminal spawner;
    - `LSPCoordinator.installLive`;
    - the plugin process launch.
    
    They refuse the same way agent transports already do, with a clear error and no spawn. The UI gating sits on top of this.

- [ ] **Step 1: Write failing tests.** These use a headless `TestWindow`, a `RemoteConnection` over fake-ssh and a local daemon.
  - `remoteWindowShowsHostBadgeAndTitle`
  - `bannerFollowsConnectionStates`
  - `retryNowButtonRetries`
  - `takeoverBannerOffersReopen`
  - `stopServerAsksThenStops`
  - `newSessionAndTerminalAreOffForRemote`
  - `localWindowUnchanged`: no badge, no banner, every feature on.
  - `remoteAndLocalSamePathKeepSeparateState`
  - `remoteFactoriesRefuseToSpawn`
- [ ] **Step 2:** run `swift test --no-parallel --filter RemoteWindowTests`. Expected: FAIL.
- [ ] **Step 3:** implement. For the banner, reuse the `UpdateBanner` and `FilePanelNotice` styling, with no new MetalUI needs. If one appears, forward it.
- [ ] **Step 4:** run the same command, then the full `--filter AlloyKitTests`. Expected: PASS.
- [ ] **Step 5:** commit `feat(remote): remote window wiring, banner, badge and feature gating`.

### Task F: End-to-end, tripwire, perf, acceptance

**Files:**
- Create: `Tests/AlloyKitTests/RemoteEndToEndTests.swift`, `docs/remote-acceptance.md`
- Modify: the A8 boundary guard allowlist, only if an entry is genuinely app-local

**Interfaces:** consumes everything.

- [ ] **Step 1: Write `remoteEndToEnd`.** A full remote window runs over fake-ssh to a local daemon with a temp `HOME`, against a project in a temp directory. It must:
  - open, edit, save, browse the tree, search (with an open dirty buffer as an overlay), stage and commit;
  - kill the link and check read-only plus the banner;
  - change a file on "disk" while offline, reconnect, and check the conflict flow;
  - attach a second client and check that the first is taken over.
- [ ] **Step 2: Write `remoteWindowSpawnsNothingLocally`.** Record every `Process` and `posix_spawn` the app process makes through the existing process seams, during a remote window session. The only allowed child is `ssh`, via `ALLOY_SSH`.
- [ ] **Step 3: Run the guards.** Run the A8 `noDirectDiskAccessOutsideHost` guard and the full `swift test --no-parallel`. Expected: PASS, with no new failures against release/0.2.
- [ ] **Step 4: Perf.** Measure these and append `remote-phase1` lines to `Bench/results/perf-history.jsonl`:
  - remote open time (fake-ssh, localhost);
  - search on 3000 files, remote against local;
  - daemon idle RSS after a session detaches, which must be under 15 MB;
  - laptop app memory for a remote window against a local one.
- [ ] **Step 5: Write `docs/remote-acceptance.md`.** It's a short checklist the user runs from the laptop against the real Mac mini:
  - "Connect to Server…" and pick the mini;
  - open a project, edit and save, then check the file on the mini;
  - sleep the laptop for 5 minutes and wake it, then check that it reconnects;
  - turn Wi-Fi off and on, then check the banner and that it recovers;
  - open the same project from a second Mac or a second Alloy window, then check the takeover notice;
  - Stop Server, then check the daemon is gone with `pgrep alloy-host` on the mini;
  - reboot the mini and log in, then check that the daemon restarts via launchd.
- [ ] **Step 6:** commit `test(remote): end-to-end, local-spawn tripwire, perf and acceptance checklist`.

---

## Later plans (unchanged outline)
- **Plan 3:** terminals and agents on the server, with replay, the MCP and hook stdio bridge, pending prompts, and Stop Server Sessions.
- **Plan 4:** language servers on the server.
- **Plan 5:** a Linux server (inotify, systemd user service, static SDK builds).
