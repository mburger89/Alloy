import Foundation

/// How git runs: the arguments, the directory, optional stdin, whether the run is read-only, and the SIGTERM and SIGKILL delays.
public typealias GitRunner = @Sendable ([String], URL, Data?, Bool, Double, Double) async -> GitResult

/// What a service knows about the project's repository.
public enum GitRepoState: Equatable, Sendable {
    /// Not looked at yet.
    case unknown
    case ready
    case notARepo
    /// Git itself is unusable; the string says why.
    case noGit(String)
}

/// What one status run changed. Only changed paths cross to the main actor.
public struct GitUpdate: Sendable {
    public var status: GitStatus
    public var state: GitRepoState
    /// Display status by path, for the paths whose status appeared (a value), changed (a value) or disappeared (nil).
    public var changedDisplay: [String: GitDisplayStatus?]
    /// The same for folders (rolled up from their children).
    public var changedFolders: [String: GitDisplayStatus?]
    /// HEAD moved: another branch or another commit than the previous status.
    public var headChanged: Bool
    public var timedOut: Bool

    public init(status: GitStatus, state: GitRepoState = .ready, changedDisplay: [String: GitDisplayStatus?] = [:],
                changedFolders: [String: GitDisplayStatus?] = [:], headChanged: Bool = false, timedOut: Bool = false) {
        self.status = status; self.state = state; self.changedDisplay = changedDisplay
        self.changedFolders = changedFolders; self.headChanged = headChanged; self.timedOut = timedOut
    }
}

/// The outcome of a git command that changes the repository.
public struct GitCommandResult: Equatable, Sendable {
    public var ok: Bool
    public var stderr: String
    public init(ok: Bool, stderr: String = "") { self.ok = ok; self.stderr = stderr }
}

public struct GitBranch: Equatable, Sendable {
    public var name: String
    public var isCurrent: Bool
    public var lastCommit: Date
    public init(name: String, isCurrent: Bool, lastCommit: Date) { self.name = name; self.isCurrent = isCurrent; self.lastCommit = lastCommit }
}

/// A counter readable without hopping to the actor.
final class GitSpawnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

/// Owns everything Alloy knows about one project's git state: the last status, the blob and blame caches, and the
/// coalescer that keeps a burst of file events down to a status run or two. Nothing here runs on its own: a status
/// run happens only after a request, and a status that timed out pauses requests until `refreshNow()`.
public actor GitService {
    /// The coalescing window of a refresh request.
    public static let window = 0.5
    static let maxCatFiles = 2

    let root: URL
    let clock: any AutosaveClock
    let runner: GitRunner
    private let counter = GitSpawnCounter()

    public private(set) var state: GitRepoState = .unknown
    public private(set) var status: GitStatus?
    /// The project's path inside the repository ("" or "sub/") and the repository's top.
    var prefix = ""
    var repoTop: URL?
    var gitDir: URL?

    private var display: [String: GitDisplayStatus] = [:]
    private var folders: [String: GitDisplayStatus] = [:]
    private var ignoredEntries: [String] = []
    private var handler: (@Sendable (GitUpdate) -> Void)?

    private var pump: Task<Void, Never>?
    private var pumpID = 0
    private var running = false
    private var dirty = false
    private var paused = false
    private var stopped = false
    private var timedOutShown = false

    // Blobs and blame (see GitService+Write.swift for blame).
    private var blobs: [String: String] = [:]
    private var unreadable: Set<String> = []
    private var inflight: [String: Task<String?, Never>] = [:]
    private var catActive = 0
    private var catWaiters: [CheckedContinuation<Void, Never>] = []
    var blameCache: [String: [GitBlameRun]] = [:]
    public internal(set) var blameSpawns = 0
    /// HEAD blob oids of files with no status entry, by "commit:path" ("" for none); see GitService+Marks.swift.
    var headBlobCache: [String: String] = [:]

    public init(root: URL, clock: any AutosaveClock, runner: @escaping GitRunner = GitService.liveRunner) {
        self.root = root; self.clock = clock; self.runner = runner
    }

    public static let liveRunner: GitRunner = { args, dir, stdin, readOnly, terminate, kill in
        await GitProcess.run(args, in: dir, stdin: stdin, readOnly: readOnly, terminateAfter: terminate, killAfter: kill)
    }

    /// How many git processes this service started.
    public nonisolated var spawnCount: Int { counter.value }

    public func setUpdateHandler(_ f: @escaping @Sendable (GitUpdate) -> Void) { handler = f }

    func run(_ args: [String], in dir: URL? = nil, stdin: Data? = nil, readOnly: Bool, terminate: Double? = nil, kill: Double? = nil) async -> GitResult {
        counter.bump()
        return await runner(args, dir ?? root, stdin, readOnly, terminate ?? (readOnly ? 10 : 120), kill ?? (readOnly ? 12 : 125))
    }

    // MARK: - Discovery

    /// Looks for the repository once; `.ready` afterwards unless there is none or git is unusable.
    func discover() async {
        if state == .ready { return }
        switch GitExecutable.current {
        case .usable: break
        case .notFound: state = .noGit("git was not found"); return
        case .shimWithoutTools: state = .noGit("the command line developer tools are not installed"); return
        case .tooOld(let v): state = .noGit("git \(v) is older than 2.23"); return
        }
        let r = await run(["rev-parse", "--show-toplevel", "--show-prefix", "--absolute-git-dir"], readOnly: true)
        guard r.status == 0 else {
            state = r.timedOut ? .unknown : .notARepo
            return
        }
        let lines = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, !lines[0].isEmpty else { state = .notARepo; return }
        repoTop = URL(fileURLWithPath: lines[0], isDirectory: true)
        prefix = lines[1]
        gitDir = URL(fileURLWithPath: lines[2], isDirectory: true)
        state = .ready
    }

    /// A git event at the project: when no repository was found, look again (a `git init` may have happened).
    public func gitEvent() {
        if state != .ready { state = .unknown; repoTop = nil }
        requestRefresh()
    }

    // MARK: - Coalescer

    /// Asks for a status run: within 0.5 s of the first request, at most one run; a request during a run asks for one
    /// follow-up. Ignored without a repository, after a timeout (until `refreshNow()`) and after `stop()`.
    public func requestRefresh() {
        guard !stopped, !paused else { return }
        switch state {
        case .notARepo, .noGit: return
        case .unknown, .ready: break
        }
        if running { dirty = true; return }
        if pump != nil { return }
        startPump(deadline: clock.now + Self.window)
    }

    /// Runs a status now (the refresh button), also after a timeout paused the automatic ones.
    public func refreshNow() async {
        guard !stopped else { return }
        paused = false
        if state == .notARepo { state = .unknown; repoTop = nil }
        if let p = pump {
            // A run in flight gets its one follow-up; a window still waiting is cut short.
            if running { dirty = true; await p.value; return }
            p.cancel()
            await p.value
        }
        if pump == nil { startPump(deadline: nil) }
        await pump?.value
    }

    private func startPump(deadline: Double?) {
        pumpID += 1
        let id = pumpID
        pump = Task { [weak self] in await self?.runPump(id: id, deadline: deadline) }
    }

    private func runPump(id: Int, deadline: Double?) async {
        if let deadline {
            do { try await clock.sleep(until: deadline) } catch {
                if pumpID == id { pump = nil }
                return
            }
        }
        repeat {
            running = true; dirty = false
            await runStatus()
            running = false
        } while dirty && !stopped && !paused
        if pumpID == id { pump = nil }
    }

    /// Waits until no run is pending or in flight (tests; the clock must already have passed the window).
    public func idle() async {
        while let p = pump { await p.value }
    }

    public func stop() {
        stopped = true
        pump?.cancel()
        handler = nil
    }

    // MARK: - Status

    private func runStatus() async {
        await discover()
        guard state == .ready, let top = repoTop else {
            if state != .unknown { emit(GitUpdate(status: GitStatus(), state: state)) }
            return
        }
        _ = top
        let r = await run(["-C", root.path, "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal",
                           "--ignored=traditional", "--", "."], readOnly: true)
        if r.timedOut {
            paused = true; timedOutShown = true
            emit(GitUpdate(status: status ?? GitStatus(), state: state, timedOut: true))
            return
        }
        guard r.status == 0 else { return }
        let prefix = self.prefix, gitDir = self.gitDir
        var next = GitStatusParser.parse(r.stdout, prefix: prefix)
        if let gitDir { next.operation = GitOperation.detect(gitDir: gitDir) }
        let previous = status
        if let previous, previous == next, !timedOutShown { return }
        timedOutShown = false
        let newDisplay = next.entries.mapValues(\.display)
        let ignoredFolders = Set(next.entries.values.filter { $0.kind == .ignored && $0.path.hasSuffix("/") }.map(\.path))
        let newFolders = GitStatusRollup.folders(newDisplay, ignoredFolders: ignoredFolders)
        var changedDisplay: [String: GitDisplayStatus?] = [:]
        for p in GitStatusDiff.changedPaths(old: display, new: newDisplay) { changedDisplay.updateValue(newDisplay[p], forKey: p) }
        var changedFolders: [String: GitDisplayStatus?] = [:]
        for p in GitStatusDiff.changedPaths(old: folders, new: newFolders) { changedFolders.updateValue(newFolders[p], forKey: p) }
        let headChanged = previous.map { $0.oid != next.oid || $0.branch != next.branch } ?? false
        if headChanged { blameCache = [:] }
        status = next; display = newDisplay; folders = newFolders
        ignoredEntries = next.entries.values.filter { $0.kind == .ignored }.map(\.path)
        emit(GitUpdate(status: next, state: .ready, changedDisplay: changedDisplay, changedFolders: changedFolders, headChanged: headChanged))
    }

    private func emit(_ update: GitUpdate) { handler?(update) }

    /// False when every path lies under (or is) something the last status reported ignored: such events cannot change
    /// the status, so they do not request a run. Always false without a repository.
    public func shouldRefresh(forWorktreePaths paths: [String]) -> Bool {
        switch state {
        case .notARepo, .noGit: return false
        case .unknown, .ready: break
        }
        guard status != nil else { return true }
        return paths.contains { path in
            !ignoredEntries.contains { $0.hasSuffix("/") ? (path + "/" == $0 || path.hasPrefix($0)) : path == $0 }
        }
    }

    // MARK: - Blobs

    /// The text of the HEAD blob `oid`, nil for a binary or LFS pointer or a failed read.
    public func headText(oid: String) async -> String? { await blob(oid) }
    /// The text of the index blob `oid`.
    public func indexText(oid: String) async -> String? { await blob(oid) }

    private func blob(_ oid: String) async -> String? {
        if let text = blobs[oid] { return text }
        if unreadable.contains(oid) { return nil }
        if let task = inflight[oid] { return await task.value }
        let task = Task<String?, Never> { await self.fetchBlob(oid) }
        inflight[oid] = task
        let text = await task.value
        inflight[oid] = nil
        return text
    }

    private func fetchBlob(_ oid: String) async -> String? {
        await acquireCat()
        defer { releaseCat() }
        await discover()
        guard state == .ready else { return nil }
        let r = await run(["cat-file", "blob", oid], in: repoTop ?? root, readOnly: true)
        guard r.status == 0, GitBlobKind.classify(r.stdout) == .text else { unreadable.insert(oid); return nil }
        let text = String(decoding: r.stdout, as: UTF8.self)
        blobs[oid] = text
        return text
    }

    private func acquireCat() async {
        if catActive < Self.maxCatFiles { catActive += 1; return }
        await withCheckedContinuation { catWaiters.append($0) }
    }

    private func releaseCat() {
        if catWaiters.isEmpty { catActive -= 1 } else { catWaiters.removeFirst().resume() }
    }

    /// Drops every cached blob whose oid is not in `oids` (the ones the open documents still use).
    public func retainBlobs(for oids: Set<String>) {
        blobs = blobs.filter { oids.contains($0.key) }
        unreadable.formIntersection(oids)
    }

    /// Whether a blob is cached (tests).
    public func hasBlob(_ oid: String) -> Bool { blobs[oid] != nil }
}
