@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct SearchReplaceViewTests {
    private func codeWindow(_ files: [String: String]) async throws -> (Rig, TestWindow) {
        let rig = Rig()
        for (f, text) in files { try text.write(to: rig.root.appendingPathComponent(f), atomically: true, encoding: .utf8) }
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        rig.workspace.codeLayout.sidebarTab = .search
        rig.workspace.searchReplaceRevealed = true
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "search-replace-all")) != nil }
        settle(window)
        return (rig, window)
    }

    private func settle(_ window: TestWindow) { for _ in 0..<4 { window.tick() } }
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }
    private func text(_ window: TestWindow, _ id: String) -> String? {
        guard let element = try? window.element(identifier: id) else { return nil }
        return element.value ?? element.label
    }
    private func read(_ rig: Rig, _ name: String) -> String {
        (try? String(contentsOf: rig.root.appendingPathComponent(name), encoding: .utf8)) ?? "<missing>"
    }

    private func search(_ rig: Rig, _ window: TestWindow, _ query: String, replace: String = "bar") async throws {
        try window.click(window.element(identifier: "search-query"))
        window.typeText(query)
        window.typeKey(.return)
        try await window.runUntil { rig.workspace.search.facts != nil && !rig.workspace.search.isRunning }
        try window.click(window.element(identifier: "search-replace"))
        window.typeText(replace)
        settle(window)
    }

    @Test func replaceAllIsDisabledWithoutResults() async throws {
        let (rig, window) = try await codeWindow(["a.txt": "foo\n"])
        #expect(try window.element(identifier: "search-replace-all").isEnabled == false)
        try await search(rig, window, "foo")
        #expect(try window.element(identifier: "search-replace-all").isEnabled)
        rig.workspace.search.noteChanged("a.txt")
        settle(window)
        #expect(try window.element(identifier: "search-replace-all").isEnabled == false)
        withExtendedLifetime(rig) {}
    }

    @Test func replaceAllRewritesFilesAndShowsTheReviewList() async throws {
        let (rig, window) = try await codeWindow(["a.txt": "foo foo\n", "b.txt": "foo\n"])
        try await search(rig, window, "foo")
        try window.click(window.element(identifier: "search-replace-all"))
        try await window.runUntil { rig.workspace.search.review != nil }
        settle(window)
        #expect(read(rig, "a.txt") == "bar bar\n")
        #expect(read(rig, "b.txt") == "bar\n")
        _ = try window.element(identifier: "search-review-file-0")
        _ = try window.element(identifier: "search-review-file-1")
        _ = try window.element(identifier: "search-review-keep-all")
        #expect(text(window, "search-summary") == "Replaced 3 matches in 2 files")
        try window.click(window.element(identifier: "search-review-revert-all"))
        try await window.runUntil { rig.workspace.search.review?.isOpen == false }
        #expect(read(rig, "a.txt") == "foo foo\n")
        #expect(read(rig, "b.txt") == "foo\n")
        #expect(text(window, "search-summary") == "Reverted 2 files")
    }

    @Test func keepAllMarksTheEditsKept() async throws {
        let (rig, window) = try await codeWindow(["a.txt": "foo\n"])
        try await search(rig, window, "foo")
        try window.click(window.element(identifier: "search-replace-all"))
        try await window.runUntil { rig.workspace.search.review != nil }
        try window.click(window.element(identifier: "search-review-keep-all"))
        try await window.runUntil { rig.workspace.search.review?.isOpen == false }
        #expect(rig.workspace.changedFiles.isEmpty)
        #expect(read(rig, "a.txt") == "bar\n")
    }

    @Test func aThousandMatchesApplyAtOnceAndMoreAsksFirst() async throws {
        let (rig, window) = try await codeWindow(["a.txt": String(repeating: "foo\n", count: 1_000)])
        try await search(rig, window, "foo")
        #expect(rig.workspace.search.matchCount == 1_000)
        try window.click(window.element(identifier: "search-replace-all"))
        try await window.runUntil { rig.workspace.search.review != nil }
        #expect(read(rig, "a.txt").hasPrefix("bar\n"))
        withExtendedLifetime(window) {}

        let (rig2, window2) = try await codeWindow(["a.txt": String(repeating: "foo\n", count: 1_001)])
        try await search(rig2, window2, "foo")
        try window2.click(window2.element(identifier: "search-replace-all"))
        settle(window2)
        #expect(text(window2, "search-summary") != nil)
        #expect(rig2.workspace.search.confirmMessage == "Replace 1,001 matches in 1 file?")
        _ = try window2.element(identifier: "search-replace-confirm")
        await rig2.workspace.settle()
        #expect(read(rig2, "a.txt").hasPrefix("foo\n"))
        try window2.click(window2.element(identifier: "search-replace-cancel"))
        settle(window2)
        #expect(read(rig2, "a.txt").hasPrefix("foo\n"))
        #expect(rig2.workspace.search.review == nil)
        try window2.click(window2.element(identifier: "search-replace-all"))
        try window2.click(window2.element(identifier: "search-replace-confirm"))
        try await window2.runUntil { rig2.workspace.search.review != nil }
        #expect(read(rig2, "a.txt").hasPrefix("bar\n"))
    }

    @Test func dismissedFilesAreLeftAlone() async throws {
        let (rig, window) = try await codeWindow(["a.txt": "foo\n", "b.txt": "foo\n"])
        try await search(rig, window, "foo")
        rig.workspace.search.dismiss(file: 0)
        settle(window)
        try window.click(window.element(identifier: "search-replace-all"))
        try await window.runUntil { rig.workspace.search.review != nil }
        #expect(read(rig, "a.txt") == "foo\n")
        #expect(read(rig, "b.txt") == "bar\n")
    }

    @Test func perFileAndPerLineButtonsReplaceJustThat() async throws {
        let (rig, window) = try await codeWindow(["a.txt": "foo\nfoo\n", "b.txt": "foo\n"])
        try await search(rig, window, "foo")
        try window.hover(window.element(identifier: "search-line-0-1"))
        settle(window)
        try window.click(window.element(identifier: "search-replace-line-0-1"))
        try await window.runUntil { rig.workspace.search.review != nil }
        #expect(read(rig, "a.txt") == "foo\nbar\n")
        #expect(read(rig, "b.txt") == "foo\n")

        let (rig2, window2) = try await codeWindow(["a.txt": "foo\nfoo\n", "b.txt": "foo\n"])
        try await search(rig2, window2, "foo")
        let frame = try window2.element(identifier: "search-file-1").frame
        window2.hover(at: Point(x: frame.origin.x + Pixels(60), y: frame.origin.y + Pixels(8)))
        settle(window2)
        try window2.click(window2.element(identifier: "search-replace-file-1"))
        try await window2.runUntil { rig2.workspace.search.review != nil }
        #expect(read(rig2, "a.txt") == "foo\nfoo\n")
        #expect(read(rig2, "b.txt") == "bar\n")
    }

    @Test func changedFilesAreReportedForRerun() async throws {
        let (rig, window) = try await codeWindow(["a.txt": "foo\n", "b.txt": "foo\n", "c.txt": "foo\n"])
        try await search(rig, window, "foo")
        for n in ["a.txt", "b.txt", "c.txt"] { try "xx foo\n".write(to: rig.root.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        rig.workspace.search.setQuery(rig.workspace.search.query)       // no-op: keeps the results
        try window.click(window.element(identifier: "search-replace-all"))
        try await window.runUntil { rig.workspace.search.review != nil }
        settle(window)
        #expect(text(window, "search-summary") == "3 files changed since search; re-run")
    }
}
