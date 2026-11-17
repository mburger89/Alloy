@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Observation
import Testing

@MainActor private final class LedgerWatch {
    let ws: Workspace
    var count = 0
    init(_ ws: Workspace) { self.ws = ws }
    func arm() {
        withObservationTracking({ _ = ws.ledger }, onChange: { MainActor.assumeIsolated { self.count += 1; self.arm() } })
    }
}

@MainActor @Suite struct WorkspaceReplaceClosedTests {
    private func makePlan(_ e: Env, _ names: [String], find: String = "foo", with template: String = "bar") throws -> ReplacePlan {
        let query = SearchQuery(text: find)
        let matcher = try query.compile()
        let files = names.map { n in
            ReplaceFile(path: n, matches: matcher.scan(Array(e.read(n).utf8)).matches)
        }
        return ReplacePlan(files: files, query: query, template: template)
    }

    @Test func replacesThreeClosedFilesInOneGroup() async throws {
        let e = Env(); defer { e.cleanup() }
        for n in ["a.txt", "b.txt", "c.txt"] { e.write(n, "one foo\ntwo foo\n") }
        await e.ws.settle()
        let plan = try makePlan(e, ["a.txt", "b.txt", "c.txt"])
        let before = e.ws.ledgerPersistCount
        let report = await e.ws.replace(plan)
        await e.ws.settle()
        for n in ["a.txt", "b.txt", "c.txt"] { #expect(e.read(n) == "one bar\ntwo bar\n") }
        #expect(report.perFile.map(\.outcome) == Array(repeating: .applied(edits: 2), count: 3))
        #expect(e.ws.ledgerPersistCount == before + 1)
        var groups = Set<UUID?>()
        for n in ["a.txt", "b.txt", "c.txt"] {
            let edits = try #require(e.ws.ledger.files[n]).edits
            #expect(edits.map(\.author) == [.user])
            groups.insert(edits[0].group)
        }
        #expect(groups == [report.group])
    }

    /// A ledger batch tells observers once. Each notification costs the window a frame, so a notification per file
    /// made Replace All over 200 files take seconds (a frame per file); it must stay a constant.
    @Test func replaceAcross200FilesNotifiesLedgerObserversOnce() async throws {
        let e = Env(); defer { e.cleanup() }
        let names = (0..<200).map { "f\($0).txt" }
        for n in names { e.write(n, "one foo\n") }
        await e.ws.settle()
        let plan = try makePlan(e, names)
        let watch = LedgerWatch(e.ws)
        watch.arm()
        let before = e.ws.ledgerPersistCount
        let report = await e.ws.replace(plan)
        await Task.yield()
        #expect(report.perFile.count == 200)
        #expect(report.perFile.allSatisfy { $0.outcome == .applied(edits: 1) })
        #expect(watch.count == 1, "ledger observers were notified \(watch.count) times")
        #expect(e.ws.ledgerPersistCount == before + 1)
        #expect(e.ws.ledger.files.count == 200)
    }

    @Test func watcherAttributesNothingOutside() async throws {
        let e = Env(); defer { e.cleanup() }
        for n in ["a.txt", "b.txt"] { e.write(n, "foo\n") }
        await e.ws.settle()
        let plan = try makePlan(e, ["a.txt", "b.txt"])
        _ = await e.ws.replace(plan)
        await e.ws.settle()
        await e.fire(["a.txt", "b.txt"])
        for n in ["a.txt", "b.txt"] {
            #expect(e.ws.ledger.files[n]?.edits.map(\.author) == [.user])
        }
    }

    @Test func fileChangedSinceSearchIsSkipped() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "foo\n"); e.write("b.txt", "foo\n")
        let plan = try makePlan(e, ["a.txt", "b.txt"])
        e.write("a.txt", "xx foo\n")
        let report = await e.ws.replace(plan)
        #expect(report.perFile[0].outcome == .skipped(reason: "changed since search"))
        #expect(report.perFile[1].outcome == .applied(edits: 1))
        #expect(e.read("a.txt") == "xx foo\n")
        #expect(e.ws.ledger.files["a.txt"] == nil)
    }

    @Test func fileModifiedDuringWriteIsReportedAndLedgerUnchanged() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "foo\n")
        let plan = try makePlan(e, ["a.txt"])
        let url = e.url("a.txt")
        e.ws.replaceWriteGate = { _ in
            try? "foo\nmore\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let report = await e.ws.replace(plan)
        #expect(report.perFile[0].outcome == .skipped(reason: "changed during replace"))
        #expect(e.read("a.txt") == "foo\nmore\n")
        #expect(e.ws.ledger.files["a.txt"] == nil)
    }

    @Test func goneAndRenamedFilesAreSkipped() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "foo\n"); e.write("b.txt", "foo\n")
        let plan = try makePlan(e, ["a.txt", "b.txt"])
        try FileManager.default.removeItem(at: e.url("a.txt"))
        let report = await e.ws.replace(plan)
        guard case .skipped = report.perFile[0].outcome else { Issue.record("a.txt not skipped"); return }
        #expect(report.perFile[1].outcome == .applied(edits: 1))
    }

    @Test func caseOnlyRenameCountsAsGone() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "foo\n")
        let plan = try makePlan(e, ["a.txt"])
        try FileManager.default.moveItem(at: e.url("a.txt"), to: e.url("A.txt"))
        let report = await e.ws.replace(plan)
        guard case .skipped = report.perFile[0].outcome else { Issue.record("not skipped"); return }
        #expect(e.read("A.txt") == "foo\n")
    }

    @Test func openingAfterwardsRecordsNothing() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "foo\n")
        let plan = try makePlan(e, ["a.txt"])
        _ = await e.ws.replace(plan)
        await e.ws.settle()
        let edits = e.ws.ledger.files["a.txt"]?.edits.count
        await e.ws.open("a.txt")
        await e.ws.settle()
        #expect(e.ws.ledger.files["a.txt"]?.edits.count == edits)
        #expect(e.ws.document("a.txt")?.buffer.snapshot().text(in: 0..<7) == "bar\n")
    }

    @Test func unseenLedgerDifferenceIsRecordedAsOutsideFirst() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "x")
        try await e.ws.save("a.txt")
        await e.ws.close("a.txt")
        e.write("a.txt", "xone foo\n")   // changed outside, not yet seen
        let plan = try makePlan(e, ["a.txt"])
        let report = await e.ws.replace(plan)
        let edits = try #require(e.ws.ledger.files["a.txt"]).edits
        #expect(edits.last?.author == .user)
        #expect(edits.last?.group == report.group)
        #expect(edits.dropLast().last?.group == nil)
        #expect(edits.count == 3)
    }

    @Test func nestedBatchPersistsOnce() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "foo\n"); e.write("b.txt", "foo\n")
        let before = e.ws.ledgerPersistCount
        await e.ws.withLedgerBatch {
            await e.ws.withLedgerBatch {
                await e.ws.appendToLedger("a.txt", saved: nil, baseline: "foo\n", edits: [(.user, "x\n")])
            }
            #expect(e.ws.ledgerPersistCount == before)
            await e.ws.appendToLedger("b.txt", saved: nil, baseline: "foo\n", edits: [(.user, "y\n")])
        }
        #expect(e.ws.ledgerPersistCount == before + 1)
    }

    @Test func emptyBatchDoesNotPersist() async {
        let e = Env(); defer { e.cleanup() }
        let before = e.ws.ledgerPersistCount
        await e.ws.withLedgerBatch {}
        #expect(e.ws.ledgerPersistCount == before)
    }

    @Test func closingProjectStopsAfterFileInFlight() async throws {
        let e = Env(); defer { e.cleanup() }
        for n in ["a.txt", "b.txt", "c.txt"] { e.write(n, "foo\n") }
        let plan = try makePlan(e, ["a.txt", "b.txt", "c.txt"])
        let ws = e.ws
        e.ws.replaceWriteGate = { path in
            if path == "a.txt" { await ws.stopAll() }
        }
        let report = await e.ws.replace(plan)
        #expect(report.perFile.count == 1)
        #expect(e.read("a.txt") == "bar\n")
        #expect(e.read("b.txt") == "foo\n")
        #expect(e.ws.ledger.files["a.txt"]?.edits.count == 1)
    }
}
