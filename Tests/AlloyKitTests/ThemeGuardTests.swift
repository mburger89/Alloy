import Foundation
import Testing

/// Keeps new views and the highlighter inside the audited palette: colours come from `Theme.swift` tokens, never MetalUI's `.secondary`
/// (too faint on tints, see `MutedInk`), an inline literal or a named system colour.
@Suite struct ThemeGuardTests {
    struct Rule {
        let pattern: String
        /// Paths (relative to `Sources/`) that may use the spelling. Empty means nowhere.
        let allowedIn: Set<String>
    }

    private static let named = "white|black|gray|red|green|blue|orange|yellow|pink|purple"

    static let rules: [Rule] = [
        Rule(pattern: #"\.secondary\b"#, allowedIn: []),
        Rule(pattern: #"Color\(hex:"#, allowedIn: []),
        Rule(pattern: #"Color\(red:"#, allowedIn: []),
        Rule(pattern: #"Color\(white:"#, allowedIn: []),
        // A named colour used as a colour (`Color.red`, `.foregroundColor(.white)`, `.fill(.black)`, ...).
        Rule(pattern: #"(Color\.|foregroundColor\(\.|foregroundStyle\(\.|\.fill\(\.|\.background\(\.|\.tint\(\.|\.border\(\.)("# + named + #")\b"#,
             allowedIn: []),
        // A theme file's own colours, shown only by the swatches of a theme row.
        Rule(pattern: #"Color\(themeRGBA:"#, allowedIn: ["AlloyKit/Themes/ThemeRow.swift"]),
        // Raw colour constructors belong to the theme plumbing.
        Rule(pattern: #"\bHsla\("#, allowedIn: ["AlloyKit/Themes/ThemeApplier.swift", "AlloyKit/Themes/ThemeSlots.swift"]),
        Rule(pattern: #"\bRgba\("#, allowedIn: ["AlloyKit/Themes/ThemeApplier.swift", "AlloyKit/Themes/ThemeSlots.swift"]),
    ]

    /// Files exempt from every rule, by path relative to `Sources/`, with the reason.
    static let allowlist: [String: String] = [
        "AlloyKit/Theme.swift": "defines the tokens",
        "AlloyHighlight/SyntaxPalette.swift": "holds the syntax keys' default colours",
    ]

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    static func offences(in text: String, path: String = "") -> [String] {
        var out: [String] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            for rule in rules where !rule.allowedIn.contains(path) && code.range(of: rule.pattern, options: .regularExpression) != nil {
                out.append("line \(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return out
    }

    @Test func noViewUsesSecondaryOrAnInlineColour() throws {
        let root = Self.sourcesRoot
        var files: [URL] = []
        for dir in ["AlloyKit", "AlloyHighlight"] {
            files += try #require(FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil))
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        #expect(files.count > 20, "found the sources")
        var failures: [String] = []
        for file in files {
            let path = String(file.path.dropFirst(root.path.count + 1))
            guard Self.allowlist[path] == nil else { continue }
            failures += Self.offences(in: try String(contentsOf: file, encoding: .utf8), path: path).map { "\(path) \($0)" }
        }
        #expect(failures.isEmpty, "use a Theme.swift token (MutedInk, ...): \(failures.joined(separator: "; "))")
    }

    @Test func theScannerSeesTheBannedSpellings() {
        for bad in ["Text(a).foregroundColor(.secondary)", "let c = Color(hex: 0x123456)", "Color(red: 1, green: 0, blue: 0)",
                    "Color(white: 0.5)", "Hsla(h: 0, s: 0, l: 0, a: 1)", "Rgba(r: 0, g: 0, b: 0, a: 1)", "Color(themeRGBA: x)",
                    "Text(a).foregroundColor(.white)", "let c = Color.red", "Rectangle().fill(.black)", "x.background(.gray)",
                    "x.tint(.orange)", "x.foregroundStyle(.purple)"] {
            #expect(Self.offences(in: bad, path: "AlloyKit/Other.swift").count == 1, "\(bad)")
        }
        #expect(Self.offences(in: "// .secondary is banned").isEmpty)
        #expect(Self.offences(in: "Text(a).foregroundColor(.mutedInk)").isEmpty)
        #expect(Self.offences(in: "Rectangle().fill(.panelFill)").isEmpty)
        #expect(Self.offences(in: "let redFlag = 1; x.greenish()").isEmpty)
    }

    @Test func confinedSpellingsAreAllowedOnlyWhereListed() {
        #expect(Self.offences(in: "Color(themeRGBA: x)", path: "AlloyKit/Themes/ThemeRow.swift").isEmpty)
        #expect(Self.offences(in: "Rgba(r: 0, g: 0, b: 0, a: 1)", path: "AlloyKit/Themes/ThemeApplier.swift").isEmpty)
        #expect(Self.offences(in: "Hsla(h: 0, s: 0, l: 0, a: 1)", path: "AlloyKit/Themes/ThemeSlots.swift").isEmpty)
        #expect(Self.offences(in: "Color(themeRGBA: x)", path: "AlloyKit/SettingsView.swift").count == 1)
        #expect(Self.offences(in: "Hsla(h: 0, s: 0, l: 0, a: 1)", path: "AlloyKit/ThemeRow.swift").count == 1)
    }
}
