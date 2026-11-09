import Foundation
import Observation
import Testing
@testable import AlloyCore

/// What the tab strip reads per tab must not be recomputed (or re-notified) on every keystroke.
@MainActor
@Suite struct TabStateTests {
    @Test func lastSessionEditorIsScannedOncePerLedgerVersion() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\n")
        await e.ws.open("a.txt")
        let session = await e.ws.newSession(name: "Ann")
        try await e.sessionEdit("a.txt", old: "one\ntwo\n", new: "one\nTWO\n")
        await waitUntil("session record") { e.ws.ledger.files["a.txt"] != nil }
        await e.ws.settle()
        let before = e.ws.editorScans
        for _ in 0..<20 { #expect(e.ws.lastSessionEditor(of: "a.txt") == .session(session.id)) }
        #expect(e.ws.editorScans - before <= 1, "scans \(e.ws.editorScans - before)")
        // Typing does not touch the ledger: still no rescan.
        let doc = try #require(e.ws.document("a.txt"))
        doc.buffer.replace(0..<0, with: "x")
        for _ in 0..<20 { _ = e.ws.lastSessionEditor(of: "a.txt") }
        #expect(e.ws.editorScans - before <= 1)
        // A new ledger version scans again, and the answer follows it.
        try await e.sessionEdit("a.txt", old: "one\nTWO\n", new: "one\nTWO\nthree\n", id: "t2")
        await waitUntil("second record") { e.ws.ledger.files["a.txt"]?.edits.count ?? 0 >= 2 }
        await e.ws.settle()
        #expect(e.ws.lastSessionEditor(of: "a.txt") == .session(session.id))
        #expect(e.ws.editorScans - before == 2)
    }

    @Test func tabDirtyChangesOnlyOnCleanDirtyTransitions() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        #expect(!doc.tabDirty)
        doc.buffer.replace(0..<0, with: "a")
        await waitUntil("dirty flag") { doc.tabDirty }
        // Further keystrokes leave the flag alone, so nothing that reads it re-renders.
        let notified = Counter()
        withObservationTracking { _ = doc.tabDirty } onChange: { notified.bump() }
        for i in 0..<10 { doc.buffer.replace(0..<0, with: "k\(i)") }
        for _ in 0..<2_000 { await Task.yield() }
        #expect(notified.count == 0)
        #expect(doc.isDirty)
        try await e.ws.save("a.txt")
        await waitUntil("clean flag") { !doc.tabDirty }
        #expect(!doc.isDirty)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}
