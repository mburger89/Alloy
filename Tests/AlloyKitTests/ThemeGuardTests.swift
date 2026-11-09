import Foundation
import Testing

/// Keeps new views inside the audited palette: colours come from `Theme.swift` tokens, never MetalUI's `.secondary`
/// (too faint on tints, see `MutedInk`) or an inline literal.
@Suite struct ThemeGuardTests {
    /// Files that may use a banned spelling, with the reason. Empty today.
    static let allowlist: [String: String] = [:]

    private static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AlloyKit")
    }

    static func offences(in text: String) -> [String] {
        var out: [String] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            for banned in [#"\.secondary\b"#, #"Color\(hex:"#, #"Color\(red:"#] where code.range(of: banned, options: .regularExpression) != nil {
                out.append("line \(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return out
    }

    @Test func noViewUsesSecondaryOrAnInlineColour() throws {
        let root = Self.sourcesDirectory
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 20, "found the sources")
        var failures: [String] = []
        for file in files where file.lastPathComponent != "Theme.swift" && Self.allowlist[file.lastPathComponent] == nil {
            let text = try String(contentsOf: file, encoding: .utf8)
            failures += Self.offences(in: text).map { "\(file.lastPathComponent) \($0)" }
        }
        #expect(failures.isEmpty, "use a Theme.swift token (MutedInk, ...): \(failures.joined(separator: "; "))")
    }

    @Test func theScannerSeesTheBannedSpellings() {
        #expect(Self.offences(in: "Text(a).foregroundColor(.secondary)").count == 1)
        #expect(Self.offences(in: "let c = Color(hex: 0x123456)").count == 1)
        #expect(Self.offences(in: "Color(red: 1, green: 0, blue: 0)").count == 1)
        #expect(Self.offences(in: "// .secondary is banned").isEmpty)
        #expect(Self.offences(in: "Text(a).foregroundColor(.mutedInk)").isEmpty)
    }
}
