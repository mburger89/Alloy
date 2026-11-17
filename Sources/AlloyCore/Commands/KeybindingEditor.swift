import Foundation

/// Pure edits of the user's key overrides (`AlloySettings.keybindings`). Every method returns a whole new overrides
/// value, so a rebind plus its reassignment is one settings write. Only overrides are stored; unknown ids and their
/// values are never touched except by an explicit edit of that id.
public struct KeybindingEditor: Sendable {
    private let defaults: [(id: String, chord: KeyChord?)]
    private let defaultByID: [String: KeyChord?]
    private let primaryIsCmd: Bool

    /// `defaults` is in registry order.
    public init(defaults: [(id: String, chord: KeyChord?)], primaryIsCmd: Bool) {
        self.defaults = defaults
        self.primaryIsCmd = primaryIsCmd
        var map: [String: KeyChord?] = [:]
        for (id, chord) in defaults where map[id] == nil { map[id] = .some(chord) }
        defaultByID = map
    }

    private func defaultChord(_ id: String) -> KeyChord? { defaultByID[id] ?? nil }

    /// The chord the command resolves to, by `Keymap`'s rule: `none` unbinds, an unparseable value is ignored.
    public func effective(_ id: String, overrides: [String: String]) -> KeyChord? {
        Keymap.effective(default: defaultChord(id), override: overrides[id])
    }

    /// The first command (registry order) other than `id` whose effective chord clashes with `chord`.
    public func holder(of chord: KeyChord, excluding id: String, overrides: [String: String]) -> String? {
        let key = chord.resolved(primaryIsCmd: primaryIsCmd)
        for (other, _) in defaults where other != id {
            if effective(other, overrides: overrides)?.resolved(primaryIsCmd: primaryIsCmd) == key { return other }
        }
        return nil
    }

    /// Stores `chord` for `id`, or removes the override when it equals the default.
    public func binding(_ id: String, to chord: KeyChord, overrides: [String: String]) -> [String: String] {
        var result = overrides
        // Compared resolved: a recorded `cmd+x` equals a default `primary+x` on macOS.
        if let def = defaultChord(id), def.resolved(primaryIsCmd: primaryIsCmd) == chord.resolved(primaryIsCmd: primaryIsCmd) {
            result[id] = nil
        } else {
            result[id] = chord.description
        }
        return result
    }

    /// Unbinds `id`: `none`, or no entry when the command has no default.
    public func clearing(_ id: String, overrides: [String: String]) -> [String: String] {
        var result = overrides
        result[id] = defaultChord(id) == nil ? nil : Keymap.unbound
        return result
    }

    public func resetting(_ id: String, overrides: [String: String]) -> [String: String] {
        var result = overrides
        result[id] = nil
        return result
    }

    /// Removes the overrides of known ids only; unknown ids (from a newer Alloy) and their values survive.
    public func resettingAll(overrides: [String: String]) -> [String: String] {
        overrides.filter { defaultByID[$0.key] == nil }
    }

    /// Binds `chord` to `id` and unbinds `holder`, in one value.
    public func reassigning(_ chord: KeyChord, to id: String, from holder: String, overrides: [String: String]) -> [String: String] {
        clearing(holder, overrides: binding(id, to: chord, overrides: overrides))
    }

    /// An override is present and either parses or is `none`.
    public func isCustom(_ id: String, overrides: [String: String]) -> Bool {
        guard let raw = overrides[id] else { return false }
        return raw.trimmingCharacters(in: .whitespaces).lowercased() == Keymap.unbound || KeyChord.parse(raw) != nil
    }
}
