@testable import AlloyCore
import Foundation
import Testing

@Suite struct ThemeContrastTests {
    private static let library = ThemeLibrary(builtIns: BuiltInThemes.all)

    private func rgba(_ hex: String) -> ThemeRGBA { ThemeRGBA(hex: hex)! }

    @Test func ratioIsWCAG() {
        #expect(abs(ThemeContrast.ratio(rgba("#000000"), rgba("#FFFFFF")) - 21) < 0.001)
        #expect(abs(ThemeContrast.ratio(rgba("#FFFFFF"), rgba("#FFFFFF")) - 1) < 0.001)
        #expect(abs(ThemeContrast.ratio(rgba("#767676"), rgba("#FFFFFF")) - 4.54) < 0.01)
    }

    @Test func ratioIsRoundedDownSoANearMissNeverReadsAsTheMinimum() throws {
        let white = rgba("#FFFFFF")
        var file = ThemeFile(name: "Draft", appearance: .light, base: "alloy-light")
        file.colors["mutedInk"] = rgba("#777777") // 4.48 on white
        file.colors["chatFill"] = white
        let (theme, _) = Self.library.resolve(draft: file)
        let finding = try #require(ThemeContrast.findings(theme).first { $0.pair == "mutedInk on chatFill" })
        let exact = ThemeContrast.ratio(rgba("#777777"), white)
        #expect(exact > 4.475 && exact < 4.48, "\(exact)") // rounding to nearest would read 4.48
        #expect(finding.ratio == 4.47)
        #expect(finding.ratio <= exact)
    }

    @Test func translucentLayersComposite() {
        let out = ThemeContrast.composite([rgba("#00000080")])
        #expect(abs(out.r - 0.5) < 0.01 && abs(out.g - 0.5) < 0.01 && abs(out.b - 0.5) < 0.01)
        #expect(out.a == 1)
    }

    @Test func lowContrastPairsAreReported() throws {
        var file = ThemeFile(name: "Draft", appearance: .dark, base: "dracula")
        file.colors["mutedInk"] = rgba("#3A3C4E")
        let (theme, notes) = Self.library.resolve(draft: file)
        #expect(notes.isEmpty)
        let finding = try #require(ThemeContrast.findings(theme).first { $0.pair == "mutedInk on chatFill" })
        #expect(finding.minimum == 4.5)
        #expect(finding.ratio < 4.5)
        #expect(finding.foreground == "mutedInk" && finding.layers == ["chatFill"])
    }

    @Test func lowContrastPickerThumbEdgeIsReported() throws {
        for (base, appearance) in [("dracula", ThemeAppearance.dark), ("alloy-light", .light)] {
            var file = ThemeFile(name: "Draft", appearance: appearance, base: base)
            file.colors["pickerThumbEdge"] = appearance == .dark ? rgba("#4A4D61") : rgba("#E0E3E9")
            let (theme, _) = Self.library.resolve(draft: file)
            let pairs = Set(ThemeContrast.findings(theme).map(\.pair))
            #expect(pairs.contains("pickerThumbEdge on surfaceSecondary"), "\(base): \(pairs)")
            #expect(pairs.contains("pickerThumbEdge on surfaceSecondary over pickerThumb"), "\(base): \(pairs)")
        }
        // A theme without the slot is not audited for it.
        var bare = try #require(Self.library.resolve("dracula"))
        bare.colors["pickerThumbEdge"] = nil
        #expect(!ThemeContrast.findings(bare).contains { $0.pair.hasPrefix("pickerThumbEdge") })
    }

    @Test func derivedSecondaryIsChecked() {
        var file = ThemeFile(name: "Draft", appearance: .light, base: "alloy-light")
        file.colors["textPrimary"] = rgba("#999999")
        let (theme, _) = Self.library.resolve(draft: file)
        var bare = theme
        bare.colors["textSecondary"] = nil
        let findings = ThemeContrast.findings(bare)
        #expect(findings.contains { $0.pair == "textSecondary on surface" })
    }

    @Test func draftResolvesOverBase() throws {
        var file = ThemeFile(name: "Draft", appearance: .dark, base: "one-dark")
        file.colors["accent"] = rgba("#FF0000")
        let (theme, notes) = Self.library.resolve(draft: file)
        #expect(notes.isEmpty)
        let oneDark = try #require(Self.library.resolve("one-dark"))
        #expect(theme.colors["chatFill"] == oneDark.colors["chatFill"])
        #expect(theme.colors["accent"] == rgba("#FF0000"))

        file.base = "nope"
        let (fallback, fallbackNotes) = Self.library.resolve(draft: file)
        #expect(fallbackNotes == ["Unknown base \"nope\"; using alloy-dark."])
        let alloyDark = try #require(Self.library.resolve("alloy-dark"))
        #expect(fallback.colors["chatFill"] == alloyDark.colors["chatFill"])
        file.appearance = .light
        file.base = nil
        #expect(Self.library.resolve(draft: file).notes.isEmpty)
    }
}
