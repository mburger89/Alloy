import Foundation
import Testing
@testable import AlloyCore

@Suite struct TerminalLayoutTests {
    func three() -> TerminalLayout {
        var l = TerminalLayout()
        l.addTab(cwd: "/a"); l.addTab(cwd: "/b"); l.addTab(cwd: "/c")
        return l
    }

    @Test func toggleOnEmptyAddsOneTab() {
        var l = TerminalLayout()
        l.toggle(defaultCwd: "/p")
        #expect(l.visible)
        #expect(l.tabs.count == 1)
        #expect(l.activeTab == l.tabs[0].id)
        #expect(l.tabs[0].panes[l.tabs[0].focusedPane]?.lastCwd == "/p")
    }

    @Test func toggleTwiceHidesButKeepsTab() {
        var l = TerminalLayout()
        l.toggle(defaultCwd: "/p"); l.toggle(defaultCwd: "/p")
        #expect(!l.visible)
        #expect(l.tabs.count == 1)
        l.toggle(defaultCwd: "/p")
        #expect(l.visible && l.tabs.count == 1)
    }

    @Test func closeLastTabHidesAndEmpties() {
        var l = TerminalLayout()
        l.toggle(defaultCwd: "/p")
        l.closeTab(l.tabs[0].id)
        #expect(!l.visible)
        #expect(l.tabs.isEmpty)
        #expect(l.activeTab == nil)
        l.toggle(defaultCwd: "/p")
        #expect(l.visible && l.tabs.count == 1)
    }

    @Test func closeActiveTabSelectsNeighbour() {
        var l = three()
        let ids = l.tabs.map(\.id)
        l.selectTab(ids[1])
        l.closeTab(ids[1])
        #expect(l.activeTab == ids[2])
        l.closeTab(ids[2])
        #expect(l.activeTab == ids[0])
        l.closeTab(ids[0])
        #expect(l.tabs.isEmpty)
    }

    @Test func closingInactiveTabKeepsActive() {
        var l = three()
        let ids = l.tabs.map(\.id)
        l.closeTab(ids[0])
        #expect(l.activeTab == ids[2])
    }

    @Test func splitInheritsCwdAndFocusesNewPane() {
        var l = TerminalLayout()
        l.addTab(cwd: "/a")
        let first = l.tabs[0].focusedPane
        l.setCwd("/moved", for: first)
        let np = UUID()
        l.split(axis: .horizontal, newPane: np)
        #expect(l.tabs[0].focusedPane == np)
        #expect(l.tabs[0].panes[np]?.lastCwd == "/moved")
        #expect(l.tabs[0].tree.paneIDs == [first, np])
    }

    @Test func closePaneOfSplitFocusesSibling() {
        var l = TerminalLayout()
        l.addTab(cwd: "/a")
        let first = l.tabs[0].focusedPane
        let np = UUID()
        l.split(axis: .vertical, newPane: np)
        l.closePane(np)
        #expect(l.tabs[0].focusedPane == first)
        #expect(l.tabs[0].tree == .pane(first))
        #expect(l.tabs[0].panes[np] == nil)
    }

    @Test func closingLastPaneClosesTab() {
        var l = TerminalLayout()
        l.addTab(cwd: "/a")
        l.closePane(l.tabs[0].focusedPane)
        #expect(l.tabs.isEmpty && !l.visible)
    }

    @Test func selectTabAtIndexOutOfRangeIsIgnored() {
        var l = three()
        let active = l.activeTab
        l.selectTab(at: 9); l.selectTab(at: -1)
        #expect(l.activeTab == active)
        l.selectTab(at: 0)
        #expect(l.activeTab == l.tabs[0].id)
    }

    @Test func panesToSpawnIsOnlyFocusedPaneOfActiveTabWhenVisible() throws {
        let data = try JSONEncoder().encode(three())
        var l = try JSONDecoder().decode(TerminalLayout.self, from: data)
        #expect(l.spawned.isEmpty)
        let active = try #require(l.active)
        #expect(l.panesToSpawn() == [active.focusedPane])
        l.visible = false
        #expect(l.panesToSpawn().isEmpty)
        l.visible = true
        l.markSpawned(active.focusedPane)
        #expect(l.panesToSpawn().isEmpty)
        l.selectTab(at: 0)
        #expect(l.panesToSpawn() == [l.tabs[0].focusedPane])
    }

    @Test func transientSpawnedStateIsNotEncoded() throws {
        var l = three()
        l.markSpawned(l.tabs[0].focusedPane)
        let json = try #require(String(data: JSONEncoder().encode(l), encoding: .utf8))
        #expect(!json.contains("spawned"))
    }

    @Test func sanitizedRepairsDuplicatesAndDanglingFocus() throws {
        let p = UUID(), q = UUID()
        let dupTree = TerminalSplitTree.pane(p).splitting(p, axis: .horizontal, newPane: p, newSplit: UUID())
        let t1 = TerminalTab(id: UUID(), tree: dupTree, panes: [:], focusedPane: UUID())
        let t2 = TerminalTab(id: UUID(), tree: .pane(p), panes: [p: TerminalPane(id: p)], focusedPane: p)
        let t3 = TerminalTab(id: UUID(), tree: .pane(q), panes: [q: TerminalPane(id: q, lastCwd: "/q")], focusedPane: UUID())
        let l = TerminalLayout(visible: true, tabs: [t1, t2, t3], activeTab: UUID())
        let s = try #require(l.sanitized())
        #expect(s.tabs.map(\.id) == [t1.id, t3.id])
        #expect(s.tabs[0].tree == .pane(p))
        #expect(s.tabs[0].focusedPane == p)
        #expect(s.tabs[1].focusedPane == q)
        #expect(s.tabs[1].panes[q]?.lastCwd == "/q")
        #expect(s.activeTab == t1.id)
        let all = s.tabs.flatMap { $0.tree.paneIDs }
        #expect(Set(all).count == all.count)
    }

    @Test func sanitizedReturnsNilWithNoTabs() {
        #expect(TerminalLayout().sanitized() == nil)
        #expect(TerminalLayout(visible: true, tabs: [], activeTab: UUID()).sanitized() == nil)
    }
}
