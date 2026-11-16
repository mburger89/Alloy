import Foundation
import Testing
@testable import AlloyCore

@Suite struct SplitTreeTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let s1 = UUID(), s2 = UUID(), s3 = UUID()

    func h(_ id: UUID, _ x: SplitTree, _ y: SplitTree) -> SplitTree { .split(id: id, axis: .horizontal, first: x, second: y) }
    func v(_ id: UUID, _ x: SplitTree, _ y: SplitTree) -> SplitTree { .split(id: id, axis: .vertical, first: x, second: y) }

    @Test func splitRightPutsNewGroupSecond() {
        let t = SplitTree.group(a).splitting(a, axis: .horizontal, newGroup: b, newSplit: s1)
        #expect(t == h(s1, .group(a), .group(b)))
    }

    @Test func splitNestsInPlace() {
        let t = SplitTree.group(a)
            .splitting(a, axis: .horizontal, newGroup: b, newSplit: s1)
            .splitting(b, axis: .vertical, newGroup: c, newSplit: s2)
        #expect(t == h(s1, .group(a), v(s2, .group(b), .group(c))))
    }

    @Test func removingCollapsesTheParent() {
        let r = h(s1, .group(a), .group(b)).removing(b)
        #expect(r?.tree == .group(a))
        #expect(r?.focus == a)
    }

    @Test func removingFocusesTheAdjacentLeaf() {
        let t = h(s1, .group(a), v(s2, .group(b), .group(c)))
        let r1 = t.removing(a)
        #expect(r1?.tree == v(s2, .group(b), .group(c)))
        #expect(r1?.focus == b)
        let r2 = t.removing(c)
        #expect(r2?.tree == h(s1, .group(a), .group(b)))
        #expect(r2?.focus == b)
    }

    @Test func theOnlyGroupCannotBeRemoved() {
        #expect(SplitTree.group(a).removing(a) == nil)
    }

    @Test func neighbourAcrossNesting() {
        let t = h(s1, .group(a), v(s2, .group(b), .group(c)))
        #expect(t.neighbour(of: a, .right) == b)
        #expect(t.neighbour(of: b, .down) == c)
        #expect(t.neighbour(of: c, .left) == a)
        #expect(t.neighbour(of: a, .up) == nil)
    }

    @Test func neighbourPrefersLargerOverlap() {
        let t = v(s1, h(s2, .group(a), h(s3, .group(b), .group(c))), .group(d))
        #expect(t.neighbour(of: d, .up) == a)
    }

    @Test func groupIDsInTreeOrder() {
        let t = h(s1, .group(a), v(s2, .group(b), .group(c)))
        #expect(t.groupIDs == [a, b, c])
        #expect(t.splitIDs == [s1, s2])
    }

    @Test func prunedDropsMissingGroups() {
        let t = h(s1, .group(a), v(s2, .group(b), .group(c)))
        #expect(t.pruned(keeping: [a, c]) == h(s1, .group(a), .group(c)))
        #expect(t.pruned(keeping: []) == nil)
    }

    @Test func codableRoundTrip() throws {
        let t = h(s1, .group(a), v(s2, .group(b), .group(c)))
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(SplitTree.self, from: data) == t)
    }
}
