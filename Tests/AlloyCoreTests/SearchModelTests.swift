@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Observation
import Testing

@MainActor
@Suite struct SearchModelTests {
    private func env(_ files: [String: String] = ["a.txt": "alpha beta\n", "b.txt": "beta gamma\nbeta\n"]) -> Env {
        let e = Env()
        for (name, text) in files {
            try? FileManager.default.createDirectory(at: e.url(name).deletingLastPathComponent(), withIntermediateDirectories: true)
            e.write(name, text)
        }
        return e
    }

    private func query(_ text: String, regex: Bool = false) -> SearchQuery { SearchQuery(text: text, regex: regex) }

    /// Waits until a batch landed after `landed`.
    private func landed(_ model: SearchModel, after landed: Int) async {
        await waitUntil("a batch") { model.landedCount > landed }
    }

    private func finished(_ model: SearchModel) async {
        await waitUntil("finished run") { model.facts != nil && !model.isRunning }
    }

    // MARK: Triggering

    @Test func typingRunsAfterTheDebounceAndReturnRunsAtOnce() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        model.setQuery(query("beta"))
        #expect(model.runCount == 0)
        e.clock.advance(by: 0.1)
        await Task.yield()
        #expect(model.runCount == 0)
        await waitUntil("debounce sleeper") { e.clock.pendingSleepers > 0 }
        e.clock.advance(by: 0.15)
        await finished(model)
        #expect(model.runCount == 1)
        #expect(model.groups.map(\.path) == ["a.txt", "b.txt"])
        // Return: no waiting for the clock.
        var q = model.query; q.text = "gamma"
        model.setQuery(q)
        model.submit()
        await finished(model)
        #expect(model.runCount == 2)
        #expect(model.groups.map(\.path) == ["b.txt"])
    }

    @Test func aTruncatedIndexRunsOnlyOnReturn() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        model.indexTruncated = true
        model.setQuery(query("beta"))
        #expect(e.clock.pendingSleepers == 0)
        e.clock.advance(by: 1)
        await Task.yield()
        #expect(model.runCount == 0)
        model.submit()
        await finished(model)
        #expect(model.runCount == 1)
        // The run read the real index state back.
        #expect(model.indexTruncated == false)
    }

    @Test func anEmptyQueryRunsNothingAndClearsResults() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        model.setQuery(query("beta")); model.submit()
        await finished(model)
        #expect(!model.groups.isEmpty)
        model.setQuery(SearchQuery())
        #expect(model.groups.isEmpty && model.summary == "" && !model.isRunning)
        #expect(model.runCount == 1)
        model.submit()
        #expect(model.runCount == 1)
    }

    @Test func anInvalidRegexSetsTheErrorAndRunsNothing() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        let before = model.landedCount
        model.setQuery(query("(", regex: true)); model.submit()
        #expect(model.error != nil && model.groups.isEmpty && !model.isRunning)
        #expect(model.runCount == 0 && model.landedCount == before)
        model.setQuery(query("beta", regex: true)); model.submit()
        await finished(model)
        #expect(model.error == nil && model.groups.count == 2)
    }

    @Test func aNewQueryCancelsThePreviousRun() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        let gate = TestGate()
        model.scanGate = { _ in await gate.hold() }
        model.setQuery(query("alpha")); model.submit()
        await gate.waitUntilEntered()
        model.setQuery(query("gamma")); model.submit()
        await finished(model)
        await gate.release()
        await e.ws.settle()
        #expect(model.groups.map(\.path) == ["b.txt"])
        #expect(model.query.text == "gamma")
    }

    @Test func shutdownCancelsTheRun() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        let gate = TestGate()
        model.scanGate = { _ in await gate.hold() }
        model.setQuery(query("beta")); model.submit()
        await gate.waitUntilEntered()
        model.shutdown()
        #expect(!model.isRunning)
        await gate.release()
        await e.ws.settle()
        #expect(model.groups.isEmpty)
    }

    @Test func escapeKeepsWhatHasLandedAndStops() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        let gate = TestGate()
        model.scanGate = { _ in await gate.hold() }
        model.setQuery(query("beta")); model.submit()
        await gate.waitUntilEntered()
        #expect(model.isRunning && model.summary == "searching…")
        model.cancel()
        #expect(!model.isRunning)
        #expect(model.summary == "Stopped")
        await gate.release()
        await e.ws.settle()
        #expect(model.groups.isEmpty)
    }

    // MARK: Summary

    @Test func summaryTexts() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        model.setQuery(query("beta")); model.submit()
        await finished(model)
        #expect(model.summary == "3 results in 2 files")
        model.setQuery(query("alpha")); model.submit()
        await finished(model)
        #expect(model.summary == "1 result in 1 file")
        model.setQuery(query("zzz")); model.submit()
        await finished(model)
        #expect(model.summary == "No results")
        model.setQuery(query("^", regex: true)); model.submit()
        await finished(model)
        #expect(model.summary == "Regex matches only empty text")
    }

    @Test func groupingAndCapAndSkipNotes() {
        #expect(SearchModel.grouped(1204) == "1,204")
        #expect(SearchModel.grouped(999) == "999")
        #expect(SearchModel.grouped(10_000) == "10,000")
    }

    @Test func capAndTruncationAndSkippedAreStated() async {
        var files: [String: String] = [:]
        for i in 0..<40 { files["f\(i).txt"] = "hit\nhit\nhit\n" }
        files["bin.dat"] = "hit\0hit"
        let e = env(files); defer { e.cleanup() }
        var settings = e.ws.settings
        settings.searchMaxResults = 100
        try? e.ws.updateSettings(settings, persist: false)
        let model = e.ws.search
        model.setQuery(query("hit")); model.submit()
        await finished(model)
        #expect(model.summary == "100+ results, refine the query · 1 file skipped (binary, large or slow)")
    }

    // MARK: Stale

    @Test func noteChangedDoesNothingWithoutFinishedResults() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        model.noteChanged("a.txt")
        #expect(!model.isStale)
        model.setQuery(query("beta")); model.submit()
        model.noteChanged("a.txt")           // still running: remembered, not flagged yet
        #expect(!model.isStale)
        await finished(model)
        #expect(model.isStale)               // out of date at landing time
    }

    @Test func aChangeAfterAFinishedRunMarksStale() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        model.setQuery(query("beta")); model.submit()
        await finished(model)
        #expect(!model.isStale)
        model.noteChanged("a.txt")
        #expect(model.isStale)
    }

    @Test func theFirstChangeMarksStaleOnceAndLaterOnesAreSilent() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        model.setQuery(query("beta")); model.submit()
        await finished(model)
        let fired = FireCount()
        func watch() { withObservationTracking { _ = model.isStale } onChange: { fired.n += 1 } }
        watch()
        model.noteChanged("a.txt")
        #expect(fired.n == 1 && model.isStale)
        watch()
        for _ in 0..<100 { model.noteChanged("b.txt") }
        #expect(fired.n == 1)
        // A re-run clears it and re-arms.
        model.rerun()
        await finished(model)
        #expect(!model.isStale)
        model.noteChanged("a.txt")
        #expect(model.isStale)
    }

    @Test func showingTheTabWithStaleResultsReruns() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        model.setQuery(query("beta")); model.submit()
        await finished(model)
        model.tabShown()
        #expect(model.runCount == 1)
        model.noteChanged("a.txt")
        model.tabShown()
        #expect(model.runCount == 2)
    }

    @Test func aStaleIndexIsRefreshedOnceBeforeASearch() async throws {
        let e = env(["a.txt": "beta\n"]); defer { e.cleanup() }
        let model = e.ws.search
        #expect(e.ws.fileIndexStale)
        model.setQuery(query("beta")); model.submit()
        await finished(model)
        #expect(!e.ws.fileIndexStale && model.groups.map(\.path) == ["a.txt"])
        // A new file is not seen until the flag is set again.
        e.write("c.txt", "beta\n")
        model.rerun(); await finished(model)
        #expect(model.groups.map(\.path) == ["a.txt"])
        e.ws.fileIndexStale = true
        model.rerun(); await finished(model)
        #expect(model.groups.map(\.path) == ["a.txt", "c.txt"])
        #expect(!e.ws.fileIndexStale)
    }

    @Test func hiddenSearchTabScansNothing() async {
        let e = env(); defer { e.cleanup() }
        e.ws.fileIndexStale = false
        let model = e.ws.search
        await e.fire(["a.txt", "new.txt"])
        #expect(model.runCount == 0 && model.landedCount == 0 && !model.isStale && !model.isRunning)
        #expect(e.ws.fileIndexStale, "a file list change only sets the flag")
    }

    // MARK: Results

    @Test func dismissRemovesALineAndAnEmptyFile() async throws {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        model.setQuery(query("beta")); model.submit()
        await finished(model)
        #expect(model.matchCount == 3)
        model.dismiss(file: 1, line: 0)
        let second = try #require(model.groups.dropFirst().first, "a second file group")
        #expect(second.matches.count == 1 && model.summary == "2 results in 2 files")
        model.dismiss(file: 1, line: 0)
        #expect(model.groups.map(\.path) == ["a.txt"] && model.summary == "1 result in 1 file")
        model.dismiss(file: 0)
        #expect(model.groups.isEmpty && model.matchCount == 0)
    }

    @Test func stepWrapsAndMoveSelectionClamps() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        model.setQuery(query("beta")); model.submit()
        await finished(model)
        model.moveSelection(1)
        #expect(model.selection == SearchSelection(file: 0, line: 0))
        model.moveSelection(-1)
        #expect(model.selection == SearchSelection(file: 0, line: 0))
        model.moveSelection(1); model.moveSelection(1); model.moveSelection(1); model.moveSelection(1)
        #expect(model.selection == SearchSelection(file: 1, line: 1))
        model.step(1)
        #expect(model.selection == SearchSelection(file: 0, line: 0))
        model.step(-1)
        #expect(model.selection == SearchSelection(file: 1, line: 1))
        await e.ws.settle()
        #expect(e.ws.activeTab == "b.txt" || e.ws.codeLayout.focusedGroup.activeTab == "b.txt")
    }

    @Test func stepOnNoResultsDoesNothing() {
        let e = env(); defer { e.cleanup() }
        e.ws.search.step(1)
        #expect(e.ws.search.selection == nil)
    }

    // MARK: Jump

    @Test func openingAPreviewSelectsTheRange() async throws {
        let e = env(["a.txt": "one\ntwo beta\n"]); defer { e.cleanup() }
        let model = e.ws.search
        model.setQuery(query("beta")); model.submit()
        await finished(model)
        e.ws.setMode(.code)
        model.open(file: 0, line: 0)
        await e.ws.settle()
        let pane = e.ws.defaultPane
        let state = try #require(e.ws.selectionState(for: "a.txt", in: pane))
        #expect(state.selections.first?.range == 8..<12)
    }

    @Test func movedTextFallsBackToTheStartOfTheStoredLine() async throws {
        let e = env(["a.txt": "one\ntwo beta\n"]); defer { e.cleanup() }
        let model = e.ws.search
        model.setQuery(query("beta")); model.submit()
        await finished(model)
        e.write("a.txt", "zero\none\ntwo gamma\n")       // text moved and changed
        e.ws.setMode(.code)
        model.open(file: 0, line: 0)
        await e.ws.settle()
        let state = try #require(e.ws.selectionState(for: "a.txt", in: e.ws.defaultPane))
        // Stored line 2 (1-based) starts at byte 5 now.
        #expect(state.selections.first?.range == 5..<5)
    }

    @Test func openDocumentsAreSearchedFromTheirBuffer() async throws {
        let e = env(["a.txt": "disk only\n"]); defer { e.cleanup() }
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<doc.buffer.snapshot().utf8Count, with: "unsaved needle\n")
        let model = e.ws.search
        model.setQuery(query("needle")); model.submit()
        await finished(model)
        #expect(model.groups.map(\.path) == ["a.txt"])
    }

    // MARK: Persistence

    @Test func aRunRecordsTheLastSearchButTypingDoesNot() async {
        let e = env(); defer { e.cleanup() }
        let model = e.ws.search
        model.indexTruncated = true
        model.setQuery(query("bet"))
        model.setQuery(query("beta"))
        #expect(e.ws.lastSearch == nil)
        model.submit()
        await finished(model)
        #expect(e.ws.lastSearch == query("beta"))
    }
}

final class FireCount: @unchecked Sendable { var n = 0 }
