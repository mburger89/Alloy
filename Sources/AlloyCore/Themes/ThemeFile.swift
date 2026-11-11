import Foundation

public enum ThemeAppearance: String, Sendable {
    case dark, light
}

public enum ThemeFileError: Error, Equatable, Sendable {
    case notJSON
    case missingName
    case badAppearance(String)
    case badColor(slot: String, value: String)
    case sessionColorCount(Int)
    case tooLarge(Int)
    case badField(String)
    case colorNotString(slot: String)

    /// Truncates an offending value to 40 characters and flattens newlines so a message stays one line.
    static func clip(_ text: String) -> String {
        let flat = text.map { $0.isNewline ? " " : String($0) }.joined()
        return flat.count > 40 ? String(flat.prefix(40)) + "..." : flat
    }

    /// A one-line, human-readable message.
    public var message: String {
        switch self {
        case .notJSON: return "Not a JSON object"
        case .missingName: return "Missing \"name\""
        case .badAppearance(let value):
            if value.isEmpty { return "missing \"appearance\" (dark or light)" }
            return "\"appearance\" must be \"dark\" or \"light\" (got \"\(Self.clip(value))\")"
        case .badColor(let slot, let value):
            return "Colour \"\(Self.clip(slot))\" is not #RRGGBB or #RRGGBBAA (got \"\(Self.clip(value))\")"
        case .sessionColorCount(let n): return "\"sessionColors\" needs 6 to 12 colours (got \(n))"
        case .badField(let field): return "\"\(field)\" has the wrong type"
        case .colorNotString(let slot): return "Colour \"\(Self.clip(slot))\" is not a string"
        case .tooLarge(let bytes): return "File is too large (\(bytes) bytes, limit \(ThemeFile.maxBytes))"
        }
    }
}

/// A parsed theme file. Unknown colour slots are kept; later layers ignore them.
public struct ThemeFile: Equatable, Sendable {
    public static let maxBytes = 256 * 1024

    public var name: String
    public var appearance: ThemeAppearance
    public var base: String?
    public var author: String?
    public var credit: String?
    public var colors: [String: ThemeRGBA]
    public var sessionColors: [ThemeRGBA]?

    public init(name: String, appearance: ThemeAppearance, base: String? = nil, author: String? = nil,
                credit: String? = nil, colors: [String: ThemeRGBA] = [:], sessionColors: [ThemeRGBA]? = nil) {
        self.name = name
        self.appearance = appearance
        self.base = base
        self.author = author
        self.credit = credit
        self.colors = colors
        self.sessionColors = sessionColors
    }

    public static func parse(_ data: Data) throws(ThemeFileError) -> ThemeFile {
        if data.count > maxBytes { throw .tooLarge(data.count) }
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            throw .notJSON
        }
        guard let name = dict["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw .missingName
        }
        let rawAppearance = dict["appearance"] as? String ?? ""
        guard let appearance = ThemeAppearance(rawValue: rawAppearance) else { throw .badAppearance(rawAppearance) }

        var colors: [String: ThemeRGBA] = [:]
        if let rawValue = dict["colors"], !(rawValue is NSNull) {
            guard let rawColors = rawValue as? [String: Any] else { throw .badField("colors") }
            for (slot, value) in rawColors {
                guard let text = value as? String else { throw .colorNotString(slot: slot) }
                guard let color = ThemeRGBA(hex: text) else { throw .badColor(slot: slot, value: text) }
                colors[slot] = color
            }
        }

        var sessionColors: [ThemeRGBA]?
        if let rawValue = dict["sessionColors"], !(rawValue is NSNull) {
            guard let rawList = rawValue as? [Any] else { throw .badField("sessionColors") }
            guard (6...12).contains(rawList.count) else { throw .sessionColorCount(rawList.count) }
            var list: [ThemeRGBA] = []
            for (index, value) in rawList.enumerated() {
                let slot = "sessionColors[\(index)]"
                guard let text = value as? String else { throw .colorNotString(slot: slot) }
                guard let color = ThemeRGBA(hex: text) else { throw .badColor(slot: slot, value: text) }
                list.append(color)
            }
            sessionColors = list
        }

        return ThemeFile(
            name: name, appearance: appearance,
            base: dict["base"] as? String,
            author: dict["author"] as? String,
            credit: (dict["credit"] as? String) ?? (dict["source"] as? String),
            colors: colors, sessionColors: sessionColors)
    }
}

extension ThemeFile {
    /// Pretty-printed JSON with sorted keys and uppercase hex colours; round-trips through `parse`.
    public func encoded() throws -> Data {
        var dict: [String: Any] = ["name": name, "appearance": appearance.rawValue]
        if let base { dict["base"] = base }
        if let author { dict["author"] = author }
        if let credit { dict["credit"] = credit }
        dict["colors"] = colors.mapValues { $0.hex }
        if let sessionColors { dict["sessionColors"] = sessionColors.map(\.hex) }
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try JSONSerialization.data(withJSONObject: dict, options: options)
    }
}
