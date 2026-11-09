@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

/// A workspace over a temp project, with a manual autosave clock and scripted session transports.
@MainActor
final class Env {
    let root: URL
    let transports = ScriptedTransports()
    let clock = ManualClock()
    let changes = ScriptedChangeSource()
    /// Wall-clock time as the workspace sees it: a fixed base plus the manual clock, so mtimes map deterministically.
    let baseDate = Date()
    var nowDate: Date { baseDate.addingTimeInterval(clock.now) }
    let ws: Workspace
    /// `base` is a temp directory the test owns (cleanup removes the project's parent, so the project is `base/<project>`;
    /// a git worktree can be one). `factory` picks the change source for a watched directory; by default every
    /// directory gets `changes`.
    init(base: URL = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-sv-\(UUID().uuidString)"),
         project: String = "p", factory: (@Sendable (URL, ScriptedChangeSource) -> any FileChangeSource)? = nil) {
        let projectDir = base.appendingPathComponent(project), support = base.appendingPathComponent("s")
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let root = projectDir.resolvingSymlinksInPath()
        self.root = root
        let bag = transports, source = changes, c = clock, baseTime = baseDate
        ws = Workspace(projectRoot: root, appSupport: support, settings: AlloySettings(),
                       locate: { _ in URL(fileURLWithPath: "/fake/claude") },
                       makeTransport: { _ in bag.make() },
                       now: { baseTime.addingTimeInterval(c.now) },
                       autosaveClock: clock,
                       changes: { url in factory?(url, source) ?? source })
    }

    /// Delivers one batch of changed files to the watcher, runs the 150 ms coalescing window, and waits for the work.
    func fire(_ names: [String]) async {
        await send(names)
        await ws.settle()
    }

    /// Delivers a batch and passes the coalescing window, without waiting for the work to finish.
    func send(_ names: [String]) async {
        await queue(names)
        clock.advance(by: 0.15)
    }

    /// Delivers a batch to the watcher but leaves the coalescing window open.
    func queue(_ names: [String]) async {
        ws.startWatching()
        changes.send(names.map { url($0).path })
        await waitUntil("batch queued") { !ws.pendingOutside.isEmpty }
    }

    func transport(of s: Session) -> ScriptedTransport {
        transports.all[ws.sessions.firstIndex { $0.id == s.id }!]
    }

    /// Delivers the result of a Bash call and waits until the session shows it finished.
    func finishBash(_ s: Session, id: String = "bash1") async {
        await transport(of: s).emit(.toolResult(ToolResultMessage(toolUseID: id, isError: false, text: "ok", result: .none)))
        await waitUntil("bash finished") {
            s.transcript.blocks.contains { if case .tool(let b) = $0 { return b.toolUseID == id && b.status != .running } else { return false } }
        }
    }

    /// Starts a session and has it run a Bash tool call that has no result yet.
    @discardableResult
    func startBash(session name: String = "S", id: String = "bash1", background: Bool = false) async -> Session {
        let s = await ws.newSession(name: name)
        let t = transports.all[ws.sessions.count - 1]
        await t.emit(.assistantBlock(messageID: "m" + id, block: .toolUse(id: id, name: "Bash", input: .object(["command": .string("sed -i x")]
                                                                            .merging(background ? ["run_in_background": .bool(true)] : [:]) { $1 }))))
        await waitUntil("bash running") {
            s.transcript.blocks.contains { if case .tool(let b) = $0 { return b.status == .running } else { return false } }
        }
        return s
    }
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    /// Writes the file and stamps it with the workspace's current time.
    func write(_ name: String, _ text: String) {
        try? text.write(to: url(name), atomically: true, encoding: .utf8)
        // Each write gets its own date (a millisecond apart), so two writes of equal size never share a stamp.
        stampCounter += 1
        setModified(name, nowDate.addingTimeInterval(Double(stampCounter) * 0.001))
    }
    private var stampCounter = 0
    func setModified(_ name: String, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url(name).path)
    }
    func read(_ name: String) -> String { (try? String(contentsOf: url(name), encoding: .utf8)) ?? "<missing>" }
    func cleanup() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    /// Writes `new` over `name` and delivers the matching Edit tool result from the first session.
    func sessionEdit(_ name: String, old: String, new: String, id: String = "t1", writeDisk: Bool = true) async throws {
        let o = TextLines(old).lines, n = TextLines(new).lines
        let hunks = Patch.diff(old: o, new: n, context: 0)
        if writeDisk { write(name, new) }
        let t = try #require(transports.all.first)
        await t.emit(.assistantBlock(messageID: "m" + id, block: .toolUse(id: id, name: "Edit", input: .object([:]))))
        await t.emit(.toolResult(ToolResultMessage(toolUseID: id, isError: false, text: "ok",
                                                   result: .edit(filePath: url(name).path, originalFile: old, hunks: hunks))))
    }

    /// The author of each line of the ledger's text for `name`.
    func lineAuthors(_ name: String) -> [Author?] {
        guard let file = ws.ledger.files[name] else { return [] }
        return file.lineOwners().map { owner in owner.flatMap { id in file.edits.first { $0.id == id }?.author } }
    }
}

@MainActor
func waitUntil(_ what: String = "condition", _ cond: @MainActor () -> Bool) async {
    for _ in 0..<500_000 { if cond() { return }; await Task.yield() }
    Issue.record("timed out waiting for \(what)")
}

/// Holds one caller until released; later callers pass straight through.
actor TestGate {
    private var entered = false, open = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var first = true
    func hold() async {
        guard first else { return }
        first = false; entered = true
        if open { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { open = true; waiter?.resume(); waiter = nil }
}


actor CallCounter {
    private var n = 0
    func next() -> Int { n += 1; return n }
}
