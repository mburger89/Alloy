@testable import AlloyCore
import AlloyHighlight
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

/// Counts what the coordinator asks of its sources and answers as a test scripts.
final class FoldScript: @unchecked Sendable {
    private let lock = NSLock()
    private var _lspCalls = 0, _treeCalls = 0
    private var _lsp: @Sendable (CodeSnapshot) async -> FoldingOutcome = { _ in .unavailable }
    private var _tree: @Sendable (UInt64) async -> [FoldRange]? = { _ in nil }

    var lspCalls: Int { lock.withLock { _lspCalls } }
    var treeCalls: Int { lock.withLock { _treeCalls } }
    func lsp(_ f: @escaping @Sendable (CodeSnapshot) async -> FoldingOutcome) { lock.withLock { _lsp = f } }
    func tree(_ f: @escaping @Sendable (UInt64) async -> [FoldRange]?) { lock.withLock { _tree = f } }

    var sources: FoldCoordinator.Sources {
        .init(
            lsp: { [self] _, snapshot in
                let f = lock.withLock { _lspCalls += 1; return _lsp }
                return await f(snapshot)
            },
            tree: { [self] _, version in
                let f = lock.withLock { _treeCalls += 1; return _tree }
                guard let ranges = await f(version) else { return nil }
                return (version, ranges)
            })
    }
}

/// Holds callers until a test opens it; a cancelled waiter leaves at once.
final class FoldGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var next = 0

    func open() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for c in all { c.resume() }
    }

    func wait() async {
        let id = lock.withLock { () -> Int in next += 1; return next }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    waiters[id] = c
                    return false
                }
                if resumeNow { c.resume() }
            }
        } onCancel: {
            let c = lock.withLock { waiters.removeValue(forKey: id) }
            c?.resume()
        }
    }
}

private func r(_ a: Int, _ b: Int) -> FoldRange { FoldRange(startLine: a, endLine: b) }

@MainActor
final class FoldRig {
    let rig = Rig()
    let engine = HighlightEngine()
    let script = FoldScript()
    let coordinator: FoldCoordinator
    var workspace: Workspace { rig.workspace }
    var pane: PaneID { workspace.defaultPane }
    private var kept: [DocumentServices] = []

    init(debounce: Duration = .milliseconds(300), lspTimeout: Duration = .seconds(1), windowedBytes: Int = 1_048_576) {
        coordinator = FoldCoordinator(sources: script.sources, debounce: debounce, lspTimeout: lspTimeout, windowedBytes: windowedBytes)
        coordinator.attach(workspace: rig.workspace)
    }

    static let body = "func a() {\n    x\n    y\n}\n"

    /// Opens `path` with `text` in the workspace and follows it with the coordinator.
    @discardableResult
    func open(_ path: String, _ text: String = FoldRig.body) async throws -> DocumentServices {
        try text.write(to: rig.root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        await workspace.open(path)
        let doc = try #require(workspace.document(path))
        _ = workspace.selectionState(for: path, in: pane)
        let services = DocumentServices(document: doc, engine: engine)
        services.attachFolds(coordinator)
        kept.append(services)
        return services
    }

    func type(_ services: DocumentServices, _ text: String, at offset: Int = 0) {
        _ = services.document.buffer.replace(offset..<offset, with: text, origin: .typing)
    }

    /// Lets main-actor tasks run until `condition` holds.
    func pump(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<600 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    func settle(_ services: DocumentServices, path: String, advance seconds: Double = 1) async {
        services.drainEdits()
        _ = await pump { self.rig.clock.pendingSleepers > 0 }
        rig.clock.advance(by: seconds)
    }
}

@MainActor @Suite struct FoldCoordinatorTests {
    @Test func firstBuildUsesIndentationWithoutAGrammar() async throws {
        let f = FoldRig()
        try await f.open("a.txt")
        #expect(await f.pump { f.coordinator.ranges["a.txt"] != nil })
        let got = try #require(f.coordinator.ranges["a.txt"])
        #expect(got.source == .indentation)
        #expect(got.ranges == [r(0, 2)])
        #expect(f.script.treeCalls == 0)
        let state = try #require(f.workspace.foldState(for: "a.txt", in: f.pane))
        #expect(state.foldableRanges == [0..<3])
    }

    @Test func treeSitterBeatsIndentation() async throws {
        let f = FoldRig()
        f.script.tree { _ in [r(0, 3)] }
        try await f.open("a.swift")
        #expect(await f.pump { f.coordinator.ranges["a.swift"] != nil })
        #expect(f.coordinator.ranges["a.swift"]?.source == .treeSitter)
        #expect(f.coordinator.ranges["a.swift"]?.ranges == [r(0, 3)])
    }

    @Test func lspBeatsTreeSitterAndSwitchesSource() async throws {
        let f = FoldRig()
        let gate = FoldGate()
        f.script.tree { _ in [r(0, 2)] }
        f.script.lsp { _ in await gate.wait(); return .answered([r(0, 3)]) }
        try await f.open("a.swift")
        #expect(await f.pump { f.coordinator.ranges["a.swift"]?.source == .treeSitter })
        gate.open()
        #expect(await f.pump { f.coordinator.ranges["a.swift"]?.source == .lsp })
        #expect(f.coordinator.ranges["a.swift"]?.ranges == [r(0, 3)])
        let state = try #require(f.workspace.foldState(for: "a.swift", in: f.pane))
        #expect(state.foldableRanges == [0..<4])
    }

    @Test func emptyLSPAnswerFallsBack() async throws {
        let f = FoldRig()
        f.script.tree { _ in [r(0, 2)] }
        f.script.lsp { _ in .answered([]) }
        try await f.open("a.swift")
        #expect(await f.pump { f.script.lspCalls == 1 && !f.coordinator.inFlight(path: "a.swift") })
        #expect(f.coordinator.ranges["a.swift"]?.source == .treeSitter)
    }

    @Test func windowedDocumentNeverAsksTreeSitter() async throws {
        let f = FoldRig(windowedBytes: 8)
        f.script.tree { _ in [r(0, 3)] }
        try await f.open("a.swift")
        #expect(await f.pump { f.coordinator.ranges["a.swift"] != nil })
        #expect(f.script.treeCalls == 0)
        #expect(f.coordinator.ranges["a.swift"]?.source == .indentation)
    }

    @Test func windowedDocumentUsesLSPWhenItAnswers() async throws {
        let f = FoldRig(windowedBytes: 8)
        f.script.lsp { _ in .answered([r(0, 3)]) }
        try await f.open("a.swift")
        #expect(await f.pump { f.coordinator.ranges["a.swift"]?.source == .lsp })
        #expect(f.script.treeCalls == 0)
    }

    @Test func typingBuildsOnlyOnTheSettle() async throws {
        let f = FoldRig()
        let s = try await f.open("a.txt")
        #expect(await f.pump { f.coordinator.buildCount(path: "a.txt") == 1 && !f.coordinator.inFlight(path: "a.txt") })
        for _ in 0..<20 { f.type(s, "x"); s.drainEdits() }
        #expect(f.coordinator.buildCount(path: "a.txt") == 1)
        #expect(f.rig.clock.pendingSleepers <= 1, "one sleeping task for the whole burst")
        await f.settle(s, path: "a.txt", advance: 0.1)
        for _ in 0..<20 { await Task.yield() }
        #expect(f.coordinator.buildCount(path: "a.txt") == 1, "inside the debounce still")
        f.rig.clock.advance(by: 1)
        #expect(await f.pump { f.coordinator.buildCount(path: "a.txt") == 2 })
        #expect(await f.pump { f.coordinator.ranges["a.txt"]?.version == s.document.buffer.version })
    }

    @Test func onlyOneBuildInFlight() async throws {
        let f = FoldRig()
        let gate = FoldGate()
        f.script.lsp { _ in await gate.wait(); return .answered([r(0, 2)]) }
        let s = try await f.open("a.txt")
        #expect(await f.pump { f.script.lspCalls == 1 })
        #expect(f.coordinator.inFlight(path: "a.txt"))
        f.type(s, "// c\n")
        await f.settle(s, path: "a.txt")
        #expect(await f.pump { f.script.lspCalls == 2 })
        #expect(f.coordinator.buildCount(path: "a.txt") == 2)
        gate.open()
        #expect(await f.pump { f.coordinator.ranges["a.txt"]?.source == .lsp })
        #expect(f.coordinator.ranges["a.txt"]?.version == s.document.buffer.version)
        #expect(await f.pump { !f.coordinator.inFlight(path: "a.txt") })
        #expect(f.coordinator.buildCount(path: "a.txt") == 2)
    }

    @Test func staleLSPAnswerIsDropped() async throws {
        let f = FoldRig()
        let gate = FoldGate()
        f.script.lsp { _ in await gate.wait(); return .answered([r(0, 2)]) }
        let s = try await f.open("a.txt")
        #expect(await f.pump { f.script.lspCalls == 1 })
        f.type(s, "// c\n")   // the buffer moves before the answer, and nobody told the coordinator yet
        gate.open()
        for _ in 0..<40 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(f.coordinator.ranges["a.txt"]?.source == .indentation, "nothing applied for the old version")
        await f.settle(s, path: "a.txt")
        #expect(await f.pump { f.script.lspCalls == 2 })
        #expect(await f.pump { f.coordinator.ranges["a.txt"]?.source == .lsp })
    }

    @Test func lspTimeoutKeepsTheCurrentSource() async throws {
        let f = FoldRig(lspTimeout: .milliseconds(40))
        f.script.tree { _ in [r(0, 2)] }
        f.script.lsp { _ in
            // Ignores the caller's cancellation and never answers.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return .unavailable
        }
        try await f.open("a.swift")
        #expect(await f.pump { f.script.lspCalls == 1 && !f.coordinator.inFlight(path: "a.swift") })
        #expect(f.coordinator.ranges["a.swift"]?.source == .treeSitter)
    }

    @Test func lspErrorAfterAnswerKeepsLSPRanges() async throws {
        let f = FoldRig()
        let answers = FoldAnswers([.answered([r(0, 2)]), .unavailable])
        f.script.lsp { _ in answers.next() }
        let s = try await f.open("a.txt")
        #expect(await f.pump { f.coordinator.ranges["a.txt"]?.source == .lsp })
        let state = try #require(f.workspace.foldState(for: "a.txt", in: f.pane))
        state.fold(0..<3)
        #expect(state.folded == [0..<3])
        f.type(s, "x", at: 0)
        await f.settle(s, path: "a.txt")
        #expect(await f.pump { f.script.lspCalls == 2 && !f.coordinator.inFlight(path: "a.txt") })
        #expect(f.coordinator.ranges["a.txt"]?.source == .lsp)
        #expect(state.folded == [0..<3])
    }

    @Test func incrementalIndentEqualsFullScan() async throws {
        let f = FoldRig()
        let s = try await f.open("a.txt", "a {\n  b {\n    c\n  }\n}\nd {\n  e\n}\n")
        #expect(await f.pump { f.coordinator.ranges["a.txt"] != nil && !f.coordinator.inFlight(path: "a.txt") })
        f.type(s, "x {\n  y\n}\n", at: 0)
        f.type(s, "  z\n", at: 10)
        _ = s.document.buffer.replace(0..<2, with: "", origin: .typing)
        await f.settle(s, path: "a.txt")
        let version = s.document.buffer.version
        #expect(await f.pump { f.coordinator.ranges["a.txt"]?.version == version })
        var fresh = IndentFolds(snapshot: s.document.buffer.snapshot())
        #expect(f.coordinator.ranges["a.txt"]?.ranges == fresh.ranges(in: s.document.buffer.snapshot()))
    }

    @Test func closeWhileBuildingAppliesNothing() async throws {
        let f = FoldRig()
        let gate = FoldGate()
        f.script.tree { _ in await gate.wait(); return [r(0, 3)] }
        let s = try await f.open("a.swift")
        #expect(await f.pump { f.script.treeCalls == 1 })
        s.close()
        gate.open()
        for _ in 0..<40 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(f.coordinator.ranges["a.swift"] == nil)
        #expect(f.workspace.latestFold["a.swift"] == nil)
        #expect(f.coordinator.buildCount(path: "a.swift") == 0)
        #expect(!f.coordinator.inFlight(path: "a.swift"))
    }

    @Test func replacedDocumentRestartsTheEntry() async throws {
        let f = FoldRig()
        let first = try await f.open("a.txt")
        #expect(await f.pump { f.coordinator.ranges["a.txt"] != nil })
        let old = first.document
        let fresh = EditorDocument(path: "a.txt", buffer: CodeBuffer(utf8: Array("p {\n  q\n  r\n}\n".utf8)), language: nil,
                                   state: .editable, diskStamp: old.diskStamp)
        f.workspace.documents["a.txt"] = fresh
        first.close()
        let second = DocumentServices(document: fresh, engine: f.engine)
        second.attachFolds(f.coordinator)
        #expect(await f.pump { f.coordinator.ranges["a.txt"]?.version == fresh.buffer.version })
        #expect(f.coordinator.buildCount(path: "a.txt") == 1)
        #expect(f.coordinator.ranges["a.txt"]?.ranges == [r(0, 2)])
        withExtendedLifetime(second) {}
    }

    @Test func replacedDocumentDropsOldLSPRanges() async throws {
        let f = FoldRig()
        let answers = FoldAnswers([.answered([r(0, 1)]), .unavailable])
        f.script.lsp { _ in answers.next() }
        let first = try await f.open("a.txt")
        #expect(await f.pump { f.coordinator.ranges["a.txt"]?.source == .lsp && !f.coordinator.inFlight(path: "a.txt") })
        let old = first.document
        let fresh = EditorDocument(path: "a.txt", buffer: CodeBuffer(utf8: Array("p {\n  q\n  r\n}\n".utf8)), language: nil,
                                   state: .editable, diskStamp: old.diskStamp)
        f.workspace.documents["a.txt"] = fresh
        let second = DocumentServices(document: fresh, engine: f.engine)
        second.attachFolds(f.coordinator)
        #expect(await f.pump { f.script.lspCalls == 2 && !f.coordinator.inFlight(path: "a.txt") })
        #expect(f.coordinator.ranges["a.txt"]?.source == .indentation)
        #expect(f.coordinator.ranges["a.txt"]?.ranges == [r(0, 2)])
        withExtendedLifetime((first, second)) {}
    }

    @Test func savingAsksAgain() async throws {
        let f = FoldRig()
        f.script.lsp { _ in .answered([r(0, 2)]) }
        try await f.open("a.txt")
        #expect(await f.pump { f.script.lspCalls == 1 && !f.coordinator.inFlight(path: "a.txt") })
        f.coordinator.settled(path: "a.txt")
        #expect(await f.pump { f.script.lspCalls == 2 })
    }
}

final class FoldAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FoldingOutcome]
    init(_ items: [FoldingOutcome]) { self.items = items }
    func next() -> FoldingOutcome { lock.withLock { items.count > 1 ? items.removeFirst() : (items.first ?? .unavailable) } }
}
