@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

@MainActor @Suite struct UIStateTests {
    private func settle(_ e: Env, _ seconds: Double) async {
        e.clock.advance(by: seconds)
        for _ in 0..<50 { await Task.yield() }
    }

    private func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>" }

    private func seed(_ e: Env, _ json: String) throws {
        try FileManager.default.createDirectory(at: e.ws.storeDirectory, withIntermediateDirectories: true)
        try json.write(to: e.ws.uiStateURL, atomically: true, encoding: .utf8)
    }

    @Test func noFileMeansChatMode() async {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        #expect(e.ws.mode == .chat)
        #expect(!FileManager.default.fileExists(atPath: e.ws.uiStateURL.path))
    }

    @Test func modeRoundTrips() async {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        e.ws.setMode(.code)
        await waitUntil("timer armed") { e.clock.pendingSleepers == 1 }
        await settle(e, 0.5)
        await waitUntil("written") { e.ws.uiStateWriteCount == 1 }
        let json = text(e.ws.uiStateURL)
        #expect(json.contains("\"version\":1") && json.contains("\"mode\":\"code\""))
        let again = Workspace(projectRoot: e.root, appSupport: e.ws.appSupport, settings: AlloySettings(),
                              locate: { _ in URL(fileURLWithPath: "/fake/claude") }, autosaveClock: e.clock)
        await again.restoreUIState()
        #expect(again.mode == .code)
    }

    @Test func newerVersionIsIgnoredAndKept() async throws {
        let e = Env(); defer { e.cleanup() }
        let future = "{\"version\":2,\"mode\":\"code\",\"future\":1}"
        try seed(e, future)
        await e.ws.restoreUIState()
        #expect(e.ws.mode == .chat)
        e.ws.setMode(.code)
        await settle(e, 1)
        #expect(text(e.ws.uiStateURL) == future)
        #expect(e.ws.uiStateWriteCount == 0)
    }

    @Test func unknownKeysAreIgnored() async throws {
        let e = Env(); defer { e.cleanup() }
        try seed(e, "{\"version\":1,\"mode\":\"code\",\"extra\":{}}")
        await e.ws.restoreUIState()
        #expect(e.ws.mode == .code)
    }

    @Test func unknownModeFallsBackToChatWithoutBeingCorrupt() async throws {
        let e = Env(); defer { e.cleanup() }
        try seed(e, "{\"version\":1,\"mode\":\"split\"}")
        #expect(UIStateFile.load(e.ws.uiStateURL) == .state(UIState(version: 1, mode: .chat)))
        await e.ws.restoreUIState()
        #expect(e.ws.mode == .chat)
        #expect(e.ws.uiStateWritable)
    }

    @Test func corruptFileFallsBackAndIsReplaced() async throws {
        let e = Env(); defer { e.cleanup() }
        try seed(e, "{")
        await e.ws.restoreUIState()
        #expect(e.ws.mode == .chat)
        e.ws.setMode(.code)
        await waitUntil("timer armed") { e.clock.pendingSleepers == 1 }
        await settle(e, 0.5)
        await waitUntil("written") { e.ws.uiStateWriteCount == 1 }
        guard case .state(let state) = UIStateFile.load(e.ws.uiStateURL) else { Issue.record("state"); return }
        #expect(state.mode == .code)
    }

    @Test func versionZeroOrMissingIsCorrupt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ui-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try "{\"version\":0,\"mode\":\"code\"}".write(to: url, atomically: true, encoding: .utf8)
        #expect(UIStateFile.load(url) == .corrupt)
        try "{\"mode\":\"code\"}".write(to: url, atomically: true, encoding: .utf8)
        #expect(UIStateFile.load(url) == .corrupt)
    }

    @Test func writesAreDebounced() async {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        e.ws.setMode(.code)
        await waitUntil("armed") { e.clock.pendingSleepers == 1 }
        await settle(e, 0.3)
        e.ws.setMode(.chat)
        await settle(e, 0.3)
        e.ws.setMode(.code)
        await waitUntil("re-armed") { e.clock.pendingSleepers == 1 && e.clock.now == 0.6 }
        await settle(e, 0.4)
        #expect(e.ws.uiStateWriteCount == 0)
        await settle(e, 0.1)
        await waitUntil("written") { e.ws.uiStateWriteCount == 1 }
        #expect(e.ws.uiStateWriteCount == 1)
    }

    @Test func switchingModeClearsCodePanelFocusSoFollowEditsIsNotBlocked() async throws {
        let e = Env(); defer { e.cleanup() }
        let old = "one\ntwo\n", new = "one\nTWO\n"
        e.write("a.txt", old)
        _ = await e.ws.newSession(name: "Ann")
        e.ws.codePanelFocused = true
        let writes = e.ws.writeCount
        e.ws.setMode(.code)
        #expect(!e.ws.codePanelFocused)
        #expect(e.ws.writeCount == writes)
        e.ws.setMode(.chat)
        e.write("a.txt", new)
        let hunks = Patch.diff(old: TextLines(old).lines, new: TextLines(new).lines, context: 0)
        let t = e.transports.all[0]
        await t.emit(.assistantBlock(messageID: "m1", block: .toolUse(id: "t1", name: "Edit", input: .object([:]))))
        await t.emit(.toolResult(ToolResultMessage(toolUseID: "t1", isError: false, text: "ok",
                                                   result: .edit(filePath: e.url("a.txt").path, originalFile: old, hunks: hunks))))
        await waitUntil("follow edit opens the file") { e.ws.activeTab == "a.txt" }
    }

    @Test func stopAllFlushesPendingWrite() async {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        e.ws.setMode(.code)
        await e.ws.stopAll()
        #expect(e.ws.uiStateWriteCount == 1)
        guard case .state(let state) = UIStateFile.load(e.ws.uiStateURL) else { Issue.record("state"); return }
        #expect(state.mode == .code)
    }

    // MARK: Remembered layout

    private func fresh(_ e: Env) -> Workspace {
        Workspace(projectRoot: e.root, appSupport: e.ws.appSupport, settings: AlloySettings(),
                  locate: { _ in URL(fileURLWithPath: "/fake/claude") }, autosaveClock: e.clock)
    }

    private func flush(_ e: Env) async {
        await e.ws.flushUIState()
    }

    /// Two groups side by side: [a, b] (active b) and [c] (active c); focus on the second.
    private func twoGroups(_ e: Env) async -> (UUID, UUID, UUID) {
        for n in ["a", "b", "c"] { e.write(n, "\(n)\n") }
        await e.ws.restoreUIState()
        e.ws.setMode(.code)
        let g0 = e.ws.codeLayout.focusedGroupID
        await e.ws.open("a", in: .group(g0))
        await e.ws.open("b", in: .group(g0))
        e.ws.splitFocused(.horizontal)
        let g1 = e.ws.codeLayout.focusedGroupID
        await e.ws.open("c", in: .group(g1))
        e.ws.removeTab("b", from: .group(g1))
        guard case .split(let split, _, _, _) = e.ws.codeLayout.tree else { fatalError("tree") }
        return (g0, g1, split)
    }

    @Test func layoutRoundTrips() async {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        let (g0, g1, split) = await twoGroups(e)
        e.ws.codeLayout.chatCollapsed = true
        e.ws.setPaneSizes([300, 500], forName: "code-split-\(split)")
        e.ws.setPaneSizes([200, 900, 300], forName: "code-main")
        e.ws.expandedFolders = ["src", "src/lib"]
        e.ws.noteExpandedFoldersChanged()
        await flush(e)
        let again = fresh(e)
        await again.restoreUIState()
        #expect(again.mode == .code)
        #expect(again.codeLayout.tree == e.ws.codeLayout.tree)
        #expect(again.codeLayout.focusedGroupID == g1)
        #expect(again.tabs(in: .group(g0)) == ["a", "b"] && again.activeTab(in: .group(g0)) == "b")
        #expect(again.tabs(in: .group(g1)) == ["c"] && again.activeTab(in: .group(g1)) == "c")
        #expect(again.codeLayout.chatCollapsed)
        #expect(again.paneSizes(forName: "code-main") == [200, 900, 300])
        #expect(again.paneSizes(forName: "code-split-\(split)") == [300, 500])
        // Folders that don't exist are dropped, so only real ones come back.
        #expect(again.expandedFolders.isEmpty)
    }

    @Test func openDuringRestoreIsNeverLeftWithoutAHolder() async {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        _ = await twoGroups(e)
        e.write("z", "z\n")
        await flush(e)
        let again = fresh(e)
        let restore = Task { @MainActor in await again.restoreUIState() }
        await Task.yield()   // the restore is now waiting on the file checks
        await again.open("z")   // a quick-open while the saved layout is not installed yet
        await restore.value
        #expect(again.document("z") != nil)
        #expect(again.holds("z"), "a document always has a tab list holding it")
        #expect(again.mode == .code)
    }

    @Test func expandedFoldersRoundTrip() async throws {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        try FileManager.default.createDirectory(at: e.url("src/lib"), withIntermediateDirectories: true)
        e.ws.expandedFolders = ["src", "src/lib", "gone"]
        e.ws.noteExpandedFoldersChanged()
        await flush(e)
        let again = fresh(e)
        await again.restoreUIState()
        #expect(again.expandedFolders == ["src", "src/lib"])
    }

    @Test func restoreDoesNotWaitOnTheFileTree() async throws {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        try FileManager.default.createDirectory(at: e.url("src"), withIntermediateDirectories: true)
        e.ws.expandedFolders = ["src"]
        e.ws.noteExpandedFoldersChanged()
        await flush(e)
        let again = fresh(e)
        await again.restoreUIState()
        #expect(again.fileTreeRefreshCount == 0)
        #expect(again.fileTree.expandedPaths == ["src"])
    }

    @Test func missingFilesAreSkipped() async {
        let e = Env(); defer { e.cleanup() }
        let (g0, _, _) = await twoGroups(e)
        await flush(e)
        try? FileManager.default.removeItem(at: e.url("b"))
        let again = fresh(e)
        await again.restoreUIState()
        #expect(again.tabs(in: .group(g0)) == ["a"])
        #expect(again.activeTab(in: .group(g0)) == "a")
    }

    @Test func groupEmptiedByMissingFilesCollapses() async {
        let e = Env(); defer { e.cleanup() }
        let (g0, g1, _) = await twoGroups(e)
        await flush(e)
        try? FileManager.default.removeItem(at: e.url("c"))
        let again = fresh(e)
        await again.restoreUIState()
        #expect(again.codeLayout.tree == .group(g0))
        #expect(again.codeLayout.groups[g1] == nil)
        #expect(again.codeLayout.focusedGroupID == g0)
        #expect(again.codeLayout.groups.count == 1)
    }

    @Test func allFilesMissingLeavesOneEmptyGroup() async {
        let e = Env(); defer { e.cleanup() }
        let (_, g1, _) = await twoGroups(e)
        await flush(e)
        for n in ["a", "b", "c"] { try? FileManager.default.removeItem(at: e.url(n)) }
        let again = fresh(e)
        await again.restoreUIState()
        #expect(again.codeLayout.groups.count == 1)
        #expect(again.codeLayout.tree == .group(g1))
        #expect(again.codeLayout.focusedGroupID == g1)
        #expect(again.codeLayout.focusedGroup.tabs.isEmpty)
        #expect(again.documents.isEmpty)
    }

    @Test func focusedIdIsValidWhenSavedOneIsUnknown() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a", "a\n")
        let g = UUID()
        let state = UIState(mode: .code, layout: CodeLayoutState(
            tree: .group(g), groups: [GroupState(id: g, tabs: ["a"], active: "zzz")], focused: UUID()))
        try UIStateFile.save(state, to: e.ws.uiStateURL)
        await e.ws.restoreUIState()
        #expect(e.ws.codeLayout.focusedGroupID == g)
        #expect(e.ws.activeTab(in: .group(g)) == "a")
    }

    @Test func chatTabsAreNotPersisted() async {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        e.write("a", "a\n")
        await e.ws.open("a")
        e.ws.setMode(.code)
        await e.ws.open("a", in: .group(e.ws.codeLayout.focusedGroupID))
        await flush(e)
        e.ws.setMode(.chat)
        await flush(e)
        let again = fresh(e)
        await again.restoreUIState()
        #expect(again.tabs.isEmpty && again.activeTab == nil)
    }

    @Test func restoredSplitKeepsItsAutosaveSizes() async {
        let e = Env(); defer { e.cleanup() }
        let (_, _, split) = await twoGroups(e)
        e.ws.setPaneSizes([111, 222], forName: "code-split-\(split)")
        await flush(e)
        let again = fresh(e)
        await again.restoreUIState()
        guard case .split(let id, _, _, _) = again.codeLayout.tree else { Issue.record("tree"); return }
        #expect(id == split)
        #expect(again.paneSizes(forName: "code-split-\(id)") == [111, 222])
    }

    @Test func commandLineFileOpensInTheRestoredMode() async {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        e.write("a", "a\n"); e.write("b", "b\n")
        e.ws.setMode(.code)
        await e.ws.open("a", in: .group(e.ws.codeLayout.focusedGroupID))
        await flush(e)
        let again = fresh(e)
        await again.restoreUIState()
        again.openFilePath = "b"
        await again.settle()
        #expect(again.mode == .code)
        #expect(again.tabs(in: .group(again.codeLayout.focusedGroupID)).contains("b"))
        #expect(again.tabs.isEmpty)
    }

    @Test func restoreLoadsOnlyActiveDocuments() async {
        let e = Env(); defer { e.cleanup() }
        let (g0, g1, _) = await twoGroups(e)
        await e.ws.open("a", in: .group(g1))
        await flush(e)
        let again = fresh(e)
        await again.restoreUIState()
        #expect(again.tabs(in: .group(g0)) == ["a", "b"] && again.tabs(in: .group(g1)) == ["c", "a"])
        await again.settle()
        // Code mode: only the focused group's active document (a) loads; the other group's waits.
        #expect(Set(again.documents.keys) == ["a"])
        again.activate("b", in: .group(g0))
        await again.settle()
        #expect(Set(again.documents.keys) == ["a", "b"])
    }

    @Test func restoreReturnsBeforeDocumentsLoad() async {
        let e = Env(); defer { e.cleanup() }
        _ = await twoGroups(e)
        await flush(e)
        let again = fresh(e)
        await again.restoreUIState()
        #expect(again.documents.isEmpty && again.uiStateRestored)
        await again.settle()
        #expect(again.documents.count == 1)
    }

    @Test func chatModeRestoreLoadsNoGroupDocuments() async {
        let e = Env(); defer { e.cleanup() }
        _ = await twoGroups(e)
        e.ws.setMode(.chat)
        await flush(e)
        let again = fresh(e)
        await again.restoreUIState()
        await again.settle()
        #expect(again.mode == .chat && again.documents.isEmpty)
        again.setMode(.code)
        await again.settle()
        #expect(Set(again.documents.keys) == ["c"])
    }

    @Test func writesBeforeRestoreDoNotReplaceTheSavedFile() async throws {
        let e = Env(); defer { e.cleanup() }
        let saved = "{\"version\":1,\"mode\":\"code\"}"
        try seed(e, saved)
        e.ws.setMode(.chat)
        await settle(e, 1)
        #expect(text(e.ws.uiStateURL) == saved && e.ws.uiStateWriteCount == 0)
    }

    @Test func staleSplitSizesAreNotWritten() async {
        let e = Env(); defer { e.cleanup() }
        let (_, _, split) = await twoGroups(e)
        e.ws.setPaneSizes([1, 2], forName: "code-split-\(split)")
        e.ws.setPaneSizes([3, 4], forName: "code-split-\(UUID())")
        e.ws.setPaneSizes([5, 6], forName: "code-main")
        await flush(e)
        guard case .state(let state) = UIStateFile.load(e.ws.uiStateURL) else { Issue.record("state"); return }
        #expect(Set(state.paneSizes.keys) == ["code-split-\(split)", "code-main"])
    }

    @Test func duplicateGroupIDsFallBackToTheDefaultLayout() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a", "a\n")
        let g = UUID()
        let tree = SplitTree.split(id: UUID(), axis: .horizontal, first: .group(g), second: .group(g))
        try UIStateFile.save(UIState(mode: .code, layout: CodeLayoutState(
            tree: tree, groups: [GroupState(id: g, tabs: ["a"], active: "a")], focused: g)), to: e.ws.uiStateURL)
        let initial = e.ws.codeLayout.focusedGroupID
        await e.ws.restoreUIState()
        #expect(e.ws.codeLayout.tree == .group(initial) && e.ws.codeLayout.groups.count == 1)
        #expect(e.ws.codeLayout.focusedGroup.tabs.isEmpty)
    }

    @Test func tabChangesScheduleADebouncedWrite() async {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        e.write("a", "a\n")
        e.ws.setMode(.code)
        await settle(e, 1)
        await waitUntil("first write") { e.ws.uiStateWriteCount == 1 }
        await e.ws.open("a", in: .group(e.ws.codeLayout.focusedGroupID))
        await settle(e, 1)
        await waitUntil("tab write") { e.ws.uiStateWriteCount == 2 }
        guard case .state(let state) = UIStateFile.load(e.ws.uiStateURL) else { Issue.record("state"); return }
        #expect(state.layout?.groups.first?.tabs == ["a"])
    }

    @Test func olderFileWithoutNewFieldsLoadsWithDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ui-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try "{\"version\":1,\"mode\":\"code\",\"layout\":{\"nope\":1},\"chatCollapsed\":\"x\"}".write(to: url, atomically: true, encoding: .utf8)
        #expect(UIStateFile.load(url) == .state(UIState(mode: .code)))
    }

    // MARK: terminal field

    @Test func fileWithoutTerminalDecodesAndVersionStaysOne() throws {
        let state = try JSONDecoder().decode(UIState.self, from: Data(#"{"version":1,"mode":"code"}"#.utf8))
        #expect(state.terminal == nil)
        #expect(UIState.currentVersion == 1)
    }

    @Test func terminalRoundTripsThroughSaveAndLoad() throws {
        var layout = TerminalLayout()
        layout.toggle(defaultCwd: "/p")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ui-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try UIStateFile.save(UIState(terminal: layout), to: url)
        guard case .state(let loaded) = UIStateFile.load(url) else { Issue.record("state"); return }
        #expect(loaded.terminal == layout)
    }

    @Test func malformedTerminalValueDecodesAsNilNotCorrupt() throws {
        for bad in ["5", #"{"tabs":"x"}"#, "[]", "null"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ui-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            try #"{"version":1,"mode":"code","terminal":\#(bad)}"#.write(to: url, atomically: true, encoding: .utf8)
            guard case .state(let loaded) = UIStateFile.load(url) else { Issue.record("not state for \(bad)"); return }
            #expect(loaded.terminal == nil)
        }
    }

    @Test func terminalWithDanglingFocusIsRepaired() throws {
        var layout = TerminalLayout()
        layout.addTab(cwd: "/a"); layout.addTab(cwd: "/b")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as? [String: Any])
        var tabs = try #require(object["tabs"] as? [[String: Any]])
        tabs[0]["focusedPane"] = UUID().uuidString
        object["tabs"] = tabs
        object["activeTab"] = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "terminal": object])
        let state = try JSONDecoder().decode(UIState.self, from: data)
        let t = try #require(state.terminal)
        #expect(t.tabs.count == 2)
        #expect(t.activeTab == t.tabs[0].id)
        #expect(t.tabs[0].panes[t.tabs[0].focusedPane] != nil)
        let empty = try JSONDecoder().decode(UIState.self, from: Data(#"{"version":1,"terminal":{"visible":true,"tabs":[]}}"#.utf8))
        #expect(empty.terminal == nil)
    }

    @Test func workspaceRestoreInstallsLayoutLazily() async throws {
        let e = Env(); defer { e.cleanup() }
        var layout = TerminalLayout()
        layout.addTab(cwd: "/a"); layout.addTab(cwd: "/b"); layout.addTab(cwd: "/c")
        layout.visible = false
        try seed(e, String(decoding: try JSONEncoder().encode(UIState(terminal: layout)), as: UTF8.self))
        await e.ws.restoreUIState()
        #expect(e.ws.terminalLayout.tabs.count == 3)
        #expect(e.ws.terminalLayout.panesToSpawn().isEmpty)
        e.ws.terminalLayout.visible = true
        #expect(e.ws.terminalLayout.panesToSpawn().count == 1)
    }

    @Test func workspaceWritesTerminalLayoutOnChange() async {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        e.ws.terminalLayout.toggle(defaultCwd: "/proj")
        await waitUntil("timer armed") { e.clock.pendingSleepers == 1 }
        await settle(e, 0.5)
        await waitUntil("written") { e.ws.uiStateWriteCount == 1 }
        guard case .state(let state) = UIStateFile.load(e.ws.uiStateURL) else { Issue.record("state"); return }
        #expect(state.terminal?.tabs.count == 1 && state.terminal?.visible == true)
    }

    @Test func spawnedChangesDoNotWrite() async {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        e.ws.terminalLayout.toggle(defaultCwd: "/proj")
        await waitUntil("timer armed") { e.clock.pendingSleepers == 1 }
        await settle(e, 0.5)
        await waitUntil("written") { e.ws.uiStateWriteCount == 1 }
        e.ws.terminalLayout.markSpawned(e.ws.terminalLayout.tabs[0].focusedPane)
        await settle(e, 1)
        #expect(e.ws.uiStateWriteCount == 1)
    }

    @Test func terminalLayoutDoesNotWriteBeforeRestore() async {
        let e = Env(); defer { e.cleanup() }
        e.ws.terminalLayout.toggle(defaultCwd: "/proj")
        await settle(e, 1)
        #expect(e.ws.uiStateWriteCount == 0)
        #expect(!FileManager.default.fileExists(atPath: e.ws.uiStateURL.path))
    }
}

@MainActor @Suite struct RecentCommandsTests {
    @Test func missingAndMalformedRecentsDecodeEmpty() throws {
        let a = try JSONDecoder().decode(UIState.self, from: Data("{\"version\":1,\"mode\":\"code\"}".utf8))
        #expect(a.recentCommands.isEmpty)
        let b = try JSONDecoder().decode(UIState.self, from: Data("{\"version\":1,\"mode\":\"code\",\"recentCommands\":{\"x\":1}}".utf8))
        #expect(b.recentCommands.isEmpty && b.mode == .code)
        #expect(UIState.currentVersion == 1)
    }

    @Test func encodeCapsAtTenNewestFirst() throws {
        let ids = (0..<15).map { "c\($0)" }
        let data = try JSONEncoder().encode(UIState(recentCommands: ids))
        let back = try JSONDecoder().decode(UIState.self, from: data)
        #expect(back.recentCommands == Array(ids.prefix(10)))
    }

    @Test func noteMovesToFrontAndWritesOnlyOnChange() async {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        e.ws.noteCommandRun(id: "a")
        await waitUntil("armed") { e.clock.pendingSleepers == 1 }
        e.clock.advance(by: 0.5)
        await waitUntil("written") { e.ws.uiStateWriteCount == 1 }
        e.ws.noteCommandRun(id: "a")
        e.clock.advance(by: 1)
        for _ in 0..<50 { await Task.yield() }
        #expect(e.ws.uiStateWriteCount == 1)
        e.ws.noteCommandRun(id: "b")
        await waitUntil("armed 2") { e.clock.pendingSleepers == 1 }
        e.clock.advance(by: 0.5)
        await waitUntil("written 2") { e.ws.uiStateWriteCount == 2 }
        #expect(e.ws.recentCommands == ["b", "a"])
        for i in 0..<12 { e.ws.noteCommandRun(id: "x\(i)") }
        #expect(e.ws.recentCommands.count == 10 && e.ws.recentCommands.first == "x11")
        #expect(UIStateFile.load(e.ws.uiStateURL) != .corrupt)
    }

    @Test func restoreCarriesRecents() async throws {
        let e = Env(); defer { e.cleanup() }
        try FileManager.default.createDirectory(at: e.ws.storeDirectory, withIntermediateDirectories: true)
        try "{\"version\":1,\"recentCommands\":[\"q\",\"r\"]}".write(to: e.ws.uiStateURL, atomically: true, encoding: .utf8)
        await e.ws.restoreUIState()
        #expect(e.ws.recentCommands == ["q", "r"])
    }
}

@MainActor @Suite struct UIStateGitFieldTests {
    @Test func gitFieldsRoundTripWithoutVersionBump() throws {
        let state = UIState(mode: .code, sidebarTab: .git, gitCommitDraft: "wip")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uistate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try UIStateFile.save(state, to: url)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.contains("\"version\":1"))
        guard case .state(let loaded) = UIStateFile.load(url) else { Issue.record("did not load"); return }
        #expect(loaded.sidebarTab == .git && loaded.gitCommitDraft == "wip")
        #expect(UIState.currentVersion == 1)
    }

    @Test func nilFieldsAreNotWritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uistate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try UIStateFile.save(UIState(mode: .chat), to: url)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(!json.contains("gitCommitDraft"))
    }

    @Test func olderFileWithoutGitFieldsLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uistate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"version":1,"mode":"code","paneSizes":{},"chatCollapsed":false,"expandedFolders":[]}"#.write(to: url, atomically: true, encoding: .utf8)
        guard case .state(let loaded) = UIStateFile.load(url) else { Issue.record("did not load"); return }
        #expect(loaded.mode == .code && loaded.sidebarTab == .files && loaded.gitCommitDraft == nil)
    }

    @Test func wrongTypedGitFieldsFallBackToNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uistate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"version":1,"mode":"code","sidebarTab":5,"gitCommitDraft":[]}"#.write(to: url, atomically: true, encoding: .utf8)
        guard case .state(let loaded) = UIStateFile.load(url) else { Issue.record("did not load"); return }
        #expect(loaded.sidebarTab == .files && loaded.gitCommitDraft == nil)
    }

    @Test func workspacePersistsSidebarTabAndDraft() async {
        let e = Env(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        e.ws.codeLayout.sidebarTab = .git; e.ws.persistedCommitDraft = "draft msg"
        await waitUntil("timer armed") { e.clock.pendingSleepers >= 1 }
        e.clock.advance(by: 0.5)
        await waitUntil("written") { e.ws.uiStateWriteCount >= 1 }
        let again = Workspace(projectRoot: e.root, appSupport: e.ws.appSupport, settings: AlloySettings(),
                              locate: { _ in URL(fileURLWithPath: "/fake/claude") }, autosaveClock: e.clock)
        await again.restoreUIState()
        #expect(again.codeLayout.sidebarTab == .git && again.persistedCommitDraft == "draft msg")
    }
}
