import Foundation
import Testing

enum Fixture {
    /// Non-empty lines of `Fixtures/<name>.jsonl`.
    static func lines(_ name: String) -> [Data] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else {
            Issue.record("missing or unreadable fixture: \(name).jsonl")
            return []
        }
        return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
    }
}

@Suite struct FixturePrivacyTests {
    /// Words from the machine that recorded the fixtures; split so this file does not carry them itself.
    private static let forbidden: [String] = [
        "mbur" + "ger", "maxbur" + "ger", "Max Bur" + "ger", "@gm" + "ail", "tes" + "sl", "cdb-" + "scan", "oxi" + "mux", "mo" + "shi",
        "sos" + "umi", "Claude " + "Max", "Fleet" + "View", "memory_paths\":[\"/", "/Us" + "ers/", "claude" + "-501",
    ]

    @Test func recordedFixturesCarryNoPrivateData() throws {
        let urls = try #require(Bundle.module.urls(forResourcesWithExtension: "jsonl", subdirectory: "Fixtures"))
        #expect(urls.count > 10)
        for url in urls {
            let text = try String(contentsOf: url, encoding: .utf8)
            for word in Self.forbidden where text.contains(word) {
                Issue.record("\(url.lastPathComponent) contains \(word)")
            }
        }
    }
}
