import AlloyLSP
import Foundation
import MetalUICodeBuffer

/// What accepting a completion item does to the buffer, in the coordinates of the text as it is now.
struct CompletionPlan: Equatable {
    /// The main edit first, then the item's `additionalTextEdits` that do not overlap it.
    var edits: [ByteEdit]
    /// Where the caret goes once every edit is applied.
    var caret: Int
    /// The parsed snippet when the main edit inserts one as a session; nil for plain items and for the plain-text fallback.
    /// `edits[0].text` is then the snippet's resolved text and `caret` the plain-text landing place (its `$0`).
    var snippet: CodeSnippet?
}

enum CompletionApply {
    /// The edits for accepting `item`, which was requested at `requestCaret` of `requestSnapshot`, now that the buffer is
    /// `current` with the caret at `caret` (the user may have typed or erased more of the word since). The main edit is the
    /// item's `textEdit` insert range, extended or shortened by what was typed since, when that range lies on the request's
    /// caret line and contains the caret; otherwise it replaces `wordStart..<caret` with `insertText ?? label`. A snippet
    /// becomes plain text and the caret goes to its `$0`, unless `allowsSnippet` and the item is a snippet: then `snippet` carries the parsed
    /// `CodeSnippet` too. Additional edits overlapping the main edit are dropped.
    static func plan(item: CompletionItem, requestSnapshot: CodeSnapshot, current: CodeSnapshot, requestCaret: Int,
                     caret: Int, wordStart: Int, allowsSnippet: Bool = true) -> CompletionPlan? {
        let count = current.utf8Count
        guard caret >= 0, caret <= count, wordStart >= 0, wordStart <= caret, requestCaret >= 0,
              requestCaret <= requestSnapshot.utf8Count else { return nil }
        let delta = caret - requestCaret
        var range = wordStart..<caret
        var source = item.insertText ?? item.label
        if let edit = item.edit, edit.insert.lowerBound <= requestCaret, requestCaret <= edit.insert.upperBound,
           edit.insert.upperBound <= requestSnapshot.utf8Count,
           requestSnapshot.point(at: edit.insert.lowerBound).row == requestSnapshot.point(at: requestCaret).row,
           requestSnapshot.point(at: edit.insert.upperBound).row == requestSnapshot.point(at: requestCaret).row {
            let lower = edit.insert.lowerBound, upper = edit.insert.upperBound + delta
            if upper >= lower, upper <= count, lower <= caret, caret <= upper {
                range = lower..<upper
                source = edit.newText
            }
        }
        var text = source
        var snippetCaret: Int?
        var snippet: CodeSnippet?
        if item.isSnippet {
            let parsed = CodeSnippet(parsing: source)
            if allowsSnippet {   // the parse never fails: malformed syntax stays literal text
                snippet = parsed
                text = parsed.text
                snippetCaret = parsed.tabStops.first { $0.index == 0 }?.range.lowerBound ?? parsed.text.utf8.count
            } else {
                (text, snippetCaret) = SnippetText.plain(source)
            }
        }
        var extra: [ByteEdit] = []
        for edit in item.additionalEdits {
            // In the request's coordinates: what lies after the request caret moved by what was typed since.
            func move(_ o: Int) -> Int { o >= requestCaret ? o + delta : o }
            guard edit.range.upperBound >= edit.range.lowerBound else { continue }
            let lower = move(edit.range.lowerBound), upper = move(edit.range.upperBound)
            guard lower >= 0, upper >= lower, upper <= count, !overlaps(lower..<upper, range) else { continue }
            let moved = lower..<upper
            extra.append(ByteEdit(range: moved, text: edit.text))
        }
        extra.sort { $0.range.lowerBound < $1.range.lowerBound }
        // Two additional edits that touch each other cannot both be applied: keep the first.
        var kept: [ByteEdit] = []
        for edit in extra where !kept.contains(where: { overlaps($0.range, edit.range) }) { kept.append(edit) }
        // The caret: the main edit's start plus the snippet's `$0` (else the end of its text), moved by the edits before it.
        let inside = snippetCaret ?? text.utf8.count
        var landed = range.lowerBound + inside
        for edit in kept where edit.range.upperBound <= range.lowerBound {
            landed += edit.text.utf8.count - edit.range.count
        }
        return CompletionPlan(edits: [ByteEdit(range: range, text: text)] + kept, caret: landed, snippet: snippet)
    }

    /// Whether two edit ranges touch or intersect (an insertion at the edge of another range counts).
    static func overlaps(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        if a.isEmpty || b.isEmpty { return a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound }
        return a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }
}
