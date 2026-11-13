import AlloyCore
import AlloyHighlight
import Foundation
import MetalUICodeBuffer

/// Decoding of `textDocument/semanticTokens` data into highlight runs, and the request that fetches it.
public enum SemanticTokens {
    /// Decodes the relative 5-integer encoding (`deltaLine, deltaStart, length, type, modifiers`) into byte ranges of
    /// `snapshot` with their syntax kinds. Tokens of unknown or unmapped types, empty tokens and tokens past the text
    /// are skipped; one that runs past its line is cut at the line's content end. Pure, for a background executor: one
    /// line lookup per line, and in UTF-16/UTF-32 two rope conversions per token (O(tokens log n)).
    public static func decode<Value: BinaryInteger>(_ data: [Value], legend: SemanticTokensLegend, snapshot: CodeSnapshot,
                              encoding: PositionEncoding) -> [(Range<Int>, SyntaxToken)] {
        // The kind of each legend type without modifiers, resolved once.
        let kinds = legend.tokenTypes.map(baseKind)
        let readonly = legend.tokenModifiers.firstIndex(of: "readonly")
        let library = legend.tokenModifiers.firstIndex(of: "defaultLibrary")
        var runs: [(Range<Int>, SyntaxToken)] = []
        runs.reserveCapacity(data.count / 5)

        var line = 0, character = 0
        var lineRange = 0..<0
        var lineBase = 0   // the line's start in `encoding` units (UTF-16 or scalars); unused for UTF-8
        var loadedLine = -1
        var i = 0
        while i + 4 < data.count {
            let deltaLine = Int(data[i]), deltaStart = Int(data[i + 1]), length = Int(data[i + 2])
            let type = Int(data[i + 3]), modifiers = Int(data[i + 4])
            i += 5
            if deltaLine > 0 { line += deltaLine; character = deltaStart } else { character += deltaStart }
            guard line >= 0, line < snapshot.lineCount else { break }
            guard length > 0, type >= 0, type < kinds.count, var kind = kinds[type] else { continue }
            if line != loadedLine {
                loadedLine = line
                lineRange = snapshot.lineRange(line)
                switch encoding {
                case .utf8: lineBase = 0
                case .utf16: lineBase = snapshot.utf16Offset(ofUTF8: lineRange.lowerBound)
                case .utf32: lineBase = snapshot.scalarOffset(ofUTF8: lineRange.lowerBound)
                }
            }
            func has(_ bit: Int?) -> Bool { bit.map { modifiers & (1 << $0) != 0 } ?? false }
            if kind == .variable, has(readonly) { kind = .constant }
            if has(library), kind == .function || kind == .type { kind = .builtin }

            let lower: Int, upper: Int
            switch encoding {
            case .utf8:
                lower = lineRange.lowerBound + character
                upper = lower + length
            case .utf16:
                lower = snapshot.utf8Offset(ofUTF16: lineBase + character)
                upper = snapshot.utf8Offset(ofUTF16: lineBase + character + length)
            case .utf32:
                lower = snapshot.utf8Offset(ofScalar: lineBase + character)
                upper = snapshot.utf8Offset(ofScalar: lineBase + character + length)
            }
            let clampedUpper = min(upper, lineRange.upperBound)
            guard lower < clampedUpper, lower >= lineRange.lowerBound else { continue }
            runs.append((lower..<clampedUpper, kind))
        }
        return runs
    }

    /// The kind of a legend type name, before modifiers; nil for names that colour nothing.
    static func baseKind(_ name: String) -> SyntaxToken? {
        switch name {
        case "keyword", "modifier": .keyword
        case "string", "regexp": .string
        case "comment": .comment
        case "number": .number
        case "type", "class", "struct", "enum", "interface", "typeParameter", "namespace": .type
        case "function", "method", "macro": .function
        case "variable", "parameter": .variable
        case "property", "event": .property
        case "enumMember": .constant
        case "operator": .operator_
        case "decorator": .attribute
        default: nil
        }
    }

    /// Applies `semanticTokens/full/delta` edits (`{start, deleteCount, data?}`, offsets into `previous`) and returns
    /// the new data; nil when an edit does not fit `previous`, or overlaps another (the caller asks for a full result).
    public static func applyDelta<Value: FixedWidthInteger>(_ previous: [Value], edits: [JSONValue]) -> [Value]? {
        var parsed: [(index: Int, start: Int, deleteCount: Int, data: [Value])] = []
        for edit in edits {
            guard let start = edit["start"]?.intValue, let deleteCount = edit["deleteCount"]?.intValue,
                  start >= 0, deleteCount >= 0, start + deleteCount <= previous.count else { return nil }
            var data: [Value] = []
            if let array = edit["data"]?.arrayValue {
                data.reserveCapacity(array.count)
                for value in array { guard let n = value.intValue, let v = Value(exactly: n) else { return nil }; data.append(v) }
            }
            parsed.append((parsed.count, start, deleteCount, data))
        }
        // Edits at one offset keep the server's order.
        parsed.sort { ($0.start, $0.index) < ($1.start, $1.index) }
        var result: [Value] = []
        var position = 0
        for edit in parsed {
            guard edit.start >= position else { return nil }
            result.append(contentsOf: previous[position..<edit.start])
            result.append(contentsOf: edit.data)
            position = edit.start + edit.deleteCount
        }
        result.append(contentsOf: previous[position...])
        return result
    }

    /// The integers of a result's `data` array (LSP `uinteger`s); nil when it is missing or malformed.
    static func integers(_ value: JSONValue?) -> [UInt32]? {
        guard let array = value?.arrayValue else { return nil }
        var out: [UInt32] = []
        out.reserveCapacity(array.count)
        for item in array { guard let n = item.intValue, let v = UInt32(exactly: n) else { return nil }; out.append(v) }
        return out
    }

    /// What a server's reply came to.
    struct Processed: Sendable {
        /// The full token data, kept only when `keepData` asked for it (it is the base of the next delta request).
        var data: [UInt32]?
        var resultID: String?
        var runs: [(Range<Int>, SyntaxToken)]
    }

    /// Turns a `full` or `full/delta` reply into runs. Meant to run off the manager's actor: it walks every token.
    /// Nil when the reply is malformed or a delta does not fit `previous`.
    static func process(_ reply: JSONValue, previous: [UInt32]?, legend: SemanticTokensLegend, snapshot: CodeSnapshot,
                        encoding: PositionEncoding, keepData: Bool) -> Processed? {
        let data: [UInt32]
        if let edits = reply["edits"]?.arrayValue {
            guard let previous, let merged = applyDelta(previous, edits: edits) else { return nil }
            data = merged
        } else {
            guard let full = integers(reply["data"]) else { return nil }
            data = full
        }
        let resultID = reply["resultId"]?.stringValue
        let runs = decode(data, legend: legend, snapshot: snapshot, encoding: encoding)
        return Processed(data: keepData && resultID != nil ? data : nil, resultID: resultID, runs: runs)
    }
}

/// The last token data of a document and the id the server gave it: the base of the next delta request.
struct SemanticBase: Sendable {
    var resultID: String
    var data: [UInt32]
}

