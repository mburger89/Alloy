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

    @Test func textOnIslandUsesIslandOpacityOverWindowBackground() throws {
        func findings(_ opacity: Double) throws -> [ContrastFinding] {
            var file = ThemeFile(name: "Draft", appearance: .dark, base: "alloy-dark")
            file.colors["textPrimary"] = rgba("#FFFFFF")
            file.colors["windowBackground"] = rgba("#FFFFFF")
            file.colors["islandFill"] = rgba("#000000")
            file.style = AppearanceStyleFile(islandOpacity: opacity)
            return ThemeContrast.findings(Self.library.resolve(draft: file).theme)
        }
        // White text: a nearly opaque black island reads, a 40% one over white does not.
        #expect(try findings(1.0).first { $0.pair == "text on island" } == nil)
        let faint = try #require(try findings(0.4).first { $0.pair == "text on island" })
        #expect(faint.layers == ["windowBackground", "islandFill"] && faint.minimum == 4.5)
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

    @Test func controlTextContrastIsChecked() throws {
        var file = ThemeFile(name: "Draft", appearance: .dark, base: "dracula")
        file.colors["controlFill"] = file.colors["textPrimary"] ?? rgba("#F8F8F2")
        let (theme, _) = Self.library.resolve(draft: file)
        let finding = try #require(ThemeContrast.findings(theme).first { $0.pair == "control text on control fill" })
        #expect(finding.foreground == "control text" && finding.layers == ["islandFill", "controlFill"] && finding.minimum == 4.5)
    }

    @Test func controlFillIsCompositedAtTheStyleOpacity() {
        // Light text on a mid fill: opaque it passes, mostly transparent over a light island it fails.
        var file = ThemeFile(name: "Draft", appearance: .light, base: "alloy-light")
        file.colors["textPrimary"] = rgba("#FFFFFF")
        file.colors["islandFill"] = rgba("#FFFFFF")
        file.colors["controlFill"] = rgba("#000000")
        file.style = AppearanceStyleFile(controlOpacity: 1)
        let opaque = ThemeContrast.findings(Self.library.resolve(draft: file).0)
        #expect(!opaque.contains { $0.pair == "control text on control fill" })
        file.style = AppearanceStyleFile(controlOpacity: 0.2)
        let faint = ThemeContrast.findings(Self.library.resolve(draft: file).0)
        #expect(faint.contains { $0.pair == "control text on control fill" })
    }

    @Test func lightControlsSeparateFromIslands() throws {
        for id in ["alloy-light", "solarized-light"] {
            let theme = try #require(Self.library.resolve(id))
            var control = try #require(theme.colors["controlFill"])
            let island = try #require(theme.colors["islandFill"])
            control.a *= theme.style.controlOpacity
            let shown = ThemeContrast.composite([island, control])
            #expect(ThemeContrast.ratio(shown, ThemeContrast.composite([island])) >= 1.08, "\(id)")
        }
    }

    @Test func builtInsPassControlContrast() {
        for theme in BuiltInThemes.all {
            let resolved = Self.library.resolve(theme.id)
            #expect(resolved.map { ThemeContrast.findings($0).contains { $0.pair == "control text on control fill" } } == false, "\(theme.id)")
        }
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

/// `ThemeContrast.rules` is what the theme skill shows; it must describe exactly the pairs `findings` checks.
@Suite struct ThemeContrastRulesTests {
    @Test func rulesMatchFindings() {
        var names = Set(ThemeContrast.rules.flatMap { $0.foregrounds + $0.backgrounds.flatMap { $0 } })
        names.subtract(["pickerThumb", "textSecondary", "syntax.*", "sessionColors[*]"])
        var colors: [String: ThemeRGBA] = [:]
        for name in names { colors[name] = ThemeRGBA(r: 0.5, g: 0.5, b: 0.5) }
        for syntax in ["syntax.keyword", "syntax.comment", "syntax.string"] { colors[syntax] = ThemeRGBA(r: 0.5, g: 0.5, b: 0.5) }
        let grey = ThemeRGBA(r: 0.5, g: 0.5, b: 0.5)
        for appearance in [ThemeAppearance.dark, .light] {
            // Everything is the same grey, so every pair fails and shows up as a finding.
            let theme = ResolvedTheme(id: "t", name: "t", appearance: appearance, colors: colors, sessionColors: Array(repeating: grey, count: 6))
            func key(_ fg: String, _ layers: [String], _ minimum: Double) -> String {
                let foreground = fg.hasPrefix("syntax.") ? "syntax.*" : fg
                let normal = foreground.hasPrefix("sessionColors[") ? "sessionColors[*]" : foreground
                return "\(normal)|\(layers.joined(separator: ">"))|\(minimum)"
            }
            let found = Set(ThemeContrast.findings(theme).map { key($0.foreground, $0.layers, $0.minimum) })
            let described = Set(ThemeContrast.rules.flatMap(\.pairs).map { key($0.foreground, $0.layers, $0.minimum) })
            #expect(found.subtracting(described).isEmpty, "checked but not described (\(appearance)): \(found.subtracting(described))")
            #expect(described.subtracting(found).isEmpty, "described but not checked (\(appearance)): \(described.subtracting(found))")
        }
    }
}
