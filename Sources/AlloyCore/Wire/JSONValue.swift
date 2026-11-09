import Foundation

/// A generic JSON tree. Decoding the wire through this means unknown fields never break a line.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // JSONDecoder is strict about scalar types, so the order only affects speed: strings are the commonest.
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if c.decodeNil() { self = .null }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Object member, or nil when this is not an object or the key is absent.
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        if case .number(let n) = self, n.isFinite, abs(n) < 9e15 { return Int(n) }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

extension JSONValue {
    /// Parses with `JSONSerialization`, several times faster than the `Codable` path on large inputs
    /// (history replay). Nil when `data` is not valid JSON.
    public static func parse(_ data: some DataProtocol) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: Data(data), options: [.fragmentsAllowed]) else { return nil }
        return convert(any)
    }

    /// `JSONSerialization` hands booleans back as `NSNumber`. Darwin tells them apart by CoreFoundation type; elsewhere
    /// (swift-corelibs-foundation has no `CFGetTypeID`) a boolean's Objective-C type encoding is `c`.
    private static func isBoolean(_ n: NSNumber) -> Bool {
        #if canImport(Darwin)
        CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        String(cString: n.objCType) == "c"
        #endif
    }

    private static func convert(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let n as NSNumber:
            if isBoolean(n) { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(convert))
        case let o as [String: Any]: return .object(o.mapValues(convert))
        default: return .null
        }
    }
}
