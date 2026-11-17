@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

@MainActor @Suite struct WorkspaceReplaceReviewTests {
    private func makePlan(_ e: Env, _ names: [String]) throws -> ReplacePlan {
        let query = SearchQuery(text: "foo")
        let matcher = try query.compile()
        let files = names.map { ReplaceFile(path: $0, matches: matcher.scan(Array(e.read($0).utf8)).matches) }
        return ReplacePlan(files: files, query: query, template: "bar")
    }

    private func setup(_ e: Env) async throws -> ReplaceReport {
        for n in ["a.txt", "b.txt", "c.txt"] { e.write(n, "one foo\n") }
        await e.ws.settle()
        let report = await e.ws.replace(try makePlan(e, ["a.txt", "b.txt", "c.txt"]))
        await e.ws.settle()
        return report
    }

    @Test func keepAllMarksGroupKeptWithOnePersist() async throws {
        let e = Env(); defer { e.cleanup() }
        let report = try await setup(e)
        let before = e.ws.ledgerPersistCount
        await e.ws.keepAll(group: report.group)
        #expect(e.ws.ledgerPersistCount == before + 1)
        for n in ["a.txt", "b.txt", "c.txt"] {
            #expect(e.ws.ledger.files[n]?.edits.allSatisfy { $0.state == .kept } == true)
        }
        #expect(e.ws.changedFiles.isEmpty)
    }

    @Test func revertAllRestoresDiskAndLedgerWithOnePersist() async throws {
        let e = Env(); defer { e.cleanup() }
        let report = try await setup(e)
        #expect(Set(e.ws.changedFiles.map(\.path)) == ["a.txt", "b.txt", "c.txt"])
        let before = e.ws.ledgerPersistCount
        let results = await e.ws.revertAll(group: report.group)
        await e.ws.settle()
        #expect(e.ws.ledgerPersistCount == before + 1)
        #expect(results.count == 3)
        for r in results { if case .reverted = r.outcome {} else { Issue.record("not reverted: \(r)") } }
        for n in ["a.txt", "b.txt", "c.txt"] { #expect(e.read(n) == "one foo\n") }
    }

    @Test func revertConflictKeepsThatFile() async throws {
        let e = Env(); defer { e.cleanup() }
        let report = try await setup(e)
        // Edited since: a later change to the same line.
        e.write("b.txt", "one baz\n")
        let results = await e.ws.revertAll(group: report.group)
        await e.ws.settle()
        let byPath = Dictionary(uniqueKeysWithValues: results.map { ($0.path, $0.outcome) })
        if case .conflict = byPath["b.txt"] {} else { Issue.record("expected conflict: \(String(describing: byPath["b.txt"]))") }
        if case .reverted = byPath["a.txt"] {} else { Issue.record("a not reverted") }
        #expect(e.read("a.txt") == "one foo\n")
    }
}
