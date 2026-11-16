import AlloyCore
import Testing

private func r(_ s: Int, _ e: Int) -> FoldRange { FoldRange(startLine: s, endLine: e) }

@Suite struct FoldMergeTests {
    @Test func lspWinsWhenPresentEvenIfEmpty() {
        let c = FoldMerge.choose(lsp: [], treeSitter: [r(1, 4)], indentation: [r(1, 3)])
        #expect(c == FoldChoice(source: .lsp, ranges: []))
    }

    @Test func treeSitterWinsOverIndentation() {
        let c = FoldMerge.choose(lsp: nil, treeSitter: [r(1, 4)], indentation: [r(1, 3)])
        #expect(c == FoldChoice(source: .treeSitter, ranges: [r(1, 4)]))
    }

    @Test func indentationIsTheFallback() {
        let c = FoldMerge.choose(lsp: nil, treeSitter: nil, indentation: [r(1, 3)])
        #expect(c == FoldChoice(source: .indentation, ranges: [r(1, 3)]))
    }

    @Test func lspReplacesTreeSitterWhenItArrivesLater() {
        let before = FoldMerge.choose(lsp: nil, treeSitter: [r(1, 4)], indentation: [])
        let after = FoldMerge.choose(lsp: [r(2, 6)], treeSitter: [r(1, 4)], indentation: [])
        #expect(before.source == .treeSitter)
        #expect(after.source == .lsp)
        #expect(after.ranges == [r(2, 6)])
        #expect(FoldSource.indentation < .treeSitter && .treeSitter < .lsp)
    }

    @Test func normalizedDropsInvalidClampsAndDedupes() {
        let input = [r(3, 3), r(5, 2), r(-1, 4), r(2, 99), r(2, 6), r(0, 1)]
        #expect(FoldMerge.normalized(input, lineCount: 10) == [r(0, 1), r(2, 9)])
    }

    @Test func normalizedOfEmptyDocument() {
        #expect(FoldMerge.normalized([r(0, 3)], lineCount: 0).isEmpty)
        #expect(FoldMerge.normalized([r(0, 3)], lineCount: 1).isEmpty)
    }
}
