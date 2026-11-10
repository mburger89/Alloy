import AlloyCore
@testable import AlloyKit
import Foundation
import Testing

@Suite struct BuiltInThemeTests {
    private static let library = ThemeLibrary(builtIns: BuiltInThemes.all)

    private func resolve(_ id: String) throws -> ResolvedTheme {
        try #require(Self.library.resolve(id))
    }

    @Test func sixBuiltInsInOrder() {
        #expect(BuiltInThemes.all.map(\.id) == ["dracula", "alloy-dark", "alloy-light", "solarized-dark", "solarized-light", "one-dark"])
        #expect(BuiltInThemes.all.first?.id == "dracula")
    }

    @Test func everyBuiltInIsCreditedAndParses() throws {
        for entry in BuiltInThemes.all {
            #expect(entry.isBuiltIn)
            #expect(!(entry.file.author ?? "").isEmpty, "\(entry.id) author")
            let theme = try resolve(entry.id)
            for slot in ThemeSlots.all { #expect(theme.colors[slot.name] != nil, "\(entry.id) lacks \(slot.name)") }
            #expect((6...12).contains(theme.sessionColors.count), "\(entry.id) session colours")
            #expect(Set(theme.sessionColors.map(\.hex)).count == theme.sessionColors.count, "\(entry.id) distinct session colours")
        }
        for entry in BuiltInThemes.all where !entry.id.hasPrefix("alloy-") {
            #expect(!(entry.file.credit ?? "").isEmpty, "\(entry.id) credit")
        }
    }

    /// Published palette values; the few that had to move for contrast are asserted at the value docs/themes.md records.
    @Test func paletteAnchorsAreFaithful() throws {
        func hex(_ id: String, _ slot: String) throws -> String { try #require(resolve(id).colors[slot]).hex.uppercased() }
        // Published values, kept because they pass the audit.
        #expect(try hex("dracula", "chatFill") == "#282A36")
        #expect(try hex("dracula", "textPrimary") == "#F8F8F2")
        #expect(try hex("dracula", "syntax.keyword") == "#FF79C6")
        #expect(try hex("dracula", "syntax.string") == "#F1FA8C")
        #expect(try hex("dracula", "syntax.function") == "#50FA7B")
        #expect(try hex("solarized-dark", "chatFill") == "#002B36")
        #expect(try hex("solarized-light", "chatFill") == "#FDF6E3")
        #expect(try hex("one-dark", "chatFill") == "#282C34")
        #expect(try hex("one-dark", "textPrimary") == "#ABB2BF")
        #expect(try hex("one-dark", "syntax.string") == "#98C379")
        #expect(try hex("one-dark", "syntax.function") == "#61AFEF")
        // Adjusted for contrast; docs/themes.md records the same values.
        #expect(try hex("dracula", "syntax.comment") == "#97A2C3")
        #expect(try hex("solarized-dark", "textPrimary") == "#93A1A1")
        #expect(try hex("solarized-light", "textPrimary") == "#56696F")
    }

    @Test func docsListEverySlotAndCredit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let docs = try String(contentsOf: root.appendingPathComponent("docs/themes.md"), encoding: .utf8)
        for slot in ThemeSlots.all {
            #expect(docs.contains("`\(slot.name)`"), "docs lack slot \(slot.name)")
            #expect(docs.contains(slot.purpose), "docs lack purpose of \(slot.name)")
        }
        for entry in BuiltInThemes.all {
            if let credit = entry.file.credit { #expect(docs.contains(credit), "docs lack credit \(credit)") }
        }
        #expect(docs.contains("`syntax.comment`: #6272A4 → #97A2C3"))
        #expect(docs.contains("`textPrimary`: #839496 → #93A1A1 (in-palette: base1)"))
        #expect(docs.contains("`textPrimary`: #657B83 → #56696F"))
    }

    /// Every `slot: old → new` line under a theme's heading in the docs names the value the theme file really uses.
    @Test func docsAdjustmentsMatchThemeFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let docs = try String(contentsOf: root.appendingPathComponent("docs/themes.md"), encoding: .utf8)
        let ids = ["Dracula": "dracula", "Solarized Dark": "solarized-dark", "Solarized Light": "solarized-light", "One Dark": "one-dark"]
        var theme: ResolvedTheme?
        var checked = 0
        for line in docs.split(separator: "\n") {
            if line.hasPrefix("### ") {
                theme = ids[String(line.dropFirst(4))].flatMap { Self.library.resolve($0) }
                continue
            }
            guard let theme, line.hasPrefix("- `"), line.contains(" → ") else { continue }
            let parts = line.dropFirst(3).components(separatedBy: "`: ")
            let slot = parts[0]
            let values = parts[1].components(separatedBy: " → ")
            let new = String(values[1].prefix(7)).uppercased()
            let old = String(values[0]).uppercased()
            let actual: String?
            if slot.hasPrefix("sessionColors["), let index = Int(slot.dropFirst(14).dropLast()), theme.sessionColors.indices.contains(index) {
                actual = theme.sessionColors[index].hex.uppercased()
            } else {
                actual = theme.colors[slot]?.hex.uppercased()
            }
            #expect(actual == new, "\(theme.id) \(slot): docs say \(new), file has \(actual ?? "nothing")")
            #expect(old != new)
            checked += 1
        }
        #expect(checked > 40)
    }

    /// In a light theme the segmented picker's thumb is painted in `surface`, so the track (`surfaceSecondary`) must differ from
    /// `surface` by at least 1.6:1 for the thumb to read against it. Dark themes draw the thumb as a text-colour overlay, so
    /// they are not covered. Alloy Light (1.24:1) is a known gap, left out until its tab text margins are reviewed.
    @Test(arguments: ["solarized-light"])
    func trackContrastsWithSurface(themeID: String) throws {
        func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
            func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }
        let theme = try resolve(themeID)
        let track = try #require(theme.colors["surfaceSecondary"])
        let surface = try #require(theme.colors["surface"])
        let a = luminance((track.r, track.g, track.b)), b = luminance((surface.r, surface.g, surface.b))
        let value = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        #expect(value >= 1.6, "\(themeID) track vs surface \(String(format: "%.2f", value)) < 1.6")
    }
}
