@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

@MainActor @Suite struct PaneSelectionTests {
    /// Code mode with "a" (ten lines) open in two groups: the first, then a second made by hand (no split copy).
    private func twoPanes() async -> (Env, PaneID, PaneID) {
        let e = Env()
        e.ws.setMode(.code)
        e.write("a", (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n")
        let g0 = e.ws.codeLayout.focusedGroupID
        await e.ws.open("a", in: .group(g0))
        e.ws.splitFocused(.horizontal)
        let g1 = e.ws.codeLayout.focusedGroupID
        return (e, .group(g0), .group(g1))
    }

    private func state(_ e: Env, _ pane: PaneID) -> CodeSelectionState {
        e.ws.selectionState(for: "a", in: pane)!
    }

    @Test func panesHaveIndependentCarets() async {
        let (e, p0, p1) = await twoPanes(); defer { e.cleanup() }
        state(e, p0).select(5..<5)
        state(e, p1).select(20..<20)
        #expect(state(e, p0).primarySelection.head == 5)
        #expect(state(e, p1).primarySelection.head == 20)
        #expect(state(e, p0) !== state(e, p1))
    }

    @Test func typingInOnePaneMovesTheOthersCaretAfterIt() async {
        let (e, p0, p1) = await twoPanes(); defer { e.cleanup() }
        state(e, p0).select(2..<2)
        state(e, p1).select(20..<20)
        state(e, p0).replaceSelections(with: "XYZ")
        #expect(state(e, p0).primarySelection.head == 5)
        #expect(state(e, p1).primarySelection.head == 23)
    }

    @Test func aSplitCopiesTheCaret() async {
        let e = Env(); defer { e.cleanup() }
        e.ws.setMode(.code)
        e.write("a", "hello world\n")
        let g0 = e.ws.codeLayout.focusedGroupID
        await e.ws.open("a", in: .group(g0))
        e.ws.selectionState(for: "a", in: .group(g0))!.select(3..<7)
        e.ws.splitFocused(.horizontal)
        let g1 = e.ws.codeLayout.focusedGroupID
        let copy = e.ws.selectionState(for: "a", in: .group(g1))!
        #expect(copy.primarySelection == CodeSelection(anchor: 3, head: 7))
        copy.select(0..<0)
        #expect(e.ws.selectionState(for: "a", in: .group(g0))!.primarySelection.head == 7)
    }

    @Test func aNewPaneSeedsFromTheMostRecentlyFocusedPane() async {
        let (e, p0, p1) = await twoPanes(); defer { e.cleanup() }
        guard case .group(let id0) = p0, case .group(let id1) = p1 else { return }
        state(e, p0).select(8..<8)
        state(e, p1).select(30..<30)
        e.ws.focusGroup(id: id0)
        // A third pane (Chat) opens the file: it follows group 0, the last one focused.
        await e.ws.open("a", in: .chat)
        #expect(e.ws.selectionState(for: "a", in: .chat)!.primarySelection.head == 8)
        e.ws.focusGroup(id: id1)
        e.ws.requestClose("a", in: .chat)
        await e.ws.settle()
        #expect(e.ws.selectionState(for: "a", in: .chat) == nil)
        await e.ws.open("a", in: .chat)
        #expect(e.ws.selectionState(for: "a", in: .chat)!.primarySelection.head == 30)
    }

    @Test func openRevealLineMovesOnlyThatPanesCaret() async {
        let (e, p0, p1) = await twoPanes(); defer { e.cleanup() }
        state(e, p0).select(0..<0)
        state(e, p1).select(0..<0)
        await e.ws.open("a", revealLine: 3, in: p1)
        #expect(state(e, p0).primarySelection == CodeSelection(anchor: 0, head: 0))
        #expect(state(e, p1).primarySelection == CodeSelection(anchor: 14, head: 20))
        #expect(e.ws.document("a")!.buffer.selectionState.primarySelection.head == 0)
    }

    @Test func openSelectingMovesOnlyThatPanesCaret() async {
        let (e, p0, p1) = await twoPanes(); defer { e.cleanup() }
        await e.ws.open("a", selecting: { _ in 2..<4 }, in: p0)
        #expect(state(e, p0).primarySelection == CodeSelection(anchor: 2, head: 4))
        #expect(state(e, p1).primarySelection.head != 4 || state(e, p1).primarySelection.anchor != 2)
    }

    @Test func releasingAPaneDropsItsState() async {
        let (e, p0, p1) = await twoPanes(); defer { e.cleanup() }
        weak var weakState: CodeSelectionState?
        do { weakState = state(e, p1); #expect(weakState != nil) }
        await e.ws.close("a", in: p1)
        #expect(e.ws.selectionState(for: "a", in: p1) == nil)
        #expect(weakState == nil)
        #expect(e.ws.selectionState(for: "a", in: p0) != nil)
    }

    @Test func chatCodeChatKeepsEachPanesCaret() async {
        let e = Env(); defer { e.cleanup() }
        e.write("a", "0123456789\n")
        await e.ws.open("a", in: .chat)
        e.ws.setMode(.code)
        let g0 = PaneID.group(e.ws.codeLayout.focusedGroupID)
        await e.ws.open("a", in: g0)
        e.ws.selectionState(for: "a", in: .chat)!.select(2..<2)
        e.ws.selectionState(for: "a", in: g0)!.select(6..<6)
        e.ws.setMode(.chat)
        e.ws.setMode(.code)
        e.ws.setMode(.chat)
        #expect(e.ws.selectionState(for: "a", in: .chat)!.primarySelection.head == 2)
        #expect(e.ws.selectionState(for: "a", in: g0)!.primarySelection.head == 6)
    }

    @Test func recencyFollowsModeSwitches() async {
        let (e, _, p1) = await twoPanes(); defer { e.cleanup() }
        e.write("b", "x\n")
        e.ws.setMode(.chat)
        #expect(e.ws.paneFocusLog.first == .chat)
        e.ws.setMode(.code)
        #expect(e.ws.paneFocusLog.first == p1)
    }

    @Test func collapsingAGroupDropsItsStatesAndFocusEntry() async {
        let (e, p0, p1) = await twoPanes(); defer { e.cleanup() }
        weak var weakState: CodeSelectionState?
        do { weakState = state(e, p1) }
        await e.ws.close("a", in: p1)
        #expect(e.ws.codeLayout.groups.count == 1)
        #expect(e.ws.paneSelections[p1] == nil)
        #expect(!e.ws.paneFocusLog.contains(p1))
        #expect(weakState == nil)
        #expect(e.ws.selectionState(for: "a", in: p0) != nil)
    }

    @Test func aDocumentKeptByAnotherHolderKeepsItsOtherStates() async {
        let (e, p0, p1) = await twoPanes(); defer { e.cleanup() }
        let keep = state(e, p0)
        keep.select(6..<6)
        await e.ws.close("a", in: p1)
        #expect(e.ws.document("a") != nil)
        #expect(e.ws.selectionState(for: "a", in: p0) === keep)
        #expect(keep.primarySelection.head == 6)
    }

    @Test func restoringTheLayoutKeepsTheFocusLog() async {
        let (e, p0, _) = await twoPanes(); defer { e.cleanup() }
        guard case .group(let id0) = p0 else { return }
        e.ws.focusGroup(id: id0)
        guard let layout = e.ws.currentUIState().layout else { Issue.record("layout"); return }
        e.ws.installLayout(layout, existing: ["a"])
        #expect(e.ws.paneFocusLog.first == p0)
        // The restored groups get fresh states (the tabs were replaced) over the same document.
        #expect(e.ws.selectionState(for: "a", in: p0)?.buffer === e.ws.document("a")?.buffer)
    }

    @Test func aSplitOfAnUnloadedDocumentHasNothingToCopy() async {
        let e = Env(); defer { e.cleanup() }
        e.ws.setMode(.code)
        let g0 = e.ws.codeLayout.focusedGroupID
        e.ws.addTab("a", in: .group(g0)); e.ws.setActive("a", in: .group(g0))
        e.ws.splitFocused(.horizontal)
        #expect(e.ws.selectionState(for: "a", in: .group(g0)) == nil)
        e.write("a", "hello\n")
        await e.ws.open("a", in: .group(g0))
        #expect(e.ws.selectionState(for: "a", in: .group(e.ws.codeLayout.focusedGroupID)) != nil)
    }
}
