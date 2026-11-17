import Foundation
import Testing

@testable import AlloyCore

@Suite struct AlloySettingsSearchTests {
    private func decode(_ json: String) throws -> AlloySettings {
        try JSONDecoder().decode(AlloySettings.self, from: Data(json.utf8))
    }

    @Test func missingKeysGiveDefaults() throws {
        let s = try decode("{}")
        #expect(s.searchMaxResults == 10_000)
        #expect(s.searchExcludes == [])
    }

    @Test func lowValueClampsUp() throws {
        #expect(try decode(#"{"searchMaxResults": 5}"#).searchMaxResults == 100)
        #expect(try decode(#"{"searchMaxResults": 900000}"#).searchMaxResults == 50_000)
    }

    @Test func wrongTypesFallBackWithoutLosingOtherKeys() throws {
        let s = try decode(#"{"searchMaxResults": "x", "searchExcludes": 3, "theme": "nord"}"#)
        #expect(s.searchMaxResults == 10_000)
        #expect(s.searchExcludes == [])
        #expect(s.theme == "nord")
    }

    @Test func roundTrips() throws {
        var s = AlloySettings()
        s.searchMaxResults = 777
        s.searchExcludes = ["dist", "**/*.min.js"]
        let back = try JSONDecoder().decode(AlloySettings.self, from: JSONEncoder().encode(s))
        #expect(back.searchMaxResults == 777)
        #expect(back.searchExcludes == ["dist", "**/*.min.js"])
    }
}
