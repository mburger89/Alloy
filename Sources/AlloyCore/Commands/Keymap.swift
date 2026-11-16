import Foundation
import Observation

/// The resolved key map: each command id's default chord with the user's `AlloySettings.keybindings` applied.
/// Only `revision` is observed, and it bumps only when the resolved map or its conflicts change, so unrelated
/// settings writes never touch readers.
@MainActor @Observable
public final class Keymap {
    /// The override value that unbinds a command.
    public nonisolated static let unbound = "none"

    public private(set) var revision = 0

    @ObservationIgnored private var resolved: [String: KeyChord] = [:]
    @ObservationIgnored private var clashing: Set<String> = []

    public init() {}

    /// Ids sharing one resolved chord (the first of them in registry order keeps it).
    public var conflicts: Set<String> { clashing }

    public func chord(for id: String) -> KeyChord? { resolved[id] }

    /// `defaults` is in registry order. An override of `"none"` unbinds; one that does not parse is ignored; an unknown
    /// id is ignored. Two commands on one chord: the first keeps it, the other resolves to nil, both are in `conflicts`.
    public func update(defaults: [(id: String, chord: KeyChord?)], overrides: [String: String]) {
        var map: [String: KeyChord] = [:]
        var owner: [KeyChord: String] = [:]
        var clash: Set<String> = []
        for (id, def) in defaults where map[id] == nil && !clash.contains(id) {
            var chord = def
            if let raw = overrides[id] {
                if raw.trimmingCharacters(in: .whitespaces).lowercased() == Self.unbound {
                    chord = nil
                } else if let parsed = KeyChord.parse(raw) {
                    chord = parsed
                }
            }
            guard let chord else { continue }
            if let first = owner[chord] {
                clash.insert(first)
                clash.insert(id)
            } else {
                owner[chord] = id
                map[id] = chord
            }
        }
        if map != resolved || clash != clashing {
            resolved = map
            clashing = clash
            revision += 1
        }
    }
}
