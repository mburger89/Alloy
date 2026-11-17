import Foundation

/// One fold as saved: 0-based inclusive `[start, end]` lines. MetalUI's range for it is `start..<end + 1`.
public struct FoldLines: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) { self.start = start; self.end = end }

    public init(_ lines: Range<Int>) { self.init(start: lines.lowerBound, end: lines.upperBound - 1) }

    public var lines: Range<Int> { start..<end + 1 }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let start = try c.decode(Int.self)
        let end = try c.decode(Int.self)
        guard c.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "A fold is exactly [start, end]")
        }
        guard start >= 0, start < end else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "A fold needs 0 <= start < end")
        }
        self.start = start; self.end = end
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(start)
        try c.encode(end)
    }
}
