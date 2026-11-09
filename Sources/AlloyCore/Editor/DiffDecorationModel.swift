import Foundation

/// The inline diff of one file as plain values: gutter bars for added lines, groups of removed lines anchored in
/// front of a buffer row, and sub-line author runs where two authors wrote one line. The code panel turns these
/// into `CodeDecorations`; nothing here touches a view, so it can be built and tested anywhere.
///
/// Rows are 0-based rows of the current text. Offsets are UTF-8 bytes, summed from `String.utf8.count`.
public struct DiffDecorationModel: Equatable, Sendable {
    /// Consecutive added rows of one edit.
    public struct LineBar: Equatable, Sendable {
        public var rows: Range<Int>
        public var author: Author
        public var edit: UUID
    }

    /// Consecutive removed lines of one edit, shown in front of buffer row `beforeRow`. `beforeRow` equal to the
    /// number of lines of the current text means after the last line.
    public struct RemovedGroup: Equatable, Sendable {
        public var beforeRow: Int
        public var lines: [String]
        public var edit: UUID
        public var author: Author
    }

    /// Text one author wrote on a line that more than one author wrote on.
    public struct AuthorRun: Equatable, Sendable {
        public var byteRange: Range<Int>
        public var author: Author
    }

    public var lineBars: [LineBar] = []
    public var removedGroups: [RemovedGroup] = []
    public var authorRuns: [AuthorRun] = []
    /// A decoration tag (the key the view reports back on a click) to the edit it stands for.
    public var tags: [UInt64: UUID] = [:]
    /// The tag of each edit, in order of first appearance, starting at 1.
    public var tagOf: [UUID: UInt64] = [:]

    public init() {}

    /// `terminators` gives each line's own terminator length in bytes (`FileLedger.diffEntries()`), so a file with
    /// mixed line endings keeps exact offsets; without it every line ends in `lineEnding` (`"\n"` or `"\r\n"`).
    public static func build(_ lines: [DiffLine], terminators: [Int]? = nil, authorOf: (UUID) -> Author,
                             lineEnding: String) -> DiffDecorationModel {
        var model = DiffDecorationModel()
        let fallbackTerminator = lineEnding.utf8.count
        var row = 0
        var offset = 0
        var authors: [UUID: Author] = [:]
        func author(_ edit: UUID) -> Author {
            if let a = authors[edit] { return a }
            let a = authorOf(edit)
            authors[edit] = a
            if model.tagOf[edit] == nil {
                let tag = UInt64(model.tagOf.count + 1)
                model.tagOf[edit] = tag
                model.tags[tag] = edit
            }
            return a
        }
        for (index, line) in lines.enumerated() {
            let terminator = terminators.map { index < $0.count ? $0[index] : fallbackTerminator } ?? fallbackTerminator
            switch line {
            case .context(let text, _):
                row += 1
                offset += text.utf8.count + terminator
            case .added(let text, _, let edit, let runs):
                let who = author(edit)
                if let last = model.lineBars.last, last.edit == edit, last.rows.upperBound == row {
                    model.lineBars[model.lineBars.count - 1].rows = last.rows.lowerBound..<(row + 1)
                } else {
                    model.lineBars.append(LineBar(rows: row..<(row + 1), author: who, edit: edit))
                }
                var cursor = offset
                var seen: [(Range<Int>, Author)] = []
                for run in runs {
                    let length = run.text.utf8.count
                    if let e = run.edit, length > 0 { seen.append((cursor..<(cursor + length), author(e))) }
                    cursor += length
                }
                if Set(seen.map(\.1)).count > 1 {
                    model.authorRuns.append(contentsOf: seen.map { AuthorRun(byteRange: $0.0, author: $0.1) })
                }
                row += 1
                offset += text.utf8.count + terminator
            case .removed(let text, let edit):
                let who = author(edit)
                if let last = model.removedGroups.last, last.edit == edit, last.beforeRow == row {
                    model.removedGroups[model.removedGroups.count - 1].lines.append(text)
                } else {
                    model.removedGroups.append(RemovedGroup(beforeRow: row, lines: [text], edit: edit, author: who))
                }
            }
        }
        return model
    }
}
