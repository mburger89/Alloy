import MetalUICodeBuffer

/// How far a quoted field may look for its closing quote before the opening quote is treated as a literal.
public struct CSVLookahead: Sendable {
    public var maxBytes = 1 << 20
    public var maxLines = 10_000
    public init(maxBytes: Int = 1 << 20, maxLines: Int = 10_000) {
        self.maxBytes = maxBytes
        self.maxLines = maxLines
    }
}

/// One parsed row. Field ranges are relative to the row start and include quotes; the terminator is not part of any field.
public struct CSVRowParse: Equatable, Sendable {
    public var fields: [Range<Int>]
    public var quoted: [Bool]
    public var terminatorLength: Int
    public var flagged: Bool
}

/// Random-access UTF-8 bytes (a `CodeSnapshot`, or an array in tests).
public protocol CSVBytes: Sendable {
    var utf8Count: Int { get }
    func utf8(in: Range<Int>) -> [UInt8]
}

extension CodeSnapshot: CSVBytes {}
extension Array: CSVBytes where Element == UInt8 {
    public var utf8Count: Int { count }
    public func utf8(in range: Range<Int>) -> [UInt8] { Array(self[range]) }
}

/// Byte access for the scanner: direct for arrays, chunked (64 KB) for snapshots.
protocol CSVByteReader {
    var count: Int { get }
    mutating func byte(_ i: Int) -> UInt8
}

struct CSVArrayReader: CSVByteReader {
    let bytes: [UInt8]
    var count: Int { bytes.count }
    @inline(__always) mutating func byte(_ i: Int) -> UInt8 { bytes[i] }
}

struct CSVChunkReader<S: CSVBytes>: CSVByteReader {
    let source: S
    let count: Int
    private var base = 0
    private var chunk: [UInt8] = []
    static var chunkSize: Int { 64 * 1024 }
    init(_ source: S) { self.source = source; self.count = source.utf8Count }
    @inline(__always) mutating func byte(_ i: Int) -> UInt8 {
        if i < base || i >= base + chunk.count {
            base = i / Self.chunkSize * Self.chunkSize
            chunk = source.utf8(in: base..<min(count, base + Self.chunkSize))
        }
        return chunk[i - base]
    }
}

public enum CSVParser {
    static let quote = UInt8(ascii: "\"")
    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D

    /// The one quote state machine. Scans a row starting at `start`; when `collect` is set also records fields.
    static func scanRow<R: CSVByteReader>(_ r: inout R, start: Int, dialect: CSVDialect, lookahead: CSVLookahead,
                                          collect: Bool) -> (end: Int, parse: CSVRowParse) {
        let n = r.count
        var pos = start
        var fields: [Range<Int>] = []
        var quoted: [Bool] = []
        var flagged = false
        var terminator = 0
        while true {
            let fieldStart = pos
            var fieldEnd = pos
            var isQuoted = false
            var literalFrom = pos
            if pos < n, r.byte(pos) == quote {
                // Look for a closing quote followed by delimiter, terminator or EOF, within the lookahead bounds.
                var j = pos + 1
                var lines = 0
                var stray = false
                var closeAt: Int?
                let limit = min(n, pos + lookahead.maxBytes)
                while j < limit {
                    let b = r.byte(j)
                    if b == quote {
                        if j + 1 < n, r.byte(j + 1) == quote { j += 2; continue }
                        if j + 1 == n { closeAt = j; break }
                        let nb = r.byte(j + 1)
                        if nb == dialect.delimiter || nb == lf || nb == cr { closeAt = j; break }
                        stray = true   // quote followed by something else: literal inside the field
                    } else if b == lf {
                        lines += 1
                        if lines > lookahead.maxLines { break }
                    }
                    j += 1
                }
                if let c = closeAt {
                    isQuoted = true
                    fieldEnd = c + 1
                    pos = fieldEnd
                    if stray { flagged = true }
                } else {
                    flagged = true   // fallback: the opening quote is a literal
                    literalFrom = pos + 1
                }
            }
            if !isQuoted {
                pos = literalFrom
                while pos < n {
                    let b = r.byte(pos)
                    if b == dialect.delimiter || b == lf || b == cr { break }
                    pos += 1
                }
                fieldEnd = pos
            }
            if collect { fields.append(fieldStart..<fieldEnd); quoted.append(isQuoted) }
            if pos >= n { terminator = 0; break }
            let b = r.byte(pos)
            if b == dialect.delimiter { pos += 1; continue }
            // After a closed quoted field only a delimiter or terminator can follow, so this is a terminator.
            if b == cr, pos + 1 < n, r.byte(pos + 1) == lf { terminator = 2 } else { terminator = 1 }
            pos += terminator
            break
        }
        let parse = CSVRowParse(fields: fields.map { ($0.lowerBound - start)..<($0.upperBound - start) }, quoted: quoted,
                                terminatorLength: terminator, flagged: flagged)
        return (pos, parse)
    }

    /// Parses one row (`bytes` is exactly the row, including its terminator if any).
    public static func parseRow(_ bytes: [UInt8], dialect: CSVDialect, lookahead: CSVLookahead = CSVLookahead()) -> CSVRowParse {
        var r = CSVArrayReader(bytes: bytes)
        return scanRow(&r, start: 0, dialect: dialect, lookahead: lookahead, collect: true).parse
    }

    /// The unquoted, un-doubled value of a field.
    public static func value(of field: ArraySlice<UInt8>, quoted: Bool) -> String {
        guard quoted, field.count >= 2, field.first == quote, field.last == quote else {
            return String(decoding: field, as: UTF8.self)
        }
        let inner = field.dropFirst().dropLast()
        var out: [UInt8] = []
        out.reserveCapacity(inner.count)
        var i = inner.startIndex
        while i < inner.endIndex {
            out.append(inner[i])
            if inner[i] == quote, i + 1 < inner.endIndex, inner[i + 1] == quote { i += 1 }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The cell display form: the first line only, plus a trailing return glyph when the value has CR or LF.
    public static func displayValue(of field: ArraySlice<UInt8>, quoted: Bool) -> String {
        let v = value(of: field, quoted: quoted)
        guard let cut = v.utf8.firstIndex(where: { $0 == lf || $0 == cr }) else { return v }
        return String(v[v.startIndex..<cut]) + "\u{23CE}"
    }
}

public enum CSVRowScanner {
    /// The offset after the row that starts at `from` (after its terminator), reading in 64 KB chunks.
    public static func nextRow(in source: some CSVBytes, from: Int, dialect: CSVDialect,
                               lookahead: CSVLookahead = CSVLookahead()) -> (end: Int, flagged: Bool) {
        var r = CSVChunkReader(source)
        let result = CSVParser.scanRow(&r, start: from, dialect: dialect, lookahead: lookahead, collect: false)
        return (result.end, result.parse.flagged)
    }
}
