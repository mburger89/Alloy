@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// Per-pane carets as the views show them: each editor group's CodeView runs on its pane's selection state.
@MainActor
@Suite struct ViewSelectionTests {
    @MainActor private struct Setup {
        let rig: Rig
        let window: TestWindow
        let doc: EditorDocument
        let a: PaneID, b: PaneID
        let viewA: OpenDocumentView, viewB: OpenDocumentView
        var stateA: CodeSelectionState { rig.workspace.selectionState(for: "big.swift", in: a)! }
        var stateB: CodeSelectionState { rig.workspace.selectionState(for: "big.swift", in: b)! }
        func offset(row: Int, column: Int = 0) -> Int { doc.buffer.snapshot().offset(of: CodePoint(row: row, column: column)) }
        func settle(_ n: Int = 8) async { for _ in 0..<n { window.tick(); await Task.yield() } }
        /// The row of the caret the focused view reports to the input method.
        func reportedCaretY() -> Double? {
            guard let area = window.platformWindow.textInputAreas.last, let rect = area else { return nil }
            return Double(rect.origin.y.value)
        }
    }

    /// Code mode with a 400-line file open in two groups (the second made by a split).
    private func setup() async throws -> Setup {
        let rig = Rig()
        let text = (0..<400).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
        try text.write(to: rig.root.appendingPathComponent("big.swift"), atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open("big.swift", in: .group(g0))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view-\(g0.uuidString)")) != nil }
        rig.workspace.splitFocused(.horizontal)
        let g1 = rig.workspace.codeLayout.focusedGroupID
        try await window.runUntil { (try? window.element(identifier: "code-view-\(g1.uuidString)")) != nil }
        let doc = try #require(rig.workspace.document("big.swift"))
        let s = Setup(rig: rig, window: window, doc: doc, a: .group(g0), b: .group(g1),
                      viewA: try #require(CodePanelStore.existingView(for: doc, in: .group(g0))),
                      viewB: try #require(CodePanelStore.existingView(for: doc, in: .group(g1))))
        await s.settle()
        return s
    }

    private func focus(_ s: Setup, _ pane: PaneID) throws {
        guard case .group(let id) = pane else { return }
        try s.window.click(s.window.element(identifier: "code-view-\(id.uuidString)"))
    }

    @Test func twoGroupsShowDifferentCarets() async throws {
        let s = try await setup()
        try focus(s, s.a)
        s.stateA.select(s.offset(row: 3)..<s.offset(row: 3), reveal: false)
        s.stateB.select(s.offset(row: 3)..<s.offset(row: 3), reveal: false)
        await s.settle()
        let atA = s.reportedCaretY()
        s.stateA.select(s.offset(row: 5)..<s.offset(row: 5), reveal: false)
        await s.settle()
        #expect(s.reportedCaretY() != atA, "the focused view A draws its own caret")
        #expect(s.stateB.primarySelection.head == s.offset(row: 3))
        // Typing in A goes through A's state and leaves the default state alone.
        let before = s.doc.buffer.selectionState.primarySelection
        s.window.typeText("x")
        await s.settle()
        #expect(s.stateA.primarySelection.head == s.offset(row: 5) + 1)
        #expect(s.doc.buffer.selectionState.primarySelection == before)
    }

    @Test func typingInAMovesBsCaretButNotBsScroll() async throws {
        let s = try await setup()
        s.viewB.scroll.position = CodeScrollPosition(row: 200, x: 0)
        let spot = s.offset(row: 300)
        s.stateB.select(spot..<spot, reveal: false)
        try focus(s, s.a)
        s.stateA.select(s.offset(row: 2)..<s.offset(row: 2), reveal: false)
        await s.settle()
        let scrollB = s.viewB.scroll.position
        s.window.typeText("x")
        await s.settle()
        #expect(s.stateB.primarySelection.head == spot + 1)
        #expect(s.viewB.scroll.position == scrollB, "B stayed at \(scrollB), now \(s.viewB.scroll.position)")
    }

    @Test func undoInBPutsBsCaretAtTheChange() async throws {
        let s = try await setup()
        try focus(s, s.a)
        let at = s.offset(row: 4)
        s.stateA.select(at..<at, reveal: false)
        s.window.typeText("x")
        await s.settle()
        try focus(s, s.b)
        s.stateB.select(s.offset(row: 100)..<s.offset(row: 100), reveal: false)
        s.window.typeKey("z", modifierFlags: .command)
        await s.settle()
        #expect(s.doc.buffer.snapshot().utf8(in: at..<at + 1).elementsEqual(Array("l".utf8)), "undone")
        #expect(s.stateB.primarySelection.head == at, "B is at the change: \(s.stateB.primarySelection)")
    }

    @Test func findInAMovesOnlyA() async throws {
        let s = try await setup()
        let spot = s.offset(row: 250)
        s.stateB.select(spot..<spot, reveal: false)
        s.viewA.showFind()
        s.viewA.setQuery("value3")
        try await s.window.runUntil { s.viewA.findCount > 0 }
        s.viewA.step(1)
        await s.settle()
        #expect(s.stateA.primarySelection.head >= s.offset(row: 3))
        #expect(s.stateB.primarySelection == CodeSelection(caret: spot))
    }

    @Test func aSplitShowsTheSourcesCaret() async throws {
        let s = try await setup()
        let range = s.offset(row: 7)..<s.offset(row: 7, column: 5)
        s.stateB.select(range, reveal: false)
        let before = s.rig.workspace.codeLayout.groups.count
        // Splitting the focused group B copies its caret into the new group C.
        s.rig.workspace.splitFocused(.vertical)
        let c = PaneID.group(s.rig.workspace.codeLayout.focusedGroupID)
        #expect(s.rig.workspace.codeLayout.groups.count == before + 1)
        #expect(s.rig.workspace.selectionState(for: "big.swift", in: c)?.primarySelection.range == range)
        try await s.window.runUntil { (try? s.window.element(identifier: "code-view-\(s.rig.workspace.codeLayout.focusedGroupID.uuidString)")) != nil }
    }

    @Test func theDiffToggleKeepsTheCaret() async throws {
        let s = try await setup()
        let range = s.offset(row: 9)..<s.offset(row: 9, column: 4)
        s.stateB.select(range, reveal: false)
        for presentation in [Presentation.sideBySide, .inline, .plain] {
            s.rig.workspace.setPresentation(presentation, of: "big.swift", in: s.b)
            await s.settle()
            #expect(s.stateB.primarySelection.range == range, "\(presentation)")
        }
    }

    @Test func chatCodeChatKeepsEachCaret() async throws {
        let s = try await setup()
        await s.rig.workspace.open("big.swift", in: .chat)
        let chat = try #require(s.rig.workspace.selectionState(for: "big.swift", in: .chat))
        chat.select(s.offset(row: 11)..<s.offset(row: 11), reveal: false)
        s.stateA.select(s.offset(row: 21)..<s.offset(row: 21), reveal: false)
        s.stateB.select(s.offset(row: 31)..<s.offset(row: 31), reveal: false)
        for mode in [WorkspaceMode.chat, .code, .chat, .code] {
            s.rig.workspace.setMode(mode)
            await s.settle()
        }
        #expect(chat.primarySelection.head == s.offset(row: 11))
        #expect(s.stateA.primarySelection.head == s.offset(row: 21))
        #expect(s.stateB.primarySelection.head == s.offset(row: 31))
    }

    /// A jump into pane B moves B's drawn caret and scrolls B to the line, and leaves A alone.
    @Test func aJumpScrollsOnlyThatPanesView() async throws {
        let s = try await setup()
        let scrollA = s.viewA.scroll.position
        let headA = s.stateA.primarySelection
        await s.rig.workspace.open("big.swift", revealLine: 300, in: s.b)
        // Frame-bounded wait (no wall clock): tick until the reveal scrolls pane B, up to a frame cap. The pane's
        // view is looked up afresh each frame: a view the store rebuilt would leave a handle taken earlier stale.
        var gid = ""; if case .group(let g) = s.b { gid = g.uuidString }
        func liveB() -> OpenDocumentView? { CodePanelStore.existingView(for: s.doc, in: s.b) }
        var frames = 0
        while (liveB()?.scroll.position.row ?? 0) <= 250 && frames < 600 { await s.settle(1); frames += 1 }
        let row = liveB()?.scroll.position.row ?? -1
        #expect(row > 250, "pane B scrolled to row \(row) after \(frames) frames; same view as setup: \(liveB() === s.viewB), setup view row \(s.viewB.scroll.position.row), serial \(s.stateB.revealSerial); B frame \((try? s.window.element(identifier: "code-view-\(gid)").frame) as Any); window \(s.window.platformWindow)")
        #expect(s.stateB.primarySelection.range == s.doc.buffer.snapshot().lineRange(299))
        #expect(s.viewA.scroll.position == scrollA && s.stateA.primarySelection == headA)
    }

    /// Types `text` in the focused view of `pane` with the pane's caret at `at`, and returns the buffer text.
    private func type(_ s: Setup, in pane: PaneID, id: String, at: Int, _ text: String) async throws {
        guard case .group(let g) = pane else { return }
        _ = g
        try s.window.click(s.window.element(identifier: id))
        s.rig.workspace.selectionState(for: "big.swift", in: pane)!.select(at..<at, reveal: false)
        await s.settle(3)
        s.window.typeText(text)
        await s.settle(3)
    }

    /// The plain view runs on its pane's state: a caret set through the state is where typing lands. Without the
    /// `.selectionState` wiring the view types at the default state's caret, and this fails.
    @Test func typingLandsAtThePanesCaret() async throws {
        let s = try await setup()
        let at = s.offset(row: 12)
        guard case .group(let g) = s.b else { return }
        try await type(s, in: s.b, id: "code-view-\(g.uuidString)", at: at, "Q")
        #expect(s.doc.buffer.snapshot().utf8(in: at..<at + 1).elementsEqual(Array("Q".utf8)))
        #expect(s.stateB.primarySelection.head == at + 1)
    }

    /// The side-by-side right pane runs on the pane's state too.
    @Test func typingInTheSideBySideRightPaneLandsAtThePanesCaret() async throws {
        let s = try await setup()
        s.rig.workspace.setPresentation(.sideBySide, of: "big.swift", in: s.b)
        guard case .group(let g) = s.b else { return }
        try await s.window.runUntil { (try? s.window.element(identifier: "sbs-right-\(g)")) != nil }
        let at = s.offset(row: 15)
        try await type(s, in: s.b, id: "sbs-right-\(g.uuidString)", at: at, "Q")
        #expect(s.doc.buffer.snapshot().utf8(in: at..<at + 1).elementsEqual(Array("Q".utf8)))
        #expect(s.stateB.primarySelection.head == at + 1)
    }

    /// A pane's state replaced under its live view (the file closed and reopened in one frame, or a layout restore):
    /// the view follows the new state, so a jump afterwards is where typing lands.
    @Test func aReplacedStateRewiresTheView() async throws {
        let s = try await setup()
        guard case .group(let g) = s.b else { return }
        try "other\n".write(to: s.rig.root.appendingPathComponent("other.swift"), atomically: true, encoding: .utf8)
        await s.rig.workspace.open("other.swift", in: s.b)
        await s.rig.workspace.open("big.swift", in: s.b)
        await s.settle()
        let old = s.stateB
        // Another pane keeps the document while this pane's state is replaced under its live view (as a layout
        // restore does), and something the pane's views observe changes in the same frame.
        s.rig.workspace.dropSelectionState("big.swift", from: s.b)
        _ = s.rig.workspace.selectionState(for: "big.swift", in: s.b)
        s.rig.workspace.setPresentation(.inline, of: "big.swift", in: s.b)
        s.rig.workspace.setPresentation(.plain, of: "big.swift", in: s.b)
        #expect(s.stateB !== old, "the state was replaced")
        await s.rig.workspace.open("big.swift", revealLine: 40, in: s.b)
        await s.settle()
        try s.window.click(s.window.element(identifier: "code-view-\(g.uuidString)"))
        let at = s.offset(row: 40)
        s.stateB.select(at..<at, reveal: false)
        await s.settle(3)
        s.window.typeText("Q")
        await s.settle(3)
        #expect(s.doc.buffer.snapshot().utf8(in: at..<at + 1).elementsEqual(Array("Q".utf8)), "typing landed at the new state's caret")
    }
}
