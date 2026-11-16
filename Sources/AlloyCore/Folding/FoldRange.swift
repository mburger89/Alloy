/// A foldable span in 0-based line numbers. Folding hides lines
/// `startLine + 1 ... endLine`; the start line stays visible. Valid iff
/// `endLine > startLine`.
public struct FoldRange: Sendable, Hashable, Comparable {
    public var startLine: Int
    public var endLine: Int

    public init(startLine: Int, endLine: Int) {
        self.startLine = startLine
        self.endLine = endLine
    }

    public static func < (a: FoldRange, b: FoldRange) -> Bool {
        a.startLine != b.startLine ? a.startLine < b.startLine : a.endLine < b.endLine
    }
}

/// Where a document's fold ranges come from, in increasing precedence.
public enum FoldSource: Int, Sendable, Comparable {
    case indentation = 0, treeSitter, lsp

    public static func < (a: FoldSource, b: FoldSource) -> Bool { a.rawValue < b.rawValue }
}
