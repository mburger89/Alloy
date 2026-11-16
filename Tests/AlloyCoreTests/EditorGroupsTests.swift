@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

@MainActor @Suite struct EditorGroupsTests {
    private func code() -> Env {
        let e = Env(); e.ws.setMode(.code); return e
    }

    private func split(_ id: UUID, _ axis: SplitAxis, _ a: SplitTree, _ b: SplitTree) -> SplitTree {
        .split(id: id, axis: axis, first: a, second: b)
    }

    /// Opens `path` into the focused group.
    private func open(_ e: Env, _ path: String) async {
        e.write(path, "\(path)\n")
        await e.ws.open(path, in: .group(e.ws.codeLayout.focusedGroupID))
    }

    @Test func splitRightOpensTheSameDocumentInANewFocusedGroup() async throws {
        let e = code(); defer { e.cleanup() }
        await open(e, "a")
        let g0 = e.ws.codeLayout.focusedGroupID
        e.ws.splitFocused(.horizontal)
        let g1 = e.ws.codeLayout.focusedGroupID
        #expect(g1 != g0)
        guard case .split(_, .horizontal, .group(let f), .group(let s)) = e.ws.codeLayout.tree else { Issue.record("tree"); return }
        #expect(f == g0 && s == g1)
        #expect(e.ws.activeTab(in: .group(g0)) == "a" && e.ws.activeTab(in: .group(g1)) == "a")
        #expect(e.ws.tabs(in: .group(g1)) == ["a"])
        #expect(e.ws.documents.count == 1)
    }

    @Test func splitDownUsesTheVerticalAxis() async {
        let e = code(); defer { e.cleanup() }
        await open(e, "a")
        e.ws.splitFocused(.vertical)
        guard case .split(_, let axis, _, _) = e.ws.codeLayout.tree else { Issue.record("tree"); return }
        #expect(axis == .vertical)
    }

    @Test func splittingAnEmptyGroupDoesNothing() {
        let e = code(); defer { e.cleanup() }
        e.ws.splitFocused(.horizontal)
        #expect(e.ws.codeLayout.groups.count == 1)
        #expect(e.ws.codeLayout.tree == .group(e.ws.codeLayout.focusedGroupID))
    }

    @Test func closingTheLastTabClosesTheGroupAndFocusesTheNeighbour() async {
        let e = code(); defer { e.cleanup() }
        await open(e, "a")
        let g0 = e.ws.codeLayout.focusedGroupID
        e.ws.splitFocused(.horizontal)
        let g1 = e.ws.codeLayout.focusedGroupID
        await e.ws.close("a", in: .group(g1))
        #expect(e.ws.codeLayout.groups.count == 1)
        #expect(e.ws.codeLayout.tree == .group(g0))
        #expect(e.ws.codeLayout.focusedGroupID == g0)
        #expect(e.ws.codeLayout.groups[g1] == nil)
    }

    @Test func nestedCloseCollapsesToTheSibling() async {
        let e = code(); defer { e.cleanup() }
        await open(e, "a")
        let a = e.ws.codeLayout.focusedGroupID
        e.ws.splitFocused(.horizontal)
        let b = e.ws.codeLayout.focusedGroupID
        e.ws.splitFocused(.vertical)
        let c = e.ws.codeLayout.focusedGroupID
        guard case .split(_, _, _, .split(_, .vertical, .group(let x), .group(let y))) = e.ws.codeLayout.tree else { Issue.record("tree"); return }
        #expect(x == b && y == c)
        await e.ws.close("a", in: .group(c))
        guard case .split(_, .horizontal, .group(let f), .group(let s)) = e.ws.codeLayout.tree else { Issue.record("collapsed"); return }
        #expect(f == a && s == b)
        #expect(e.ws.codeLayout.focusedGroupID == b)
    }

    @Test func theLastGroupStaysEmpty() async {
        let e = code(); defer { e.cleanup() }
        await open(e, "a")
        let g = e.ws.codeLayout.focusedGroupID
        await e.ws.close("a", in: .group(g))
        #expect(e.ws.codeLayout.groups.count == 1)
        #expect(e.ws.tabs(in: .group(g)) == [])
        #expect(e.ws.activeTab(in: .group(g)) == nil)
    }

    @Test func focusMovesDoNotSave() async throws {
        let e = code(); defer { e.cleanup() }
        await open(e, "a")
        let g0 = e.ws.codeLayout.focusedGroupID
        e.ws.splitFocused(.horizontal)
        e.ws.focusGroup(id: g0)
        let doc = try #require(e.ws.document("a"))
        _ = doc.buffer.replace(0..<0, with: "typed ")
        let writes = e.ws.writeCount
        e.ws.focusGroup(.right)
        #expect(e.ws.codeLayout.focusedGroupID != g0)
        e.ws.focusGroup(.left)
        #expect(e.ws.codeLayout.focusedGroupID == g0)
        #expect(e.ws.writeCount == writes)
        #expect(doc.isDirty)
    }

    @Test func cmdWClosesTheFocusedGroupsTab() async {
        let e = code(); defer { e.cleanup() }
        await open(e, "a"); await open(e, "b")
        e.ws.closeActiveTab()
        await e.ws.settle()
        let g = PaneID.group(e.ws.codeLayout.focusedGroupID)
        #expect(e.ws.tabs(in: g) == ["a"])
        #expect(e.ws.tabs == [] && e.ws.activeTab == nil)
    }

    @Test func ctrlTabCyclesWithinTheFocusedGroup() async {
        let e = code(); defer { e.cleanup() }
        await open(e, "a"); await open(e, "b")
        let g = PaneID.group(e.ws.codeLayout.focusedGroupID)
        e.ws.cycleTab(1)
        #expect(e.ws.activeTab(in: g) == "a")
        e.ws.cycleTab(-1)
        #expect(e.ws.activeTab(in: g) == "b")
        #expect(e.ws.tabs == [] && e.ws.activeTab == nil)
    }

    @Test func cmdNumberSelectsInTheFocusedGroup() async {
        let e = code(); defer { e.cleanup() }
        await open(e, "a"); await open(e, "b")
        let g = PaneID.group(e.ws.codeLayout.focusedGroupID)
        e.ws.selectTab(number: 1)
        #expect(e.ws.activeTab(in: g) == "a")
        e.ws.selectTab(number: 9)
        #expect(e.ws.activeTab(in: g) == "a")
        #expect(e.ws.tabs == [] && e.ws.activeTab == nil)
    }

    @Test func requestOpenGoesToTheFocusedGroup() async {
        let e = code(); defer { e.cleanup() }
        e.write("b", "b\n")
        e.ws.requestOpen("b")
        await e.ws.settle()
        let g = PaneID.group(e.ws.codeLayout.focusedGroupID)
        #expect(e.ws.tabs(in: g) == ["b"])
        #expect(e.ws.tabs == [])
    }

    @Test func commandLineOpenGoesToTheFocusedGroup() async {
        let e = code(); defer { e.cleanup() }
        e.write("b", "b\n")
        e.ws.openFilePath = "b"
        await e.ws.settle()
        let g = PaneID.group(e.ws.codeLayout.focusedGroupID)
        #expect(e.ws.tabs(in: g) == ["b"])
        #expect(e.ws.tabs == [] && e.ws.activeTab == nil)
    }

    @Test func followEditsDoesNothingInCodeMode() async {
        let e = Env(); defer { e.cleanup() }
        let old = "one\ntwo\n", new = "one\nTWO\n"
        e.write("a.txt", old)
        _ = await e.ws.newSession(name: "Ann")
        e.ws.setMode(.code)
        let focus = e.ws.codeLayout.focusedGroupID
        e.write("a.txt", new)
        let hunks = Patch.diff(old: TextLines(old).lines, new: TextLines(new).lines, context: 0)
        let t = e.transports.all[0]
        await t.emit(.assistantBlock(messageID: "m1", block: .toolUse(id: "t1", name: "Edit", input: .object([:]))))
        await t.emit(.toolResult(ToolResultMessage(toolUseID: "t1", isError: false, text: "ok",
                                                   result: .edit(filePath: e.url("a.txt").path, originalFile: old, hunks: hunks))))
        await e.ws.settle()
        #expect(e.ws.tabs == [] && e.ws.activeTab == nil)
        #expect(e.ws.codeLayout.groups.count == 1)
        #expect(e.ws.tabs(in: .group(focus)) == [])
        #expect(e.ws.codeLayout.focusedGroupID == focus)
    }

    @Test func sharedDirtyFileSavesOnceAndLivesUntilTheLastHolderCloses() async throws {
        let e = code(); defer { e.cleanup() }
        await open(e, "a")
        let g0 = e.ws.codeLayout.focusedGroupID
        e.ws.splitFocused(.horizontal)
        let g1 = e.ws.codeLayout.focusedGroupID
        e.ws.focusGroup(id: g0)
        let doc = try #require(e.ws.document("a"))
        _ = doc.buffer.replace(0..<0, with: "typed ")
        let writes = e.ws.writeCount
        await e.ws.close("a", in: .group(g0))
        #expect(e.ws.writeCount == writes + 1)
        #expect(e.read("a") == "typed a\n")
        #expect(e.ws.document("a") === doc)
        #expect(doc.buffer.canUndo)
        #expect(e.ws.tabs(in: .group(g1)) == ["a"])
        await e.ws.close("a", in: .group(g1))
        #expect(e.ws.document("a") == nil)
    }

    @Test func closingAnUnfocusedGroupsLastTabRemovesItAndKeepsFocus() async {
        let e = code(); defer { e.cleanup() }
        await open(e, "a")
        let g0 = e.ws.codeLayout.focusedGroupID
        e.ws.splitFocused(.horizontal)
        let g1 = e.ws.codeLayout.focusedGroupID
        await e.ws.close("a", in: .group(g0))
        #expect(e.ws.codeLayout.groups[g0] == nil)
        #expect(e.ws.codeLayout.tree == .group(g1))
        #expect(e.ws.codeLayout.focusedGroupID == g1)
    }

    @Test func followEditsDoesNothingInCodeModeEvenWithPanelFocus() async {
        let e = Env(); defer { e.cleanup() }
        let old = "one\ntwo\n", new = "one\nTWO\n"
        e.write("a.txt", old)
        _ = await e.ws.newSession(name: "Ann")
        e.ws.setMode(.code)
        e.ws.codePanelFocused = true
        let focus = e.ws.codeLayout.focusedGroupID
        e.write("a.txt", new)
        let hunks = Patch.diff(old: TextLines(old).lines, new: TextLines(new).lines, context: 0)
        let t = e.transports.all[0]
        await t.emit(.assistantBlock(messageID: "m1", block: .toolUse(id: "t1", name: "Edit", input: .object([:]))))
        await t.emit(.toolResult(ToolResultMessage(toolUseID: "t1", isError: false, text: "ok",
                                                   result: .edit(filePath: e.url("a.txt").path, originalFile: old, hunks: hunks))))
        await e.ws.settle()
        #expect(e.ws.tabs == [] && e.ws.codeLayout.groups.count == 1)
        #expect(e.ws.tabs(in: .group(focus)) == [])
        #expect(e.ws.codeLayout.focusedGroupID == focus)
    }
}
