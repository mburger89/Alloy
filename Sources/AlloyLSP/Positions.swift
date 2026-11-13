import Foundation
import MetalUICodeBuffer

public struct LSPPosition: Codable, Equatable, Sendable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public struct LSPRange: Codable, Equatable, Sendable {
    public var start: LSPPosition
    public var end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

/// Conversion between the buffer's UTF-8 byte offsets and LSP positions in the negotiated encoding.
/// A line's terminator (`\n`, and the `\r` of CRLF) is not addressable: positions clamp to the line content.
public enum Positions {
    public static func lspPosition(utf8Offset: Int, in snapshot: CodeSnapshot, encoding: PositionEncoding) -> LSPPosition {
        let clamped = max(0, min(utf8Offset, snapshot.utf8Count))
        let row = snapshot.point(at: clamped).row
        let line = snapshot.lineRange(row)
        let offset = max(line.lowerBound, min(clamped, line.upperBound))
        let character: Int
        switch encoding {
        case .utf8: character = offset - line.lowerBound
        case .utf16: character = snapshot.utf16Offset(ofUTF8: offset) - snapshot.utf16Offset(ofUTF8: line.lowerBound)
        case .utf32: character = snapshot.scalarOffset(ofUTF8: offset) - snapshot.scalarOffset(ofUTF8: line.lowerBound)
        }
        return LSPPosition(line: row, character: character)
    }

    /// A line past the last maps to the end of the text; a character past the line's content to the content end.
    public static func utf8Offset(of position: LSPPosition, in snapshot: CodeSnapshot, encoding: PositionEncoding) -> Int {
        guard position.line < snapshot.lineCount else { return snapshot.utf8Count }
        let line = snapshot.lineRange(max(0, position.line))
        let character = max(0, position.character)
        let offset: Int
        switch encoding {
        case .utf8:
            offset = line.lowerBound + character
        case .utf16:
            offset = snapshot.utf8Offset(ofUTF16: snapshot.utf16Offset(ofUTF8: line.lowerBound) + character)
        case .utf32:
            offset = snapshot.utf8Offset(ofScalar: snapshot.scalarOffset(ofUTF8: line.lowerBound) + character)
        }
        return min(offset, line.upperBound)
    }

    public static func utf8Range(of range: LSPRange, in snapshot: CodeSnapshot, encoding: PositionEncoding) -> Range<Int> {
        let start = utf8Offset(of: range.start, in: snapshot, encoding: encoding)
        let end = utf8Offset(of: range.end, in: snapshot, encoding: encoding)
        return start..<max(start, end)
    }

    /// The character count of `prefix` (the bytes of a line before a position) in `encoding`.
    static func character(ofLinePrefix prefix: ArraySlice<UInt8>, encoding: PositionEncoding) -> Int {
        switch encoding {
        case .utf8: return prefix.count
        case .utf16:
            var n = 0
            for byte in prefix where byte & 0xC0 != 0x80 { n += byte >= 0xF0 ? 2 : 1 }
            return n
        case .utf32:
            return prefix.reduce(0) { $0 + ($1 & 0xC0 != 0x80 ? 1 : 0) }
        }
    }
}
