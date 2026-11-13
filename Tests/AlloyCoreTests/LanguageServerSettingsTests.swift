import Foundation
import Testing
@testable import AlloyCore

@Suite struct LanguageServerSettingsTests {
    private func tempSupport() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("alloy-ls-settings-\(UUID().uuidString)")
    }

    @Test func oldSettingsFileWithoutLanguageServersStillLoads() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let url = AlloySettings.url(appSupport: support)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"claudePath":"/x/claude","theme":"nord"}"#.write(to: url, atomically: true, encoding: .utf8)
        let s = AlloySettings.load(appSupport: support)
        #expect(s.claudePath == "/x/claude")
        #expect(s.theme == "nord")
        #expect(s.languageServers.isEmpty)
    }

    @Test func languageServersRoundTrip() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var s = AlloySettings()
        s.languageServers = [
            "gopls": ServerConfigOverride(enabled: false),
            "my-ls": ServerConfigOverride(extensions: ["foo"], command: "my-ls", arguments: ["--x"],
                                          initializationOptions: .object(["a": .bool(true)])),
        ]
        try s.save(appSupport: support)
        #expect(AlloySettings.load(appSupport: support).languageServers == s.languageServers)
    }

    @Test func malformedLanguageServersFallBackWithoutWipingOtherSettings() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let url = AlloySettings.url(appSupport: support)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"theme":"nord","languageServers":[1,2]}"#.write(to: url, atomically: true, encoding: .utf8)
        let s = AlloySettings.load(appSupport: support)
        #expect(s.theme == "nord")
        #expect(s.languageServers.isEmpty)
    }

    @Test func malformedEntryDropsOnlyThatEntry() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let url = AlloySettings.url(appSupport: support)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"languageServers":{"gopls":{"enabled":false},"bad":{"extensions":"nope"},"ok":{"command":"x","extensions":["x"],"languageIDs":{"x":"xx"}}}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let s = AlloySettings.load(appSupport: support)
        #expect(Set(s.languageServers.keys) == ["gopls", "ok"])
        #expect(s.languageServers["gopls"]?.enabled == false)
        #expect(s.languageServers["ok"]?.languageIDs == ["x": "xx"])
    }
}
