@testable import AlloyCore
import Foundation
import Testing

@Suite struct KeyChordTests {
    @Test func everyNamedKeyRoundTrips() throws {
        for n in NamedKey.allCases {
            let chord = KeyChord(modifiers: [.ctrl, .shift], key: .named(n))
            #expect(KeyChord.parse(chord.description) == chord)
        }
        #expect(NamedKey.allCases.contains(.f1) && NamedKey.allCases.contains(.f20))
        #expect(KeyChord.parse("f12")?.key == .named(.f12))
    }

    @Test func canonicalOrderAndCase() throws {
        let c = try #require(KeyChord.parse("Shift+Primary+P"))
        #expect(c.description == "primary+shift+p")
        #expect(c.key == .character("p"))
        #expect(KeyChord.parse("ctrl+tab")?.description == "ctrl+tab")
        #expect(KeyChord.parse("alt+cmd+PageUp")?.description == "cmd+alt+pageUp")
    }

    @Test func plusKey() throws {
        let c = try #require(KeyChord.parse("primary++"))
        #expect(c.key == .character("+"))
        #expect(KeyChord.parse(c.description) == c)
        #expect(KeyChord.parse("+")?.key == .character("+"))
    }

    @Test func rejectsMalformed() {
        for bad in ["", " ", "shift", "primary+shift", "primary+primary+p", "bogus+p", "a+b", "primary+", "+primary", "ab"] {
            #expect(KeyChord.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func codableRoundTrip() throws {
        let c = KeyChord(modifiers: [.primary, .shift], key: .character("P"))
        let data = try JSONEncoder().encode([c])
        #expect(String(decoding: data, as: UTF8.self) == "[\"primary+shift+p\"]")
        #expect(try JSONDecoder().decode([KeyChord].self, from: data) == [c])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(KeyChord.self, from: Data("\"shift\"".utf8)) }
    }
}
