@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct SearchTabTests {
    private func codeWindow(_ files: [String] = ["a.swift", "b.swift"]) async throws -> (Rig, TestWindow) {
        let rig = Rig()
        for f in files { try "x\n".write(to: rig.root.appendingPathComponent(f), atomically: true, encoding: .utf8) }
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { !rig.workspace.fileTree.snapshot.children(of: "").isEmpty }
        settle(window)
        return (rig, window)
    }

    private func settle(_ window: TestWindow) { for _ in 0..<4 { window.tick() } }
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }
    private func rows(_ window: TestWindow) -> [TestElement] {
        (try? window.elements { ($0.identifier ?? "").hasPrefix("file-tree-row-") }) ?? []
    }

    @Test func tabsSwitchBetweenTreeAndSearch() async throws {
        let (rig, window) = try await codeWindow()
        _ = try window.element(identifier: "code-sidebar-tabs")
        #expect(!rows(window).isEmpty)
        #expect(!exists(window, "search-query"))
        try window.click(window.element(identifier: "code-sidebar-tab-search"))
        settle(window)
        #expect(rig.workspace.codeLayout.sidebarTab == .search)
        _ = try window.element(identifier: "search-query")
        #expect(rows(window).isEmpty, "the tree is gone")
        try window.click(window.element(identifier: "code-sidebar-tab-files"))
        settle(window)
        #expect(!rows(window).isEmpty)
        #expect(!exists(window, "search-query"))
    }

    @Test func selectedTabIsMarkedAndInked() async throws {
        let (_, window) = try await codeWindow()
        #expect(try window.element(identifier: "code-sidebar-tab-files").isSelected)
        #expect(try !window.element(identifier: "code-sidebar-tab-search").isSelected)
        try window.click(window.element(identifier: "code-sidebar-tab-search"))
        settle(window)
        #expect(try window.element(identifier: "code-sidebar-tab-search").isSelected)
        #expect(try !window.element(identifier: "code-sidebar-tab-files").isSelected)
        #expect(CodeSidebarView.tabInk(selected: true) != CodeSidebarView.tabInk(selected: false))
        #expect(CodeSidebarView.tabInk(selected: true) == .primary)
        #expect(CodeSidebarView.tabInk(selected: false) == .mutedInk)
    }

    @Test func showSearchFromChatLandsOnTheSearchTab() async throws {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        let window = try alloyWindow(rig.workspace)
        settle(window)
        #expect(rig.workspace.mode == .chat)
        rig.workspace.showSearch(replace: false)
        settle(window)
        #expect(rig.workspace.mode == .code)
        #expect(rig.workspace.codeLayout.sidebarTab == .search)
        _ = try window.element(identifier: "search-query")
    }

    @Test func menuItemsOpenTheTab() async throws {
        let (rig, window) = try await codeWindow()
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "view-replace-in-files")
        settle(window)
        #expect(rig.workspace.codeLayout.sidebarTab == .search)
        _ = try window.element(identifier: "search-replace")
        let items = window.testApp.menuBar.flatMap(\.items)
        let find = try #require(items.first { $0.title == "Find in Files" })
        #expect(find.shortcut?.key == "f" && find.shortcut?.modifiers == [.command, .shift])
        let replace = try #require(items.first { $0.title == "Replace in Files" })
        #expect(replace.shortcut?.key == "h" && replace.shortcut?.modifiers == [.command, .shift])
        let next = try #require(items.first { $0.title == "Next Result" })
        let previous = try #require(items.first { $0.title == "Previous Result" })
        #expect(next.shortcut?.modifiers == [] && previous.shortcut?.modifiers == [.shift])
        #expect(next.shortcut?.key == previous.shortcut?.key)
    }

    @Test func tabPersistsAcrossRestore() async throws {
        let (rig, window) = try await codeWindow()
        rig.workspace.codeLayout.sidebarTab = .search
        rig.workspace.search.restore(SearchQuery(text: "needle", regex: true))
        rig.workspace.lastSearch = rig.workspace.search.query
        await rig.workspace.flushUIState()
        let saved = UIStateFile.load(rig.workspace.uiStateURL)
        guard case .state(let state) = saved else { Issue.record("no state: \(saved)"); return }
        #expect(state.sidebarTab == .search)
        #expect(state.lastSearch?.text == "needle")
        rig.workspace.codeLayout.sidebarTab = .files
        await rig.workspace.restoreUIState()
        #expect(rig.workspace.codeLayout.sidebarTab == .search)
        #expect(rig.workspace.search.query.text == "needle")
        withExtendedLifetime(window) {}
    }

    @Test func optionTogglesFlipTheQuery() async throws {
        let (rig, window) = try await codeWindow()
        rig.workspace.codeLayout.sidebarTab = .search
        settle(window)
        for (id, keyPath) in [("search-opt-case", \SearchQuery.caseSensitive), ("search-opt-word", \.wholeWord), ("search-opt-regex", \.regex)] {
            #expect(rig.workspace.search.query[keyPath: keyPath] == false)
            try window.click(window.element(identifier: id)); settle(window)
            #expect(rig.workspace.search.query[keyPath: keyPath] == true, Comment(rawValue: id))
            try window.click(window.element(identifier: id)); settle(window)
            #expect(rig.workspace.search.query[keyPath: keyPath] == false, Comment(rawValue: id))
        }
    }

    @Test func globsDiscloseAndReplaceNeedsReveal() async throws {
        let (rig, window) = try await codeWindow()
        rig.workspace.codeLayout.sidebarTab = .search
        settle(window)
        #expect(!exists(window, "search-include") && !exists(window, "search-exclude"))
        #expect(!exists(window, "search-replace"))
        _ = try window.element(identifier: "search-globs")
        let triangle = try #require(try window.elements { $0.role == .disclosureTriangle }.first)
        try window.click(triangle); settle(window)
        _ = try window.element(identifier: "search-include")
        _ = try window.element(identifier: "search-exclude")
        rig.workspace.showSearch(replace: true)
        settle(window)
        _ = try window.element(identifier: "search-replace")
    }

    @Test func typingFillsTheQuery() async throws {
        let (rig, window) = try await codeWindow()
        rig.workspace.codeLayout.sidebarTab = .search
        settle(window)
        try window.click(window.element(identifier: "search-query"))
        window.typeText("abc"); settle(window)
        #expect(rig.workspace.search.query.text == "abc")
    }
}
