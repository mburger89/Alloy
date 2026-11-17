import Foundation
import Testing
@testable import AlloyCore

@Suite struct TerminalSplitTreeTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test func splitThenRemoveRestoresTree() {
        let t = TerminalSplitTree.pane(a).splitting(a, axis: .horizontal, newPane: b, newSplit: UUID())
        #expect(t.paneIDs == [a, b])
        let r = t.removing(b)
        #expect(r?.tree == .pane(a))
        #expect(r?.focus == a)
    }

    @Test func removingFirstFocusesSiblingFirstLeaf() {
        let t = TerminalSplitTree.pane(a).splitting(a, axis: .vertical, newPane: b, newSplit: UUID())
        #expect(t.removing(a)?.focus == b)
    }

    @Test func removingOnlyPaneIsNil() {
        #expect(TerminalSplitTree.pane(a).removing(a) == nil)
    }

    @Test func neighbourFindsRightSibling() {
        let t = TerminalSplitTree.pane(a).splitting(a, axis: .horizontal, newPane: b, newSplit: UUID())
        #expect(t.neighbour(of: a, .right) == b)
        #expect(t.neighbour(of: a, .left) == nil)
        #expect(t.neighbour(of: b, .left) == a)
    }

    @Test func prunedDropsMissingLeaves() {
        let t = TerminalSplitTree.pane(a)
            .splitting(a, axis: .horizontal, newPane: b, newSplit: UUID())
            .splitting(b, axis: .vertical, newPane: c, newSplit: UUID())
        #expect(t.pruned(keeping: [a, c])?.paneIDs == [a, c])
        #expect(t.pruned(keeping: [c]) == .pane(c))
        #expect(t.pruned(keeping: []) == nil)
    }

    @Test func codableRoundTrip() throws {
        let t = TerminalSplitTree.pane(a).splitting(a, axis: .vertical, newPane: b, newSplit: UUID())
        let back = try JSONDecoder().decode(TerminalSplitTree.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }
}
