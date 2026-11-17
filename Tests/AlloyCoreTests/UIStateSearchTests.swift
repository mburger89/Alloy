@testable import AlloyCore
import Foundation
import Testing

@Suite struct UIStateSearchTests {
    private func decode(_ json: String) throws -> UIState {
        try JSONDecoder().decode(UIState.self, from: Data(json.utf8))
    }

    @Test func oldFileWithoutTheKeysGetsDefaults() throws {
        let state = try decode(#"{"version":1,"mode":"code"}"#)
        #expect(state.sidebarTab == .files)
        #expect(state.lastSearch == nil)
    }

    @Test func unknownTabFallsBackToFiles() throws {
        let state = try decode(#"{"version":1,"sidebarTab":"bogus","lastSearch":42}"#)
        #expect(state.sidebarTab == .files)
        #expect(state.lastSearch == nil)
    }

    @Test func roundTripKeepsBoth() throws {
        let query = SearchQuery(text: "needle", caseSensitive: true, wholeWord: false, regex: true, include: "*.swift", exclude: "Tests")
        let state = UIState(sidebarTab: .search, lastSearch: query)
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(UIState.self, from: data)
        #expect(back.sidebarTab == .search)
        #expect(back.lastSearch == query)
        #expect(back == state)
    }

    @Test func versionStaysOne() { #expect(UIState.currentVersion == 1) }
}
