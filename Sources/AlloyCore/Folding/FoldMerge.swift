/// The single source chosen for a document and its ranges.
public struct FoldChoice: Sendable, Equatable {
    public var source: FoldSource
    public var ranges: [FoldRange]

    public init(source: FoldSource, ranges: [FoldRange]) {
        self.source = source
        self.ranges = ranges
    }
}

public enum FoldMerge {
    /// One source per document, never merged: LSP over tree-sitter over
    /// indentation. A source that answered, even with an empty list, wins;
    /// `nil` means "not available".
    public static func choose(
        lsp: [FoldRange]?, treeSitter: [FoldRange]?, indentation: [FoldRange]
    ) -> FoldChoice {
        if let lsp { return FoldChoice(source: .lsp, ranges: lsp) }
        if let treeSitter { return FoldChoice(source: .treeSitter, ranges: treeSitter) }
        return FoldChoice(source: .indentation, ranges: indentation)
    }

    /// Drops invalid ranges, clamps `endLine` to the last line (dropping
    /// ranges that collapse), keeps the largest end per start line, sorted.
    public static func normalized(_ ranges: [FoldRange], lineCount: Int) -> [FoldRange] {
        guard lineCount > 1 else { return [] }
        var best: [Int: Int] = [:]
        for r in ranges where r.startLine >= 0 && r.endLine > r.startLine {
            let end = min(r.endLine, lineCount - 1)
            guard end > r.startLine else { continue }
            if let e = best[r.startLine], e >= end { continue }
            best[r.startLine] = end
        }
        return best.map { FoldRange(startLine: $0.key, endLine: $0.value) }.sorted()
    }
}
