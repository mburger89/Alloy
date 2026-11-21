public enum CSVEncoder {
    /// Encodes a cell value as field bytes. Quotes when the value contains the delimiter, a quote, CR or LF, has leading
    /// or trailing spaces, or when the field was quoted before (to keep the original style). Doubles inner quotes.
    public static func encode(_ value: String, delimiter: UInt8, wasQuoted: Bool) -> [UInt8] {
        let bytes = Array(value.utf8)
        let q = UInt8(ascii: "\"")
        let space = UInt8(ascii: " ")
        let needs = wasQuoted
            || bytes.first == space || bytes.last == space
            || bytes.contains { $0 == delimiter || $0 == q || $0 == 0x0A || $0 == 0x0D }
        guard needs else { return bytes }
        var out: [UInt8] = [q]
        out.reserveCapacity(bytes.count + 2)
        for b in bytes { out.append(b); if b == q { out.append(q) } }
        out.append(q)
        return out
    }
}
