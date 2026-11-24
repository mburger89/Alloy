import Foundation
import Testing
@testable import AlloyCore

@Suite("PluginSetting")
struct PluginSettingTests {
    private func decode(_ json: String) throws -> AlloySettings {
        try JSONDecoder().decode(AlloySettings.self, from: Data(json.utf8))
    }

    private let valid = #"{"enabled":true,"version":"1.0.0","source":{"kind":"folder","path":"/x"},"grants":["project.read"]}"#

    @Test func missingPluginsKeyDecodesEmpty() throws {
        #expect(try decode("{}").plugins.isEmpty)
    }

    @Test func oneBadEntryDropsOnlyThatEntry() throws {
        let s = try decode(#"{"plugins":{"a.b":\#(valid),"c.d":{"enabled":"yes"}}}"#)
        #expect(Array(s.plugins.keys) == ["a.b"])
    }

    @Test func unknownGrantStringsAreDropped() throws {
        let s = try decode(#"{"plugins":{"a.b":{"source":{"kind":"folder","path":"/x"},"grants":["project.read","teleport"]}}}"#)
        #expect(s.plugins["a.b"]?.grants == [.projectRead])
    }

    @Test func missingKeysTakeDefaults() throws {
        let s = try decode(#"{"plugins":{"a.b":{"source":{"kind":"folder","path":"/x"}}}}"#)
        let p = try #require(s.plugins["a.b"])
        #expect(!p.enabled && p.grants.isEmpty && p.values.isEmpty && p.enableOrder == 0 && !p.disabledAfterCrashes)
    }

    @Test func roundTripsSortedGrants() throws {
        let p = PluginSetting(enabled: true, version: "1.0.0", source: .git(url: "u", tag: "v1", commit: "abc"),
                              grants: [.projectRead, .mcpTools])
        let data = try JSONEncoder().encode(p)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["grants"] as? [String] == ["mcp.tools", "project.read"])
        #expect(try JSONDecoder().decode(PluginSetting.self, from: data) == p)
    }
}
