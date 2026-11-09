import Foundation
import MetalUICodeBuffer

/// What the watcher learns about one changed file, computed off the main actor.
struct OutsideFacts: Sendable {
    var text: String
    /// The ledger holds a different text (false when the file is not in the ledger or is too large to track).
    var ledgerDiffers: Bool
    /// The open document's last-seen disk text differs from the file now.
    var bufferDiffers: Bool
    /// The bytes are valid UTF-8.
    var valid: Bool
    /// A refresh already in flight is bringing exactly these bytes into the buffer.
    var inFlight: Bool
}

/// One shell tool call's activity: from its tool_use to its tool_result plus a grace period. An open window
/// (`end == nil`) is a call still running.
struct ShellWindow: Equatable {
    var toolUseID: String
    var start: Double
    var end: Double?
}

extension Workspace {
    /// Changes under a directory are coalesced over this long before they are looked at.
    static let outsideCoalesce = 0.15
    /// How long a running Edit or Write tool call is given to deliver its result before the change counts as outside.
    static let editResultWait = 2.0
    /// A shell's window outlives its tool_result by this long: the file event and the read come later than the write.
    static let shellGrace = 1.0
    /// A change this long before a shell's tool_use still counts as the shell's (clock and mtime rounding).
    static let shellLead = 0.25
    /// Windows that ended longer ago than this are forgotten.
    static let windowRetention = 60.0
    /// A watcher event is at most this much older than the change it reports (FSEvents latency plus the coalescing window).
    static let eventLag = 0.35
    /// A modification date this recent before the event's arrival is believed: the watcher's thread may have been
    /// late, and a fresh date is a fair witness. Older dates (`mv`, `cp -p`, `rsync -a`, `tar -x`, `touch -r`)
    /// are not, and fall back to the lag.
    static let mtimeTrust = 2.0

    // MARK: Attribution

    /// Who authored a change that appeared on disk at `time` (on the injected clock) without a tool result to
    /// explain it: the one live session whose shell window covers that time, otherwise `.outside`. Every place that
    /// records a disk change the ledger was not told about uses this, so a Bash edit is not labelled `.outside`
    /// by whichever path happens to see it first, nor lost because its tool call already finished.
    func diskChangeAuthor(at time: Double) -> Author {
        let ids = coveringSessions(from: time, to: time)
        return ids.count == 1 ? .session(ids[0]) : .outside
    }

    /// The live sessions with a shell window that covers any time in `lo...hi`.
    func coveringSessions(from lo: Double, to hi: Double) -> [Session.ID] {
        pruneShellWindows()
        var found: [Session.ID] = []
        for (id, windows) in shellWindows where live[id] != nil {
            guard let s = session(id) else { continue }
            let covers = windows.contains { w in
                guard w.start - Self.shellLead <= hi, lo <= (w.end ?? .infinity) else { return false }
                // A call still waiting for the user's permission is not running yet.
                return w.end != nil || !Self.awaitsPermission(s, toolUseID: w.toolUseID)
            }
            if covers { found.append(id) }
        }
        return found
    }

    /// The injected clock's time at which a file last changed: its modification date, or, when that is unknown,
    /// shortly before `arrival`.
    func changeTime(_ modified: Date?, arrival: Double? = nil) -> Double {
        let nowClock = autosaveClock.now
        guard let modified else { return (arrival ?? nowClock) - 0.1 }
        return nowClock - max(0, now().timeIntervalSince(modified))
    }

    /// When a watched file changed, on the clock. The modification date is believed when it lies within
    /// `mtimeTrust` before `arrival`; an older one (preserved by `mv`, `cp -p`, ...) means only that the change is
    /// about one event lag old. The result never lies after `arrival`.
    func watcherChangeTime(_ modified: Date?, arrival: Double) -> Double {
        let mapped = changeTime(modified, arrival: arrival)
        return mapped >= arrival - Self.mtimeTrust ? min(arrival, mapped) : arrival - Self.eventLag
    }

    /// A watcher arrival for a path stays usable by the save path for this long.
    static let arrivalRetention = 10.0

    /// When a change that a save, a refresh, an open or a revert found on disk happened, on the clock, mapped the
    /// way the watcher maps it so the path that sees the change first does not decide its label. A recent watcher
    /// arrival for the path gives `watcherChangeTime` (an old modification date, from `cp -p`, `mv` or `rsync -a`,
    /// is clamped to one event lag before the arrival). Without an arrival the modification date is believed only
    /// within `mtimeTrust` of now; an older one has no witness, so the time is unknown (nil) and the change is not
    /// credited to whichever session happens to be running now (it may predate Alloy's start).
    func saveChangeTime(_ path: String, _ modified: Date?) -> Double? {
        pruneArrivals()
        if let arrival = recentArrival[path] { return watcherChangeTime(modified, arrival: arrival) }
        let mapped = changeTime(modified)
        return mapped >= autosaveClock.now - Self.mtimeTrust ? mapped : nil
    }

    /// Who authored a change the save path found: see `saveChangeTime`; `.outside` when its time is unknown.
    func saveChangeAuthor(_ path: String, _ modified: Date?) -> Author {
        saveChangeTime(path, modified).map { diskChangeAuthor(at: $0) } ?? .outside
    }

    func pruneArrivals() {
        let nowClock = autosaveClock.now
        recentArrival = recentArrival.filter { nowClock - $0.value <= Self.arrivalRetention }
    }

    /// The session behind a `.session` author (nil for `.outside` and `.user`).
    func sessionFor(_ author: Author) -> Session? {
        guard case .session(let id) = author else { return nil }
        return session(id)
    }

    private static func awaitsPermission(_ s: Session, toolUseID: String) -> Bool {
        s.transcript.blocks.contains {
            if case .permission(let p) = $0, p.state == .pending { return p.toolUseID == toolUseID }
            return false
        }
    }

    var shellWindowCount: Int { shellWindows.values.reduce(0) { $0 + $1.count } }

    private func pruneShellWindows() {
        let cutoff = autosaveClock.now - Self.windowRetention
        for (id, windows) in shellWindows {
            let kept = windows.filter { ($0.end ?? .infinity) >= cutoff }
            if kept.isEmpty { shellWindows.removeValue(forKey: id) } else if kept.count != windows.count { shellWindows[id] = kept }
        }
    }

    /// Keeps `shellWindows` in step with a session's events: a shell tool_use opens a window; once its block is no
    /// longer running the window ends a grace period later (a denied call never ran, so its window is dropped).
    func trackShellWindows(_ event: ProcessEvent, session s: Session) {
        let t = autosaveClock.now
        if case .message(.assistantBlock(_, .toolUse(let id, let name, _, _))) = event, ToolKind.classify(name) == .shell {
            if shellWindows[s.id]?.contains(where: { $0.toolUseID == id }) != true {
                shellWindows[s.id, default: []].append(ShellWindow(toolUseID: id, start: t, end: nil))
            }
            return
        }
        if case .message(.delta) = event { return }
        guard var windows = shellWindows[s.id], windows.contains(where: { $0.end == nil }) else { return }
        for i in windows.indices.reversed() where windows[i].end == nil {
            let status = s.transcript.blocks.reversed().lazy.compactMap { b -> ToolBlock.Status? in
                if case .tool(let tb) = b, tb.toolUseID == windows[i].toolUseID { return tb.status } else { return nil }
            }.first
            switch status {
            case .running?: continue
            case .denied?: windows.remove(at: i)
            default: windows[i].end = t + Self.shellGrace
            }
        }
        if windows.isEmpty { shellWindows.removeValue(forKey: s.id) } else { shellWindows[s.id] = windows }
    }

    /// The user answered a permission prompt: an allowed call starts running now, a denied one never does.
    func permissionAnswered(toolUseID: String?, allow: Bool, session id: Session.ID) {
        guard let toolUseID, var windows = shellWindows[id], let i = windows.firstIndex(where: { $0.toolUseID == toolUseID }) else { return }
        if allow { windows[i].start = autosaveClock.now } else { windows.remove(at: i) }
        shellWindows[id] = windows.isEmpty ? nil : windows
    }

    /// Whether a live session has an Edit or Write tool call running for `url` (not one awaiting permission).
    private func hasRunningEdit(for url: URL) -> Bool {
        let target = url.path, resolved = url.resolvingSymlinksInPath().path
        for s in sessions where live[s.id] != nil {
            for case .tool(let t) in s.transcript.blocks where t.status == .running && (t.kind == .edit || t.kind == .write) {
                guard let fp = t.input["file_path"]?.stringValue ?? t.input["notebook_path"]?.stringValue else { continue }
                let u = URL(fileURLWithPath: fp, relativeTo: projectRoot).standardizedFileURL
                guard u.path == target || u.resolvingSymlinksInPath().path == resolved else { continue }
                if !Self.awaitsPermission(s, toolUseID: t.toolUseID) { return true }
            }
        }
        return false
    }

    // MARK: Watching

    /// Starts watching the project for changes made outside Alloy. Calling it again does nothing.
    public func startWatching() {
        guard watchTask == nil, !isShuttingDown else { return }
        eventRoots = [projectRoot.standardizedFileURL.path, FSEventsSource.realPath(projectRoot)]
        let stream = changeFactory(projectRoot).changes()
        watchTask = Task { @MainActor [weak self] in
            for await paths in stream {
                guard let self else { return }
                self.enqueueOutside(paths)
            }
        }
        track { [weak self] in await self?.watchExternalGitDirectory() }
    }

    func stopWatching() {
        watchTask?.cancel(); watchTask = nil
        gitWatchTask?.cancel(); gitWatchTask = nil
        outsideDebounce?.cancel()
        gitDebounce?.cancel()
    }

    func enqueueOutside(_ paths: [String]) {
        guard !isShuttingDown else { return }
        let arrival = autosaveClock.now
        for p in paths { pendingOutside[p] = arrival }
        guard outsideDebounce == nil else { return }
        // The deadline is taken now, so a manual clock advanced before the timer task runs still fires it.
        let deadline = arrival + Self.outsideCoalesce, clock = autosaveClock
        outsideDebounce = track { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { self?.outsideDebounce = nil; return }
            await self?.flushOutside()
        }
    }

    private func flushOutside() async {
        outsideDebounce = nil
        let batch = pendingOutside
        pendingOutside = [:]
        guard !isShuttingDown else { return }
        // Per batch: which events are inside the project, which are directories, and which paths matter at all.
        var rels: [String: Double] = [:]
        var git: [String] = []
        for (path, arrival) in batch.sorted(by: { $0.key < $1.key }) {
            if let inGit = externalGitEventPath(path) { git.append(inGit); continue }
            guard let rel = relativeEventPath(path) else { continue }
            if rel == ".git" || rel.hasPrefix(".git/") { git.append(rel); continue }
            if path.hasSuffix("/") || path == eventRoots.first || path == eventRoots.last {
                // A directory removed or renamed, or a rescan: look at every file below it that Alloy knows.
                for known in knownPaths(under: rel) where rels[known] == nil { rels[known] = arrival }
            } else if rels[rel] == nil { rels[rel] = arrival }
        }
        for rel in rels.keys { noteFileChanged(rel) }
        var toProcess: [(String, Double)] = []
        var unknown: [(String, Double)] = []
        var shellAround: [Double: Bool] = [:]       // per distinct arrival time
        for (rel, arrival) in rels.sorted(by: { $0.key < $1.key }) {
            if documents[rel] != nil || tabs.contains(rel) || ledger.files[rel] != nil { toProcess.append((rel, arrival)); continue }
            // A path Alloy has never seen matters only if some shell could have written it. The modification date
            // is not known without a stat, so any window in the range `applyOutside` could pick lets the path through;
            // `applyOutside` then decides with the clamped date.
            let possible = shellAround[arrival] ?? !coveringSessions(from: arrival - Self.mtimeTrust, to: arrival).isEmpty
            shellAround[arrival] = possible
            if possible { unknown.append((rel, arrival)) }
        }
        if !unknown.isEmpty {
            let tracked = await trackedPaths(unknown.map(\.0))
            guard !isShuttingDown else { return }
            toProcess += unknown.filter { tracked.contains($0.0) }
        }
        pruneArrivals()
        for (rel, arrival) in toProcess { recentArrival[rel] = arrival }
        for (rel, arrival) in toProcess {
            guard !isShuttingDown else { return }
            await processOutsideChange(rel, arrival: arrival)
        }
        if !git.isEmpty, !isShuttingDown {
            gitChanged?(git)
            if git.contains(where: Self.isBaselineEvent) { baselineEventSeen() }
        }
    }

    /// The project-relative form of an event path ("" for the root itself), or nil outside the project.
    private func relativeEventPath(_ path: String) -> String? {
        for root in eventRoots {
            if path == root || path == root + "/" { return "" }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) {
                var rel = String(path.dropFirst(prefix.count))
                if rel.hasSuffix("/") { rel.removeLast() }
                return rel
            }
        }
        return nil
    }

    /// Open documents, tabs and ledger files at or below the directory `rel` ("" is the whole project).
    private func knownPaths(under rel: String) -> Set<String> {
        let all = Set(documents.keys).union(tabs).union(ledger.files.keys)
        if rel.isEmpty { return all }
        return all.filter { $0 == rel || $0.hasPrefix(rel + "/") }
    }

    // MARK: Waiting for a running Edit or Write

    func resumeToolResultWaiters() {
        let all = toolResultWaiters
        toolResultWaiters.removeAll()
        for w in all.values { w.resume() }
    }

    private func waitForToolResult(_ id: UUID) async {
        if abandonedWaiters.remove(id) != nil { return }
        await withCheckedContinuation { toolResultWaiters[id] = $0 }
    }

    private func abandonWaiter(_ id: UUID) {
        if let c = toolResultWaiters.removeValue(forKey: id) { c.resume() } else { abandonedWaiters.insert(id) }
    }

    /// Gives a running Edit or Write for `url` up to two seconds (on the injected clock) to deliver its result.
    private func waitForRunningEditResult(of url: URL) async {
        let clock = autosaveClock
        let deadline = clock.now + Self.editResultWait
        while hasRunningEdit(for: url), clock.now < deadline, !isShuttingDown {
            let id = UUID()
            // Wakes on the next tool result, or when the deadline passes, whichever comes first.
            let timeout = Task { @MainActor [weak self] in
                try? await clock.sleep(until: deadline)
                if !Task.isCancelled { self?.abandonWaiter(id) }
            }
            await waitForToolResult(id)
            abandonedWaiters.remove(id)
            timeout.cancel()
        }
    }

    // MARK: One changed file

    private func processOutsideChange(_ rel: String, arrival: Double) async {
        let url = projectRoot.appendingPathComponent(rel).standardizedFileURL
        await waitForRunningEditResult(of: url)
        for _ in 0..<3 {
            guard !isShuttingDown else { return }
            outsideReadCount += 1
            let read = await readSettled(rel, url)
            guard !isShuttingDown else { return }
            let doc = documents[rel], file = ledger.files[rel]
            switch read {
            case .binary: return
            case .unreadable:
                if !FileManager.default.fileExists(atPath: url.path) { handleDeleted(rel) }
                return
            case .text(let bytes, _, let truncated):
                deletedNotified.remove(rel)
                let base = doc?.savedSnapshot
                let inFlight = syncTarget[rel]?.bytes
                let facts = await Task.detached {
                    Self.compare(bytes: bytes, file: file, base: base, truncated: truncated, inFlight: inFlight)
                }.value
                guard !isShuttingDown else { return }
                // The ledger or the document moved while comparing: look again.
                guard documents[rel] === doc, ledger.files[rel]?.version == file?.version else { continue }
                await applyOutside(rel, url: url, read: read, arrival: arrival, facts: facts, doc: doc, file: file)
                return
            }
        }
    }

    nonisolated private static func compare(bytes: [UInt8], file: FileLedger?, base: CodeSnapshot?,
                                            truncated: Bool, inFlight: [UInt8]?) -> OutsideFacts {
        let text = String(decoding: bytes, as: UTF8.self)
        let ledgerDiffers = !truncated && file.map { !TextDiff.same($0.text.text, text) } == true
        let bufferDiffers = base.map { $0.utf8(in: 0..<$0.utf8Count) != Array(text.utf8) } ?? false
        return OutsideFacts(text: text, ledgerDiffers: ledgerDiffers, bufferDiffers: bufferDiffers,
                            valid: String(data: Data(bytes), encoding: .utf8) != nil,
                            inFlight: inFlight.map { $0.count == bytes.count && $0 == bytes } ?? false)
    }

    private func applyOutside(_ rel: String, url: URL, read: EditorFileRead, arrival: Double, facts: OutsideFacts,
                              doc: EditorDocument?, file: FileLedger?) async {
        guard case .text(_, let stamp, let truncated) = read else { return }
        let author = diskChangeAuthor(at: watcherChangeTime(stamp.modified, arrival: arrival))
        let trackable = facts.valid && !truncated
        if let doc {
            guard facts.ledgerDiffers || facts.bufferDiffers else { return }
            // The ledger follows the disk first, so a merge's save records only the user's own typing.
            var attributed = false
            if trackable, facts.ledgerDiffers || (file == nil && sessionFor(author) != nil) {
                await appendToLedger(rel, saved: doc.savedSnapshot, edits: [(author, facts.text)])
                attributed = true
            }
            guard !isShuttingDown, facts.bufferDiffers else { return }
            // A read-only document whose reason is gone (invalid bytes fixed, file shrunk or restored) is editable again.
            if doc.state != .editable, !doc.isDirty, trackable {
                install(read, path: rel, url: url)
                return
            }
            // A refresh already heading for these bytes (a tool result's) does the work and names its session.
            if facts.inFlight { return }
            // The ledger already held this text: the change was a session's tool result, not a new outside one.
            var who = sessionFor(author)
            if !attributed, let last = file?.edits.last?.author { who = sessionFor(last) }
            syncOpenBuffer(rel, by: who)
            return
        }
        // A tab that could not show the file (binary, unreadable, deleted before it opened) tries again.
        if tabs.contains(rel), tabMessages[rel] != nil {
            tabMessages.removeValue(forKey: rel)
            install(read, path: rel, url: url)
            await reconcileOnOpen(rel, read)
            return
        }
        guard trackable else { return }
        if file != nil {
            guard facts.ledgerDiffers else { return }
            await appendToLedger(rel, saved: nil, edits: [(author, facts.text)])
            return
        }
        // A file the ledger has never seen: only a change made while exactly one shell runs, in a file git tracks,
        // is attributed (to that session, against HEAD's text).
        guard case .session = author else { return }
        gitSpawnCount += 1
        guard let baseline = await Self.gitHead(root: projectRoot, rel: rel, differingFrom: facts.text), !isShuttingDown else { return }
        await appendToLedger(rel, saved: nil, baseline: baseline, edits: [(author, facts.text)])
    }

    private func handleDeleted(_ rel: String) {
        guard let doc = documents[rel], doc.state == .editable else { return }
        if doc.isDirty {
            // Unsaved typing is never thrown away: the buffer stays editable and the next save recreates the file.
            // Once per deletion: the path is cleared again when the file is seen to exist.
            if deletedNotified.insert(rel).inserted {
                notify(path: rel, kind: .warning, text: "\(rel) was deleted outside Alloy; your unsaved changes are kept and saving recreates it.")
            }
            return
        }
        doc.state = .readOnly(reason: "File was deleted outside Alloy")
        doc.buffer.isReadOnly = true
    }

    /// Adds a message about the user's work, keeping the newest `noticeLimit`.
    func notify(path: String?, kind: NoticeKind, text: String) {
        notices.append(Notice(path: path, kind: kind, text: text))
        if notices.count > Self.noticeLimit { notices.removeFirst(notices.count - Self.noticeLimit) }
    }

    /// When a file is opened and the ledger's text for it differs from the disk text, the difference is recorded.
    func reconcileOnOpen(_ path: String, _ result: EditorFileRead) async {
        guard let doc = documents[path], doc.state == .editable, case .text(let bytes, let stamp, let truncated) = result,
              !truncated, let file = ledger.files[path] else { return }
        let text = await Task.detached { () -> String? in
            let t = String(decoding: bytes, as: UTF8.self)
            return TextDiff.same(file.text.text, t) ? nil : t
        }.value
        guard let text, !isShuttingDown, ledger.files[path]?.version == file.version, documents[path] === doc else { return }
        await appendToLedger(path, saved: doc.savedSnapshot, edits: [(saveChangeAuthor(path, stamp.modified), text)])
    }

    // MARK: git

    /// The subset of `paths` git tracks, from one `git ls-files -z` per chunk (not a repository: none).
    private func trackedPaths(_ paths: [String]) async -> Set<String> {
        var tracked = Set<String>()
        for start in stride(from: 0, to: paths.count, by: 400) {
            let chunk = Array(paths[start..<min(start + 400, paths.count)])
            gitSpawnCount += 1
            guard let out = await Self.gitRun(["--literal-pathspecs", "ls-files", "-z", "--"] + chunk, in: projectRoot) else { continue }
            for name in out.split(separator: 0) { tracked.insert(String(decoding: name, as: UTF8.self)) }
        }
        return tracked
    }

    /// HEAD's text of `rel` (`git cat-file blob`, which never runs textconv), when it differs from `text`. Not a git
    /// repository, an untracked path, an unreadable output and a hung git (killed after 10 s) all read as nil.
    nonisolated static func gitHead(root: URL, rel: String, differingFrom text: String) async -> String? {
        guard let data = await gitRun(["cat-file", "blob", "HEAD:./" + rel], in: root),
              let head = String(data: data, encoding: .utf8) else { return nil }
        return await Task.detached { TextDiff.same(head, text) ? nil : head }.value
    }

    /// Whether a developer toolchain is selected. `xcode-select -p` never shows a dialog, unlike running the
    /// `/usr/bin/git` shim without one, and it accepts an Xcode.app-only setup.
    nonisolated private static let gitUsable: Bool = {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return false }
        if ProcessInfo.processInfo.environment["DEVELOPER_DIR"] != nil { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()

    /// Runs git in `root` and returns its standard output when it exits 0. The wait does not occupy a thread of the
    /// cooperative pool: output is read by a readability handler and the exit arrives through the termination
    /// handler. A hung git gets SIGTERM after `terminateAfter` seconds and SIGKILL after `killAfter`, when the run
    /// also gives up with nil whatever the process does; only the process started here is ever signalled.
    nonisolated static func gitRun(_ args: [String], in root: URL, terminateAfter: Double = 10, killAfter: Double = 12) async -> Data? {
        guard gitUsable else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = root
            var env = ProcessInfo.processInfo.environment
            env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_LITERAL_PATHSPECS"] = "1"
            process.environment = env
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let run = GitRun(continuation)
            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; run.outputEnded() } else { run.append(chunk) }
            }
            process.terminationHandler = { run.exited($0.terminationStatus) }
            do { try process.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil
                run.fail()
                return
            }
            let box = ProcessBox(process)
            DispatchQueue.global().asyncAfter(deadline: .now() + terminateAfter) { box.terminateIfRunning() }
            DispatchQueue.global().asyncAfter(deadline: .now() + killAfter) { box.killIfRunning(); run.fail() }
        }
    }
}

/// The state of one git run: output so far, whether it ended, how the process exited; resumes once.
private final class GitRun: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var ended = false
    private var status: Int32?
    private var done = false
    private let continuation: CheckedContinuation<Data?, Never>

    init(_ c: CheckedContinuation<Data?, Never>) { continuation = c }

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    func outputEnded() { lock.withLock { ended = true }; finishIfReady() }
    func exited(_ code: Int32) {
        lock.withLock { status = code }
        finishIfReady()
        // A grandchild holding the pipe open must not hold the result back.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in lock.withLock { ended = true }; finishIfReady() }
    }
    func fail() { resume(nil) }

    private func finishIfReady() {
        let result: Data?? = lock.withLock {
            guard ended, let status, !done else { return nil }
            return .some(status == 0 ? data : nil)
        }
        if let result { resume(result) }
    }

    private func resume(_ value: Data?) {
        let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
        if first { continuation.resume(returning: value) }
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    init(_ p: Process) { process = p }
    func terminateIfRunning() { if process.isRunning { process.terminate() } }
    func killIfRunning() { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
}
