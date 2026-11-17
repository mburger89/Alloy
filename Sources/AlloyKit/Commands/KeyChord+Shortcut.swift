import AlloyCore
import MetalUI

/// The bridge between the platform-neutral `KeyChord` and MetalUI's `KeyboardShortcut`.
extension KeyChord {
    /// The MetalUI shortcut for this chord. `primary` maps to MetalUI's `.primary` (Command on macOS), `cmd` to
    /// `.command`, `ctrl` to `.control`, `alt` to `.option`.
    public var shortcut: KeyboardShortcut { shortcut(for: .current) }

    /// The shortcut as it would be on `platform`: `primary` becomes that platform's primary modifier (so its display text
    /// reads right when shown for another platform), everything else is as in `shortcut`.
    public func shortcut(for platform: KeyboardShortcut.Platform) -> KeyboardShortcut {
        var mods: EventModifiers = []
        if modifiers.contains(.primary) { mods.formUnion(platform.primaryModifiers) }
        if modifiers.contains(.cmd) { mods.insert(.command) }
        if modifiers.contains(.ctrl) { mods.insert(.control) }
        if modifiers.contains(.alt) { mods.insert(.option) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        let equivalent: KeyEquivalent
        switch key {
        case .character(let c): equivalent = KeyEquivalent(c)
        case .named(let n): equivalent = Self.equivalent(of: n)
        }
        return KeyboardShortcut(equivalent, modifiers: mods)
    }

    private static func equivalent(of key: NamedKey) -> KeyEquivalent {
        switch key {
        case .up: .upArrow
        case .down: .downArrow
        case .left: .leftArrow
        case .right: .rightArrow
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .tab: .tab
        case .return: .return
        case .escape: .escape
        case .delete: .delete
        case .forwardDelete: .deleteForward
        case .space: .space
        default:
            // F1...F20 are the private-use characters U+F704...: F12 is U+F70F, as `goToDefinitionShortcut` uses.
            // swiftlint:disable:next force_unwrapping
            KeyEquivalent(Character(UnicodeScalar(0xF704 + UInt32(Self.functionNumber(key) - 1))!))
        }
    }

    private static func functionNumber(_ key: NamedKey) -> Int {
        Int(key.rawValue.dropFirst()) ?? 1
    }

    /// The chord a shortcut stands for (the inverse of `shortcut`, with Command read as `cmd`); nil for a key no chord names.
    public static func chord(from shortcut: KeyboardShortcut) -> KeyChord? {
        var mods: ChordModifiers = []
        if shortcut.modifiers.contains(.command) { mods.insert(.cmd) }
        if shortcut.modifiers.contains(.control) { mods.insert(.ctrl) }
        if shortcut.modifiers.contains(.option) { mods.insert(.alt) }
        if shortcut.modifiers.contains(.shift) { mods.insert(.shift) }
        let c = shortcut.key.character
        let named: [KeyEquivalent: NamedKey] = [
            .upArrow: .up, .downArrow: .down, .leftArrow: .left, .rightArrow: .right, .home: .home, .end: .end,
            .pageUp: .pageUp, .pageDown: .pageDown, .tab: .tab, .return: .return, .escape: .escape, .delete: .delete,
            .deleteForward: .forwardDelete, .space: .space,
        ]
        if let n = named[shortcut.key] { return KeyChord(modifiers: mods, key: .named(n)) }
        if let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1, (0xF704...0xF717).contains(scalar.value),
           let f = NamedKey(rawValue: "f\(scalar.value - 0xF704 + 1)") {
            return KeyChord(modifiers: mods, key: .named(f))
        }
        return KeyChord(modifiers: mods, key: .character(c))
    }
}
