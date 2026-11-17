@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct SearchPolishTests {
    private func rig(_ files: [String: Data]) throws -> Rig {
        let rig = Rig()
        for (name, data) in files { try data.write(to: rig.root.appendingPathComponent(name)) }
        return rig
    }

    private func text(_ s: String) -> Data { Data(s.utf8) }

    private func until(_ what: String, _ cond: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !cond() {
            if ContinuousClock.now > deadline { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func runQuery(_ rig: Rig, _ q: SearchQuery) async throws {
        let model = rig.workspace.search
        model.setQuery(q)
        model.submit()
        try await until("finished run") { model.facts != nil && !model.isRunning }
    }

    private func read(_ rig: Rig, _ name: String) -> Data {
        (try? Data(contentsOf: rig.root.appendingPathComponent(name))) ?? Data()
    }

    @Test func summaryShowsEachNoteOnceInAStableOrder() async throws {
        var files: [String: Data] = [:]
        for i in 0..<120 { files["f\(i).txt"] = text("foo\n") }
        files["bin.dat"] = Data([0x66, 0x6f, 0x6f, 0x00, 0x01])
        let rig = try rig(files)
        var settings = rig.workspace.settings
        settings.searchMaxResults = AlloySettings.searchResultRange.lowerBound
        try rig.workspace.updateSettings(settings, persist: false)
        try await runQuery(rig, SearchQuery(text: "foo"))
        let summary = rig.workspace.search.summary
        let parts = summary.components(separatedBy: " · ")
        #expect(parts.count == 2, "summary: \(summary)")
        #expect(parts.first?.hasSuffix("results, refine the query") == true)
        #expect(parts.last == "1 file skipped (binary, large or slow)")
        #expect(summary.components(separatedBy: "skipped").count == 2)
        #expect(summary.components(separatedBy: "refine").count == 2)
        // The same facts, the same text.
        #expect(rig.workspace.search.summary == summary)
    }

    @Test func closingTheProjectMidSearchLeavesNoRunningTask() async throws {
        let rig = try rig(["a.txt": text("foo\n"), "b.txt": text("foo\n")])
        let model = rig.workspace.search
        model.scanGate = { _ in try? await Task.sleep(for: .seconds(30)) }
        model.setQuery(SearchQuery(text: "foo"))
        model.submit()
        try await until("a run") { model.isRunning }
        await rig.workspace.stopAll()
        #expect(!model.isRunning)
        await rig.workspace.settle()
        #expect(model.groups.isEmpty)
    }

    @Test func escapeCancelsButClearsNothing() async throws {
        let rig = try rig(["a.txt": text("foo\n"), "b.txt": text("foo\n")])
        let model = rig.workspace.search
        try await runQuery(rig, SearchQuery(text: "foo"))
        let before = model.groups
        model.cancel()
        #expect(model.groups == before)
        #expect(model.query.text == "foo")

        // Mid-run: results found so far stay, the run stops.
        let gate = PolishGate()
        model.scanGate = { path in if path == "b.txt" { await gate.wait() } }
        model.submit()
        try await until("a first batch") { model.groups.count >= 1 && model.isRunning }
        model.cancel()
        #expect(!model.isRunning)
        #expect(model.isStopped)
        #expect(model.groups.count >= 1)
        #expect(model.query.text == "foo")
        await gate.open()
        await rig.workspace.settle()
    }

    @Test func clearingTheFieldCancelsAndEmptiesTheResults() async throws {
        let rig = try rig(["a.txt": text("foo\n")])
        let model = rig.workspace.search
        try await runQuery(rig, SearchQuery(text: "foo"))
        #expect(!model.groups.isEmpty)
        model.setQuery(SearchQuery(text: ""))
        #expect(model.groups.isEmpty)
        #expect(model.matchCount == 0)
        #expect(model.facts == nil)
        #expect(!model.isRunning)
        #expect(model.summary == "")
    }

    @Test func crlfAndMultibyteFilesSearchAndReplaceEndToEnd() async throws {
        let rig = try rig([
            "crlf.txt": text("one foo\r\ntwo foo\r\n"),
            "emoji.txt": text("😀 e\u{301} 日本 foo 😀 foo\n"),
        ])
        let model = rig.workspace.search
        try await runQuery(rig, SearchQuery(text: "foo"))
        #expect(model.matchCount == 4)
        #expect(!model.groups.flatMap(\.matches).contains { $0.preview.contains("\r") })
        model.replacement = "bar"
        model.replaceAll()
        try await until("review") { model.review != nil }
        #expect(String(decoding: read(rig, "crlf.txt"), as: UTF8.self) == "one bar\r\ntwo bar\r\n")
        #expect(String(decoding: read(rig, "emoji.txt"), as: UTF8.self) == "😀 e\u{301} 日本 bar 😀 bar\n")
        await rig.workspace.settle()
    }

    @Test func aHiddenSearchTabStartsNoTaskOnFileEvents() async throws {
        let rig = try rig(["a.txt": text("foo\n")])
        rig.workspace.setMode(.code)
        #expect(rig.workspace.codeLayout.sidebarTab != .search)
        let model = rig.workspace.search
        model.noteChanged("a.txt")
        model.tabShown()
        try text("foo foo\n").write(to: rig.root.appendingPathComponent("a.txt"))
        await rig.workspace.settle()
        #expect(model.runCount == 0)
        #expect(!model.isRunning)
        #expect(model.groups.isEmpty)
    }
}

private actor PolishGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; for w in waiters { w.resume() }; waiters = [] }
}
