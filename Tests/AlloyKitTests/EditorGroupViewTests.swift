@testable import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyLSPTestSupport
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// Code mode's editor groups: one view per group, nested resizable splits, focus, and the View menu's items.
@MainActor
@Suite struct EditorGroupViewTests {
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }
    private func frame(_ window: TestWindow, _ id: String) throws -> Bounds<Pixels> { try window.element(identifier: id).frame }

    /// Code mode with `a.swift` (and `b.swift`) open in the one group.
    private func setup(files: [String] = ["a.swift"]) async throws -> (rig: Rig, window: TestWindow, g0: UUID) {
        let rig = Rig()
        for name in ["a.swift", "b.swift"] {
            try "let \(name.prefix(1)) = 1\n".write(to: rig.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        for file in files { await rig.workspace.open(file, in: .group(g0)) }
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-view-\(g0.uuidString)") }
        return (rig, window, g0)
    }

    private func settle(_ window: TestWindow, _ n: Int = 4) async {
        for _ in 0..<n { window.tick(); await Task.yield() }
    }

    private func overlap(_ x: Bounds<Pixels>, _ y: Bounds<Pixels>) -> Bool {
        x.minX.value < y.maxX.value - 0.5 && y.minX.value < x.maxX.value - 0.5
            && x.minY.value < y.maxY.value - 0.5 && y.minY.value < x.maxY.value - 0.5
    }

    @Test func cmdBackslashShowsTwoGroupsOnOneFile() async throws {
        let (rig, window, g0) = try await setup()
        window.typeKey("\\", modifierFlags: [.command])
        await settle(window)
        let ids = rig.workspace.codeLayout.tree.groupIDs
        #expect(ids.count == 2)
        let g1 = ids[1]
        for id in ["code-group-\(g0)", "code-group-\(g1)", "code-view-\(g0)", "code-view-\(g1)"] { #expect(exists(window, id), "\(id)") }
        let a = try frame(window, "code-group-\(g0)"), b = try frame(window, "code-group-\(g1)")
        #expect(a.maxX.value <= b.minX.value + 0.5, "side by side")
        #expect(!overlap(a, b))
    }

    @Test func tabContextMenuSplitsRightWithTheClickedTab() async throws {
        let (rig, window, g0) = try await setup(files: ["a.swift", "b.swift"])
        rig.workspace.activate("a.swift", in: .group(g0))
        await settle(window)
        try window.rightClick(window.element(identifier: "group-\(g0)-tab-b.swift"))
        #expect(window.presentedMenu?.items.map(\.title) == ["Split Right", "Split Down", "Close Tab"])
        try window.chooseMenuItem("Split Right")
        await settle(window)
        let layout = rig.workspace.codeLayout
        #expect(layout.tree.groupIDs.count == 2)
        let g1 = layout.tree.groupIDs[1]
        #expect(layout.groups[g1]?.tabs == ["b.swift"] && layout.groups[g1]?.activeTab == "b.swift")
        #expect(layout.groups[g0]?.activeTab == "b.swift", "the right click selected the tab first")
        #expect(layout.focusedGroupID == g1)
        let a = try frame(window, "code-group-\(g0)"), b = try frame(window, "code-group-\(g1)")
        #expect(a.maxX.value <= b.minX.value + 0.5, "side by side")
    }

    @Test func tabContextMenuSplitsDownAndClosesATab() async throws {
        let (rig, window, g0) = try await setup(files: ["a.swift", "b.swift"])
        try window.rightClick(window.element(identifier: "group-\(g0)-tab-a.swift"))
        try window.chooseMenuItem("Split Down")
        await settle(window)
        let layout = rig.workspace.codeLayout
        #expect(layout.tree.groupIDs.count == 2)
        let g1 = layout.tree.groupIDs[1]
        #expect(layout.groups[g1]?.tabs == ["a.swift"])
        #expect(try frame(window, "code-group-\(g0)").maxY.value <= frame(window, "code-group-\(g1)").minY.value + 0.5)
        try window.rightClick(window.element(identifier: "group-\(g0)-tab-b.swift"))
        try window.chooseMenuItem("Close Tab")
        try await window.runUntil { layout.groups[g0]?.tabs == ["a.swift"] }
        #expect(layout.groups[g0]?.tabs == ["a.swift"])
    }

    @Test func tabContextMenuInAnUnfocusedGroupSplitsThatGroupWithTheClickedFile() async throws {
        let (rig, window, g0) = try await setup(files: ["a.swift", "b.swift"])
        let layout = rig.workspace.codeLayout
        rig.workspace.activate("a.swift", in: .group(g0))
        window.typeKey("\\", modifierFlags: [.command])
        await settle(window)
        let g1 = layout.tree.groupIDs[1]
        #expect(layout.focusedGroupID == g1)
        try await window.runUntil { self.exists(window, "group-\(g0)-tab-b.swift") }
        try window.rightClick(window.element(identifier: "group-\(g0)-tab-b.swift"))
        try window.chooseMenuItem("Split Right")
        try await window.runUntil { layout.tree.groupIDs.count == 3 }
        let ids = layout.tree.groupIDs
        #expect(ids[0] == g0 && ids[2] == g1, "the new group opened beside g0, not beside the focused group: \(ids)")
        let fresh = ids[1]
        #expect(layout.groups[fresh]?.tabs == ["b.swift"] && layout.focusedGroupID == fresh)
        #expect(layout.groups[g1]?.tabs == ["a.swift"] && layout.groups[g1]?.activeTab == "a.swift", "the previously focused group's content is unchanged")
    }

    @Test func tabContextMenuCloseSavesADirtyFileThenCloses() async throws {
        let (rig, window, g0) = try await setup()
        let doc = try #require(rig.workspace.document("a.swift"))
        doc.buffer.replace(0..<0, with: "typed ")
        #expect(doc.isDirty)
        try window.rightClick(window.element(identifier: "group-\(g0)-tab-a.swift"))
        try window.chooseMenuItem("Close Tab")
        try await window.runUntil { rig.workspace.codeLayout.groups[g0]?.tabs.isEmpty == true }
        let onDisk = try String(contentsOf: rig.root.appendingPathComponent("a.swift"), encoding: .utf8)
        #expect(onDisk.hasPrefix("typed "), "saved before it closed: \(onDisk)")
        #expect(rig.workspace.document("a.swift") == nil)
    }

    @Test func splitDividerIsFoundByItsIdentifierAndResizesThePane() async throws {
        let (rig, window, g0) = try await setup()
        window.typeKey("\\", modifierFlags: [.command])
        await settle(window)
        let g1 = rig.workspace.codeLayout.tree.groupIDs[1]
        guard case .split(let splitID, _, _, _) = rig.workspace.codeLayout.tree else { Issue.record("no split"); return }
        let divider = try window.element(identifier: "code-split-\(splitID).0")
        #expect(divider.role == .splitter)
        let before = try frame(window, "code-group-\(g0)").size.width.value
        let target = Double(before - 80)
        #expect(try window.setAccessibilityValue(target, on: divider))
        await settle(window)
        let after = try frame(window, "code-group-\(g0)").size.width.value
        #expect(abs(Double(after) - target) < 2 && after < before, "\(before) -> \(after)")
        #expect(try frame(window, "code-group-\(g1)").size.width.value > 0)
        #expect(try window.element(identifier: "code-main.0").role == .splitter, "the three-island split's dividers too")
    }

    @Test func optionCmdBackslashNestsDown() async throws {
        let (rig, window, _) = try await setup()
        window.typeKey("\\", modifierFlags: [.command])
        await settle(window)
        window.typeKey("\\", modifierFlags: [.option, .command])
        await settle(window)
        let ids = rig.workspace.codeLayout.tree.groupIDs
        #expect(ids.count == 3)
        let frames = try ids.map { try frame(window, "code-group-\($0)") }
        for i in 0..<3 { for j in (i + 1)..<3 { #expect(!overlap(frames[i], frames[j])) } }
        let island = try frame(window, "island-code-editor")
        for f in frames {
            #expect(f.minX.value >= island.minX.value - 1 && f.maxX.value <= island.maxX.value + 1)
            #expect(f.minY.value >= island.minY.value - 1 && f.maxY.value <= island.maxY.value + 1)
        }
        // The new group is under the second one.
        #expect(frames[2].minY.value >= frames[1].maxY.value - 0.5)
    }

    @Test func typingInOneGroupEditsTheSharedBuffer() async throws {
        let (rig, window, g0) = try await setup()
        window.typeKey("\\", modifierFlags: [.command])
        await settle(window)
        let g1 = rig.workspace.codeLayout.tree.groupIDs[1]
        let doc = try #require(rig.workspace.document("a.swift"))
        let before = doc.buffer.snapshot().text
        try window.click(window.element(identifier: "code-view-\(g1)"))
        await settle(window)
        window.typeText("Z")
        await settle(window)
        #expect(doc.buffer.snapshot().text != before)
        let v0 = try #require(CodePanelStore.existingView(for: doc, in: .group(g0)))
        let v1 = try #require(CodePanelStore.existingView(for: doc, in: .group(g1)))
        #expect(v0.document === v1.document)
        #expect(v0.scroll !== v1.scroll)
    }

    @Test func closingTheLastTabCollapsesTheGroup() async throws {
        let (rig, window, g0) = try await setup()
        window.typeKey("\\", modifierFlags: [.command])
        await settle(window)
        let g1 = rig.workspace.codeLayout.tree.groupIDs[1]
        try window.click(window.element(identifier: "group-\(g1)-tab-close-a.swift"))
        try await window.runUntil { !self.exists(window, "code-group-\(g1)") }
        await settle(window)
        let island = try frame(window, "island-code-editor"), only = try frame(window, "code-group-\(g0)")
        #expect(only.maxX.value - only.minX.value > (island.maxX.value - island.minX.value) - 4)
        // The closed group's views and the file's services stay for the group that still holds it.
        let doc = try #require(rig.workspace.document("a.swift"))
        #expect(CodePanelStore.existingView(for: doc, in: .group(g1)) == nil)
        let kept = try #require(CodePanelStore.existingView(for: doc, in: .group(g0)))
        #expect(!kept.services.closed)
    }

    @Test func focusShortcutsMoveFocus() async throws {
        let (rig, window, g0) = try await setup()
        window.typeKey("\\", modifierFlags: [.command])
        await settle(window)
        let g1 = rig.workspace.codeLayout.tree.groupIDs[1]
        #expect(rig.workspace.codeLayout.focusedGroupID == g1)
        window.typeKey(.leftArrow, modifierFlags: [.control, .command])
        #expect(rig.workspace.codeLayout.focusedGroupID == g0)
        window.typeKey(.rightArrow, modifierFlags: [.control, .command])
        #expect(rig.workspace.codeLayout.focusedGroupID == g1)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "view-focus-left")
        #expect(rig.workspace.codeLayout.focusedGroupID == g0)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "view-split-down")
        await settle(window)
        #expect(rig.workspace.codeLayout.tree.groupIDs.count == 3)
    }

    @Test func viewMenuItemsAreDisabledInChatMode() async throws {
        // The group has an active tab, so a split would happen if the item were enabled.
        let (rig, window, g0) = try await setup()
        rig.workspace.setMode(.chat)
        await settle(window)
        #expect(rig.workspace.codeLayout.groups[g0]?.activeTab == "a.swift")
        window.typeKey("\\", modifierFlags: [.command])
        window.typeKey("\\", modifierFlags: [.option, .command])
        await settle(window)
        #expect(rig.workspace.codeLayout.tree.groupIDs.count == 1)
    }

    @Test func tabClickInAnUnfocusedGroupFocusesIt() async throws {
        let (rig, window, g0) = try await setup()
        window.typeKey("\\", modifierFlags: [.command])
        await settle(window)
        let g1 = rig.workspace.codeLayout.tree.groupIDs[1]
        rig.workspace.focusGroup(id: g0)
        await settle(window)
        #expect(rig.workspace.codeLayout.focusedGroupID == g0)
        try window.click(window.element(identifier: "group-\(g1)-tab-a.swift"))
        await settle(window)
        #expect(rig.workspace.codeLayout.focusedGroupID == g1)
    }

    @Test func clickingACodeViewFocusesItsGroup() async throws {
        let (rig, window, g0) = try await setup()
        window.typeKey("\\", modifierFlags: [.command])
        await settle(window)
        #expect(rig.workspace.codeLayout.focusedGroupID != g0)
        try window.click(window.element(identifier: "code-view-\(g0)"))
        await settle(window)
        #expect(rig.workspace.codeLayout.focusedGroupID == g0)
    }

    @Test func aLateBlurOfAnotherGroupLeavesTheFocusedOneFocused() {
        let rig = Rig()
        let a = PaneID.group(UUID()), b = PaneID.group(UUID())
        rig.workspace.codeFocusChanged(true, pane: a)
        rig.workspace.codeFocusChanged(true, pane: b)
        rig.workspace.codeFocusChanged(false, pane: a)
        #expect(rig.workspace.focusedCodePane == b)
        rig.workspace.codeFocusChanged(false, pane: b)
        #expect(rig.workspace.focusedCodePane == nil)
        rig.workspace.codePanelFocused = true
        #expect(rig.workspace.focusedCodePane == .chat)
        rig.workspace.setMode(.code)
        #expect(rig.workspace.focusedCodePane == nil)
    }

    @Test func emptyStateShowsInTheLastGroup() async throws {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let window = try alloyWindow(rig.workspace)
        await settle(window)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        #expect(exists(window, "code-group-empty-\(g0)"))
        #expect(exists(window, "code-group-\(g0)"))
    }

    @Test func splitNamesFollowNodeIDs() async throws {
        let (rig, window, _) = try await setup()
        window.typeKey("\\", modifierFlags: [.command])
        await settle(window)
        guard case .split(let id, _, _, _) = rig.workspace.codeLayout.tree else { Issue.record("no split"); return }
        #expect(exists(window, "code-split-\(id)"))
    }

    @Test func splitNamesAreQueriedFromTheStore() async throws {
        let rig = Rig()
        try "x\n".write(to: rig.root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        await rig.workspace.open("a.swift", in: .group(rig.workspace.codeLayout.focusedGroupID))
        let store = UIStateSplitStore(workspace: rig.workspace)
        let panel = CodePanelStore(), sessions = SessionUIStore(), quickOpen = QuickOpenModel()
        let workspace = rig.workspace
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            VStack(spacing: 0) {
                CodeIslandRow(workspace: workspace, store: sessions, panel: panel, terminal: TerminalPanelStore(workspace: workspace), quickOpen: quickOpen, splitStore: store, style: .defaults)
            }
        }
        window.installAlloyMenu(rig.workspace)
        for _ in 0..<3 { window.tick() }
        rig.workspace.splitFocused(.horizontal)
        for _ in 0..<4 { window.tick(); await Task.yield() }
        guard case .split(let id, _, _, _) = rig.workspace.codeLayout.tree else { Issue.record("no split"); return }
        #expect(store.queriedNames.contains("code-split-\(id)"))
    }

    @Test func quickOpenOpensIntoTheFocusedGroup() async throws {
        let (rig, window, g0) = try await setup()
        window.typeKey("\\", modifierFlags: [.command])
        await settle(window)
        let g1 = rig.workspace.codeLayout.tree.groupIDs[1]
        window.typeKey("p", modifierFlags: [.command])
        try await window.runUntil { self.exists(window, "quick-open-field") }
        window.typeText("b.sw")
        try await window.runUntil { self.exists(window, "quick-open-row-0") }
        window.typeKey(.return)
        try await window.runUntil { rig.workspace.activeTab(in: .group(g1)) == "b.swift" }
        #expect(rig.workspace.activeTab(in: .group(g0)) == "a.swift")
        #expect(rig.workspace.tabs.isEmpty)
    }

    @Test func presentationPickerIsPerGroup() async throws {
        let (rig, window, g0) = try await setup()
        window.typeKey("\\", modifierFlags: [.command])
        await settle(window)
        let g1 = rig.workspace.codeLayout.tree.groupIDs[1]
        let picker = try window.element(identifier: "code-group-presentation-\(g1)")
        // The segments are buttons below the picker; the last is "Side by side".
        let segments = descendants(of: picker, in: window).filter { $0.role == .button || $0.role == .radioButton }
        let side = try #require(segments.last)
        try window.click(side)
        await settle(window)
        #expect(rig.workspace.presentation(of: "a.swift", in: .group(g1)) == .sideBySide)
        #expect(rig.workspace.presentation(of: "a.swift", in: .group(g0)) == .plain)
        // Side-by-side ids carry the group's suffix.
        #expect(exists(window, "sbs-right-\(g1)"))
        #expect(!exists(window, "sbs-right"))
    }

    @Test func f12GoesToDefinitionInTheFocusedGroup() async throws { try await definition(viaMenu: false) }

    @Test func goToDefinitionMenuItemUsesTheFocusedGroup() async throws { try await definition(viaMenu: true) }

    private func definition(viaMenu: Bool) async throws {
        let rig = Rig()
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-groupdef-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: log) }
        let launcher = ServerLauncher { _, resolved, root in
            let target = root.appendingPathComponent("lib.rs").absoluteString
            var env = ProcessInfo.processInfo.environment
            env["FAKE_LSP_SCRIPT"] = #"{"capabilities":{"textDocumentSync":2,"definitionProvider":true},"definition":[{"uri":"\#(target)","range":{"start":{"line":1,"character":3},"end":{"line":1,"character":8}}}]}"#
            env["FAKE_LSP_LOG"] = log.path
            return try ServerProcess(executable: resolved, arguments: [], environment: env, currentDirectory: root)
        }
        let config = ServerConfig(id: "fake", name: "Fake", languageID: "rust", extensions: ["rs"], command: fakeServerPath)
        let coordinator = LSPCoordinator.install(on: rig.workspace, builtIn: [config],
                                                 locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                                 launcher: launcher)
        try "use lib;\nfn main() { call(); }\n".write(to: rig.root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        try "// lib\nfn call() {}\n".write(to: rig.root.appendingPathComponent("lib.rs"), atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open("main.rs", in: .group(g0))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-view-\(g0.uuidString)") }
        window.typeKey("\\", modifierFlags: [.command])
        await settle(window)
        let g1 = rig.workspace.codeLayout.tree.groupIDs[1]
        try await window.runUntil { coordinator.status.byPath["main.rs"]?.state == .ready }
        await settle(window, 5)
        // The new group has focus after the split; clicking the first group's code moves it there.
        #expect(rig.workspace.codeLayout.focusedGroupID == g1)
        try window.click(window.element(identifier: "code-view-\(g0)"))
        await settle(window, 5)
        #expect(rig.workspace.codeLayout.focusedGroupID == g0)
        _ = try #require(rig.workspace.document("main.rs"))
        rig.workspace.selectionState(for: "main.rs", in: .group(g0))!.select(20..<20, reveal: false)
        if viaMenu { rig.workspace.goToDefinition?() } else { window.typeKey(FilePanelView.f12) }
        try await window.runUntil { rig.workspace.activeTab(in: .group(g0)) == "lib.rs" }
        #expect(rig.workspace.activeTab(in: .group(g1)) == "main.rs")
        #expect(rig.workspace.tabs.isEmpty)
        await rig.workspace.stopAll()
    }

    @Test func groupTabsReleaseTheirViewsWhenClosed() async throws {
        let (rig, window, g0) = try await setup(files: ["a.swift", "b.swift"])
        await settle(window)
        let b = try #require(rig.workspace.document("b.swift"))
        #expect(rig.workspace.activeTab(in: .group(g0)) == "b.swift")
        rig.workspace.activate("b.swift", in: .group(g0))
        await settle(window)
        #expect(CodePanelStore.existingView(for: b, in: .group(g0)) != nil)
        try window.click(window.element(identifier: "group-\(g0)-tab-close-b.swift"))
        try await window.runUntil { rig.workspace.tabs(in: .group(g0)) == ["a.swift"] }
        await settle(window)
        #expect(CodePanelStore.existingView(for: b, in: .group(g0)) == nil)
    }

    @Test func closeFinishingAfterSwitchToChatReleasesTheGroupView() async throws {
        let (rig, window, g0) = try await setup()
        let doc = try #require(rig.workspace.document("a.swift"))
        try await window.runUntil { CodePanelStore.existingView(for: doc, in: .group(g0)) != nil }
        doc.buffer.replace(0..<0, with: "x", origin: .typing)
        #expect(doc.isDirty)
        rig.workspace.requestClose("a.swift", in: .group(g0))   // the save is still in flight
        rig.workspace.setMode(.chat)
        await rig.workspace.settle()
        #expect(rig.workspace.tabs(in: .group(g0)).isEmpty)
        await settle(window, 6)
        #expect(CodePanelStore.existingView(for: doc, in: .group(g0)) == nil, "released while Chat is shown")
    }

    @Test func chatCloseFinishingAfterSwitchToCodeReleasesTheChatView() async throws {
        let rig = Rig()
        try "let a = 1\n".write(to: rig.root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.openFilePath = "a.swift"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-view") }
        let doc = try #require(rig.workspace.document("a.swift"))
        #expect(CodePanelStore.existingView(for: doc, in: .chat) != nil)
        doc.buffer.replace(0..<0, with: "x", origin: .typing)
        rig.workspace.requestClose("a.swift", in: .chat)
        window.typeKey("2", modifierFlags: [.control, .command])
        await rig.workspace.settle()
        await settle(window, 6)
        #expect(rig.workspace.mode == .code)
        #expect(rig.workspace.tabs.isEmpty)
        #expect(CodePanelStore.existingView(for: doc, in: .chat) == nil, "released while Code is shown")
    }
}
