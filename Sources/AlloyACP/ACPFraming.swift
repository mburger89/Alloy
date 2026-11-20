import Foundation

/// Splits a byte stream into newline-delimited messages. Unbounded (agents send multi-megabyte lines), so a line
/// is only ever copied once, when it completes. Blank lines are dropped; a trailing carriage return is trimmed.
public struct ACPLineReader: Sendable {
    private var buffer = Data()
    /// Bytes at the front of `buffer` already scanned and known to hold no newline.
    private var scanned = 0

    public init() {}

    /// Appends `data` and returns every complete line now available, in order.
    public mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        var start = buffer.startIndex
        var from = buffer.startIndex + scanned
        while let nl = buffer[from...].firstIndex(of: 0x0A) {
            var end = nl
            if end > start, buffer[end - 1] == 0x0D { end -= 1 }
            if end > start { lines.append(Data(buffer[start..<end])) }
            start = nl + 1
            from = start
        }
        if start > buffer.startIndex {
            buffer = Data(buffer[start...])
            scanned = 0
        } else {
            scanned = buffer.count
        }
        return lines
    }

    /// The unterminated bytes still held (a final line without a newline at EOF).
    public mutating func finish() -> Data? {
        defer { buffer = Data(); scanned = 0 }
        var rest = buffer
        if rest.last == 0x0D { rest.removeLast() }
        return rest.isEmpty ? nil : rest
    }
}

public enum ACPFraming {
    /// One JSON message plus the terminating newline.
    public static func encode(_ body: Data) -> Data {
        var out = body
        out.append(0x0A)
        return out
    }
}
