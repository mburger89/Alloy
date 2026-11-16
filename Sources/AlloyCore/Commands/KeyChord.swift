import Foundation

/// Modifier keys of a chord. `primary` is the platform's main shortcut modifier (Command on macOS, Control elsewhere);
/// `cmd` and `ctrl` name those keys exactly.
public struct ChordModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let primary = ChordModifiers(rawValue: 1 << 0)
    public static let cmd = ChordModifiers(rawValue: 1 << 1)
    public static let ctrl = ChordModifiers(rawValue: 1 << 2)
    public static let alt = ChordModifiers(rawValue: 1 << 3)
    public static let shift = ChordModifiers(rawValue: 1 << 4)

    /// Canonical order, which is also the order of the tokens in `KeyChord.description`.
    static let ordered: [(ChordModifiers, String)] = [
        (.primary, "primary"), (.cmd, "cmd"), (.ctrl, "ctrl"), (.alt, "alt"), (.shift, "shift"),
    ]
}

/// Keys that are not a single printable character.
public enum NamedKey: String, CaseIterable, Codable, Sendable {
    case up, down, left, right, home, end, pageUp, pageDown, tab, `return`, escape, delete, forwardDelete, space
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20
}

public enum ChordKey: Hashable, Sendable {
    /// A printable character, always lowercased.
    case character(Character)
    case named(NamedKey)
}

/// A key and its modifiers, in a platform-neutral form that is stored in settings as a string such as
/// `primary+shift+p`, `ctrl+tab` or `f12`.
public struct KeyChord: Hashable, Codable, Sendable {
    public var modifiers: ChordModifiers
    public var key: ChordKey

    public init(modifiers: ChordModifiers = [], key: ChordKey) {
        self.modifiers = modifiers
        if case .character(let c) = key {
            self.key = .character(Character(String(c).lowercased()))
        } else {
            self.key = key
        }
    }

    /// Canonical text: modifiers in the order primary, cmd, ctrl, alt, shift, then the key, joined by `+`.
    public var description: String {
        var parts = ChordModifiers.ordered.compactMap { modifiers.contains($0.0) ? $0.1 : nil }
        switch key {
        case .character(let c): parts.append(String(c))
        case .named(let n): parts.append(n.rawValue)
        }
        return parts.joined(separator: "+")
    }

    /// Nil for an empty key, a modifier-only chord, an unknown token or a duplicate token. Case-insensitive.
    public static func parse(_ text: String) -> KeyChord? {
        var s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // The "+" key itself: "+", or a chord ending in "++".
        var tokens: [String]
        if s == "+" {
            tokens = ["+"]
        } else if s.hasSuffix("++") {
            s.removeLast()
            tokens = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            guard tokens.last == "" else { return nil }
            tokens[tokens.count - 1] = "+"
        } else {
            tokens = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        }
        var mods: ChordModifiers = []
        var key: ChordKey?
        for raw in tokens {
            let token = raw.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { return nil }
            let lower = token.lowercased()
            if let m = ChordModifiers.ordered.first(where: { $0.1 == lower }) {
                if mods.contains(m.0) { return nil }
                mods.insert(m.0)
            } else if let n = NamedKey.allCases.first(where: { $0.rawValue.lowercased() == lower }) {
                if key != nil { return nil }
                key = .named(n)
            } else if token.count == 1 {
                if key != nil { return nil }
                key = .character(Character(lower))
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        return KeyChord(modifiers: mods, key: key)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let chord = KeyChord.parse(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Malformed chord: \(text)"))
        }
        self = chord
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// The palette spec's name for a command's shortcut: it is the chord.
public typealias CommandShortcut = KeyChord
