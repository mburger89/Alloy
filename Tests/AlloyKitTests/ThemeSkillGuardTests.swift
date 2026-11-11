import Foundation
import Testing

/// Only `ThemeSkillInstaller` may build a path under `.claude` for writing; `TranscriptFile` reads the CLI's
/// transcripts there and never writes.
@Suite struct ThemeSkillGuardTests {
    static let allowedIn: Set<String> = ["AlloyCore/Themes/ThemeSkillInstaller.swift", "AlloyCore/Chat/TranscriptFile.swift"]
    static let pattern = #"["~/]\.claude[/"]"#

    static func offences(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return code.range(of: pattern, options: .regularExpression) != nil ? "line \(index + 1): \(line)" : nil
        }
    }

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    @Test func onlyTheInstallerBuildsAClaudePath() throws {
        let root = Self.sourcesRoot
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var checked = 0
        var failures: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            checked += 1
            let path = String(url.path.dropFirst(root.path.count + 1))
            guard !Self.allowedIn.contains(path) else { continue }
            failures += Self.offences(in: try String(contentsOf: url, encoding: .utf8)).map { "\(path) \($0)" }
        }
        #expect(checked > 50, "found the sources")
        #expect(failures.isEmpty, "route .claude writes through ThemeSkillInstaller: \(failures.joined(separator: "; "))")
    }

    @Test func theScannerSeesClaudePaths() {
        for bad in [#"home.appendingPathComponent(".claude")"#, #"let p = "~/.claude/skills""#, #"URL(fileURLWithPath: "/x/.claude/y")"#] {
            #expect(Self.offences(in: bad).count == 1, "\(bad)")
        }
        #expect(Self.offences(in: "// the .claude folder").isEmpty)
        #expect(Self.offences(in: "let claudePath = x").isEmpty)
    }
}
