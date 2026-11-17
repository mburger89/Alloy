@testable import AlloyCore
import Foundation
import Testing

@MainActor @Suite struct KeymapTests {
    private func c(_ s: String) -> KeyChord { KeyChord.parse(s)! }

    @Test func defaultUsedWithoutOverride() {
        let k = Keymap()
        k.update(defaults: [("a", c("primary+k")), ("b", nil)], overrides: [:])
        #expect(k.chord(for: "a") == c("primary+k"))
        #expect(k.chord(for: "b") == nil)
        #expect(k.conflicts.isEmpty)
    }

    @Test func overrideReplacesAndGivesChordToUnboundDefault() {
        let k = Keymap()
        k.update(defaults: [("a", c("primary+k")), ("b", nil)], overrides: ["a": "primary+j", "b": "ctrl+tab"])
        #expect(k.chord(for: "a") == c("primary+j"))
        #expect(k.chord(for: "b") == c("ctrl+tab"))
    }

    @Test func noneUnbinds() {
        let k = Keymap()
        k.update(defaults: [("a", c("primary+k"))], overrides: ["a": Keymap.unbound])
        #expect(k.chord(for: "a") == nil)
    }

    @Test func malformedOverrideFallsBackAndUnknownIdIgnored() {
        let k = Keymap()
        k.update(defaults: [("a", c("primary+k"))], overrides: ["a": "shift", "ghost": "primary+x"])
        #expect(k.chord(for: "a") == c("primary+k"))
        #expect(k.chord(for: "ghost") == nil)
    }

    @Test func clashKeepsFirstAndFlagsBoth() {
        let k = Keymap()
        k.update(defaults: [("a", c("primary+k")), ("b", c("primary+j")), ("c", nil)], overrides: ["b": "primary+k", "c": "primary+k"])
        #expect(k.chord(for: "a") == c("primary+k"))
        #expect(k.chord(for: "b") == nil)
        #expect(k.chord(for: "c") == nil)
        #expect(k.conflicts == ["a", "b", "c"])
    }

    @Test func revisionBumpsOnlyOnChange() {
        let k = Keymap()
        let defaults: [(id: String, chord: KeyChord?)] = [("a", c("primary+k"))]
        k.update(defaults: defaults, overrides: [:])
        let r = k.revision
        k.update(defaults: defaults, overrides: [:])
        k.update(defaults: defaults, overrides: ["ghost": "primary+x"])
        #expect(k.revision == r)
        k.update(defaults: defaults, overrides: ["a": "primary+j"])
        #expect(k.revision == r + 1)
    }
}

@MainActor @Suite struct KeymapPlatformTests {
    private func c(_ s: String) -> KeyChord { KeyChord.parse(s)! }

    @Test func ctrlXAndPrimaryXConflictOffMacOnly() {
        let defaults: [(id: String, chord: KeyChord?)] = [("a", c("primary+x")), ("b", c("ctrl+x"))]
        let mac = Keymap()
        mac.update(defaults: defaults, overrides: [:], primaryIsCmd: true)
        #expect(mac.conflicts.isEmpty)
        let other = Keymap()
        other.update(defaults: defaults, overrides: [:], primaryIsCmd: false)
        #expect(other.conflicts == ["a", "b"])
        #expect(other.chord(for: "a") == c("primary+x"))
        #expect(other.chord(for: "b") == nil)
    }
}
