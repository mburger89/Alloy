import Foundation
import AlloyTestSupport
import Testing
@testable import AlloyCore

@Suite struct LanguageServerSettingsTests {
    private func tempSupport() -> URL {
        TempFiles.url("alloy-ls-settings")
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

    @Test func gitSettingsDecodeTolerantly() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let url = AlloySettings.url(appSupport: support)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"theme":"nord"}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(AlloySettings.load(appSupport: support).git == GitSettings())
        #expect(GitSettings().liveMarks == false)
        try #"{"git":{"liveMarks":"x","gitPath":"/g","gutterMarks":false}}"#.write(to: url, atomically: true, encoding: .utf8)
        let g = AlloySettings.load(appSupport: support).git
        #expect(g == GitSettings(gutterMarks: false, statusColours: true, liveMarks: false, gitPath: "/g"))
    }
}

@Suite struct FormatSettingsTests {
    private func tempSupport() -> URL {
        TempFiles.url("alloy-fmt-settings")
    }

    private func write(_ json: String, to support: URL) throws {
        let url = AlloySettings.url(appSupport: support)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func formatOnSaveAndFormattersRoundTrip() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        var s = AlloySettings()
        s.languageServers = ["gopls": ServerConfigOverride(formatOnSave: true)]
        s.formatters = ["swift": "swiftformat"]
        try s.save(appSupport: support)
        let back = AlloySettings.load(appSupport: support)
        #expect(back.languageServers["gopls"]?.formatOnSave == true)
        #expect(back.formatters == ["swift": "swiftformat"])
    }

    @Test func oldFileWithoutEitherDecodesWithDefaults() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        try write(#"{"theme":"nord","languageServers":{"gopls":{"enabled":false}}}"#, to: support)
        let s = AlloySettings.load(appSupport: support)
        #expect(s.theme == "nord")
        #expect(s.formatters.isEmpty)
        #expect(s.languageServers["gopls"]?.formatOnSave == nil)
        #expect(s.languageServers["gopls"]?.enabled == false)
    }

    @Test func malformedFormattersFallBackWithoutDroppingOtherKeys() throws {
        let support = tempSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        try write(#"{"theme":"nord","formatters":["a","b"],"languageServers":{"gopls":{"formatOnSave":true}}}"#, to: support)
        let s = AlloySettings.load(appSupport: support)
        #expect(s.theme == "nord")
        #expect(s.formatters.isEmpty)
        #expect(s.languageServers["gopls"]?.formatOnSave == true)
    }
}
