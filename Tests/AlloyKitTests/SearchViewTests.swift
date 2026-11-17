@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct SearchViewTests {
    private func codeWindow(_ files: [String: String] = ["a.swift": "let alpha = 1\nlet beta = 2\n", "b.swift": "beta again\nno\nbeta beta\n"]) async throws -> (Rig, TestWindow) {
        let rig = Rig()
        for (f, text) in files { try text.write(to: rig.root.appendingPathComponent(f), atomically: true, encoding: .utf8) }
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        rig.workspace.codeLayout.sidebarTab = .search
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "search-query")) != nil }
        settle(window)
        return (rig, window)
    }

    private func settle(_ window: TestWindow) { for _ in 0..<4 { window.tick() } }
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    private func text(_ window: TestWindow, _ id: String) -> String? {
        guard let element = try? window.element(identifier: id) else { return nil }
        return element.value ?? element.label
    }

    /// Types `query` into the field and presses Return, then waits for the run to finish.
    private func search(_ rig: Rig, _ window: TestWindow, _ query: String) async throws {
        try window.click(window.element(identifier: "search-query"))
        window.typeText(query)
        window.typeKey(.return)
        try await window.runUntil { rig.workspace.search.facts != nil && !rig.workspace.search.isRunning }
        settle(window)
    }

    @Test func typingRendersGroupsPreviewsAndSummary() async throws {
        let (rig, window) = try await codeWindow()
        try await search(rig, window, "beta")
        _ = try window.element(identifier: "search-file-0")
        _ = try window.element(identifier: "search-file-1")
        _ = try window.element(identifier: "search-line-0-0")
        _ = try window.element(identifier: "search-line-1-1")
        #expect(text(window, "search-summary") == "4 results in 2 files")
        #expect(rig.workspace.search.groups.map(\.path) == ["a.swift", "b.swift"])
    }

    @Test func anInvalidRegexShowsTheErrorInline() async throws {
        let (rig, window) = try await codeWindow()
        try window.click(window.element(identifier: "search-opt-regex")); settle(window)
        try window.click(window.element(identifier: "search-query"))
        window.typeText("(")
        window.typeKey(.return)
        settle(window)
        _ = try window.element(identifier: "search-error")
        #expect(rig.workspace.search.runCount == 0)
        #expect(!exists(window, "search-file-0"))
    }

    @Test func clickingAPreviewOpensTheFileWithTheMatchSelected() async throws {
        let (rig, window) = try await codeWindow()
        try await search(rig, window, "alpha")
        try window.click(window.element(identifier: "search-line-0-0"))
        try await window.runUntil { rig.workspace.codeLayout.focusedGroup.activeTab == "a.swift" }
        let pane = rig.workspace.defaultPane
        try await window.runUntil { rig.workspace.selectionState(for: "a.swift", in: pane)?.selections.first?.range == 4..<9 }
    }

    @Test func movedTextSelectsTheStartOfTheStoredLine() async throws {
        let (rig, window) = try await codeWindow(["a.swift": "one\ntwo beta\n"])
        try await search(rig, window, "beta")
        try "zero\none\ntwo gamma\n".write(to: rig.root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try window.click(window.element(identifier: "search-line-0-0"))
        try await window.runUntil { rig.workspace.codeLayout.focusedGroup.activeTab == "a.swift" }
        let pane = rig.workspace.defaultPane
        try await window.runUntil { rig.workspace.selectionState(for: "a.swift", in: pane)?.selections.first?.range == 5..<5 }
    }

    @Test func arrowsMoveTheSelectionAndReturnOpens() async throws {
        let (rig, window) = try await codeWindow()
        try await search(rig, window, "beta")
        window.typeKey(.downArrow)
        window.typeKey(.downArrow)
        settle(window)
        #expect(rig.workspace.search.selection == SearchSelection(file: 0, line: 0) || rig.workspace.search.selection == SearchSelection(file: 1, line: 0))
        #expect(rig.workspace.search.selection == SearchSelection(file: 1, line: 0))
        window.typeKey(.upArrow)
        #expect(rig.workspace.search.selection == SearchSelection(file: 0, line: 0))
        window.typeKey(.downArrow)
        window.typeKey(.return)
        try await window.runUntil { rig.workspace.codeLayout.focusedGroup.activeTab == "b.swift" }
        #expect(rig.workspace.search.runCount == 1, "Return on a selection opens it and does not re-run")
    }

    @Test func escapeCancelsARunningSearch() async throws {
        let (rig, window) = try await codeWindow()
        let gate = SearchScanGate()
        rig.workspace.search.scanGate = { _ in await gate.hold() }
        try window.click(window.element(identifier: "search-query"))
        window.typeText("beta")
        window.typeKey(.return)
        await gate.waitUntilEntered()
        settle(window)
        #expect(text(window, "search-summary") == "searching…")
        window.typeKey(.escape)
        settle(window)
        #expect(!rig.workspace.search.isRunning)
        await gate.release()
        settle(window)
        #expect(rig.workspace.search.groups.isEmpty)
    }

    @Test func aChangeShowsTheRerunLinkAndClickingItRuns() async throws {
        let (rig, window) = try await codeWindow()
        try await search(rig, window, "beta")
        #expect(!exists(window, "search-rerun"))
        rig.workspace.search.noteChanged("a.swift")
        settle(window)
        try window.click(window.element(identifier: "search-rerun"))
        try await window.runUntil { rig.workspace.search.runCount == 2 && !rig.workspace.search.isRunning }
        settle(window)
        #expect(!exists(window, "search-rerun"))
    }

    @Test func findInFilesSeedsFromASingleLineSelectionOnly() async throws {
        let (rig, window) = try await codeWindow()
        rig.workspace.codeLayout.sidebarTab = .files
        await rig.workspace.open("a.swift")
        let pane = rig.workspace.defaultPane
        try await window.runUntil { rig.workspace.selectionState(for: "a.swift", in: pane) != nil }
        rig.workspace.selectionState(for: "a.swift", in: pane)?.select(4..<9)
        rig.workspace.showSearch(replace: false)
        try await window.runUntil { rig.workspace.search.query.text == "alpha" }
        try await window.runUntil { rig.workspace.search.facts != nil }
        rig.workspace.selectionState(for: "a.swift", in: pane)?.select(0..<20)      // spans two lines
        rig.workspace.showSearch(replace: false)
        settle(window)
        #expect(rig.workspace.search.query.text == "alpha")
    }

    /// Appending a batch must not rebuild the rows already built: every row body runs about once per visible row, not
    /// once per batch. (If MetalUI's `List` relaid out existing rows on append, this is the conditional MetalUI gap.)
    @Test func appendingABatchDoesNotRebuildExistingRows() async throws {
        let (rig, window) = try await codeWindow(["seed.txt": "x\n"])
        for i in 0..<300 { try "needle \(i)\n".write(to: rig.root.appendingPathComponent("hit\(i).txt"), atomically: true, encoding: .utf8) }
        let model = rig.workspace.search
        model.limits.flushMatches = 10
        model.limits.flushInterval = .milliseconds(1)
        let before = BodyProbe.count("SearchResultRow")
        try window.click(window.element(identifier: "search-query"))
        window.typeText("needle")
        window.typeKey(.return)
        var ticks = 0
        while (model.facts == nil || model.isRunning) && ticks < 20_000 { window.tick(); await Task.yield(); ticks += 1 }
        for _ in 0..<6 { window.tick(); await Task.yield() }
        #expect(model.groups.count == 300)
        let visible = (try window.elements { ($0.identifier ?? "").hasPrefix("search-file-") }).count
        let built = BodyProbe.count("SearchResultRow") - before
        #expect(visible > 0)
        #expect(built <= visible * 2, "\(built) row bodies for \(visible) visible rows after \(model.landedCount) batches")
        print("SEARCH rows built=\(built) visible=\(visible) batches=\(model.landedCount)")
    }

    @Test func goNextResultStepsFromTheEditor() async throws {
        let (rig, window) = try await codeWindow()
        try await search(rig, window, "beta")
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "go-next-result")
        try await window.runUntil { rig.workspace.codeLayout.focusedGroup.activeTab == "a.swift" }
        #expect(rig.workspace.search.selection == SearchSelection(file: 0, line: 0))
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "go-next-result")
        #expect(rig.workspace.search.selection == SearchSelection(file: 1, line: 0))
    }
}

/// Holds the first scanning worker until released.
actor SearchScanGate {
    private var entered = false, open = false, first = true
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        guard first else { return }
        first = false; entered = true
        if open { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { open = true; waiter?.resume(); waiter = nil }
}
