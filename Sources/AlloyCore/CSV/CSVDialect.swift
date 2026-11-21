/// The delimiter and quoting convention of one CSV or TSV document. Quote is always `"`.
public struct CSVDialect: Equatable, Sendable {
    public var delimiter: UInt8

    public init(delimiter: UInt8 = UInt8(ascii: ",")) { self.delimiter = delimiter }

    public static let comma = CSVDialect(delimiter: UInt8(ascii: ","))
    public static let tab = CSVDialect(delimiter: UInt8(ascii: "\t"))
    public static let semicolon = CSVDialect(delimiter: UInt8(ascii: ";"))

    /// `tsv` is always tab. `csv` is comma unless the first logical row has more `;` than `,` outside quotes.
    /// A leading UTF-8 BOM in `firstRow` is ignored. Anything else falls back to comma.
    public static func detect(language: String?, firstRow: [UInt8]) -> CSVDialect {
        if language == "tsv" { return .tab }
        var bytes = firstRow[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), semi = UInt8(ascii: ";")
        var commas = 0, semis = 0
        var i = bytes.startIndex
        var atFieldStart = true
        scan: while i < bytes.endIndex {
            let b = bytes[i]
            if atFieldStart && b == quote {
                // Skip a well-formed quoted field; an unclosed quote is a literal (lenient rule).
                var j = i + 1
                var closed: Int?
                while j < bytes.endIndex {
                    if bytes[j] == quote {
                        if j + 1 < bytes.endIndex && bytes[j + 1] == quote { j += 2; continue }
                        closed = j
                        break
                    }
                    j += 1
                }
                if let c = closed { i = c + 1; atFieldStart = false; continue scan }
            }
            if b == 0x0A || b == 0x0D { break }
            if b == comma { commas += 1 }
            if b == semi { semis += 1 }
            atFieldStart = b == comma || b == semi
            i += 1
        }
        return semis > commas ? .semicolon : .comma
    }
}
