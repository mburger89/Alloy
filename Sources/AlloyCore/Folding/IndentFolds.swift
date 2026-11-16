import MetalUICodeBuffer

/// Fold ranges derived from indentation. Keeps an indent-per-line cache so a
/// rebuild measures only dirty lines, then runs one integer stack pass.
public struct IndentFolds: Sendable {
    static let blank: Int16 = -1
    static let dirty: Int16 = .min

    public let tabWidth: Int
    var cache: [Int16]
    /// Cumulative lines measured; test observability.
    private(set) var measuredLineCount = 0

    public init(snapshot: CodeSnapshot, tabWidth: Int = 4) {
        self.tabWidth = max(1, tabWidth)
        self.cache = [Int16](repeating: Self.dirty, count: snapshot.lineCount)
    }

    /// Splices the cache for edits in the order the buffer emitted them: the old
    /// rows of each edit become dirty rows for the new text. An edit whose rows
    /// do not fit the cache invalidates it; `ranges(in:)` then re-measures fully.
    public mutating func apply(_ edits: [CodeEdit]) {
        for edit in edits {
            let start = edit.startPoint.row
            let oldEnd = edit.oldEndPoint.row
            let newEnd = edit.newEndPoint.row
            guard start >= 0, start <= oldEnd, oldEnd < cache.count, newEnd >= start else {
                cache = []
                return
            }
            cache.replaceSubrange(start...oldEnd, with: repeatElement(Self.dirty, count: newEnd - start + 1))
        }
    }

    /// Forgets everything measured; the next `ranges(in:)` measures every line.
    public mutating func reset(to snapshot: CodeSnapshot) {
        cache = [Int16](repeating: Self.dirty, count: snapshot.lineCount)
    }

    public mutating func ranges(in snapshot: CodeSnapshot) -> [FoldRange] {
        let n = snapshot.lineCount
        if cache.count != n { cache = [Int16](repeating: Self.dirty, count: n) }
        for row in 0..<n where cache[row] == Self.dirty {
            cache[row] = measure(row, in: snapshot)
            measuredLineCount += 1
        }
        var out: [FoldRange] = []
        var stack: [(line: Int, indent: Int)] = []
        var lastNonBlank = -1
        for row in 0..<n {
            let v = cache[row]
            if v == Self.blank { continue }
            let d = Int(v)
            while let top = stack.last, top.indent >= d {
                if lastNonBlank > top.line { out.append(FoldRange(startLine: top.line, endLine: lastNonBlank)) }
                stack.removeLast()
            }
            stack.append((row, d))
            lastNonBlank = row
        }
        while let top = stack.popLast() {
            if lastNonBlank > top.line { out.append(FoldRange(startLine: top.line, endLine: lastNonBlank)) }
        }
        return FoldMerge.normalized(out, lineCount: n)
    }

    private func measure(_ row: Int, in snapshot: CodeSnapshot) -> Int16 {
        let range = snapshot.lineRange(row)
        var width = 0
        var i = range.lowerBound
        while i < range.upperBound {
            let b = snapshot.byte(at: i)
            if b == 0x20 { width += 1 } else if b == 0x09 { width += tabWidth } else { break }
            if width >= Int(Int16.max) { width = Int(Int16.max); break }
            i += 1
        }
        // Blank when only whitespace (or a stray CR/LF) remains.
        if i >= range.upperBound { return Self.blank }
        let b = snapshot.byte(at: i)
        if b == 0x0A || b == 0x0D { return Self.blank }
        return Int16(width)
    }
}
