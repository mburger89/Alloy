import Foundation

public enum LSPFramingError: Error, Equatable {
    case badHeader
    /// The header block exceeded `LSPFrameDecoder.maxHeaderBytes`.
    case headerTooLarge
    /// `Content-Length` exceeded `LSPFrameDecoder.maxBodyBytes`.
    case bodyTooLarge
}

/// Splits a byte stream into `Content-Length` framed message bodies.
public struct LSPFrameDecoder: Sendable {
    public static let maxHeaderBytes = 8 * 1024
    public static let maxBodyBytes = 64 * 1024 * 1024
    private var buffer = Data()

    public init() {}

    /// Appends `data` and returns every complete body now available, in order.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var bodies: [Data] = []
        let separator = Data("\r\n\r\n".utf8)
        while true {
            guard let range = buffer.range(of: separator) else {
                if buffer.count > Self.maxHeaderBytes { buffer.removeAll(); throw LSPFramingError.headerTooLarge }
                return bodies
            }
            if range.lowerBound - buffer.startIndex > Self.maxHeaderBytes {
                buffer.removeAll()
                throw LSPFramingError.headerTooLarge
            }
            let header = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
            var length: Int?
            for line in header.split(separator: "\r\n", omittingEmptySubsequences: true) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                if line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    length = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                }
            }
            guard let length, length >= 0 else {
                buffer.removeAll()
                throw LSPFramingError.badHeader
            }
            if length > Self.maxBodyBytes {
                buffer.removeAll()
                throw LSPFramingError.bodyTooLarge
            }
            let bodyStart = range.upperBound
            guard buffer.endIndex - bodyStart >= length else { return bodies }
            bodies.append(Data(buffer[bodyStart..<(bodyStart + length)]))
            buffer = Data(buffer[(bodyStart + length)...])
        }
    }
}

public enum LSPFrame {
    /// `Content-Length: <utf8 byte count>\r\n\r\n<body>`.
    public static func encode(_ body: Data) -> Data {
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }
}
