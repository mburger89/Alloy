@testable import AlloyCore
import Foundation
import Testing

@Suite struct TerminalPaletteTests {
    private static let library = ThemeLibrary(builtIns: BuiltInThemes.all)

    @Test func tokenListHasTwentyNamesInOrder() {
        #expect(TerminalTokens.names.count == 20)
        #expect(Array(TerminalTokens.names.prefix(4)) == ["terminal.background", "terminal.foreground", "terminal.cursor", "terminal.selection"])
        #expect(TerminalTokens.names[4] == "terminal.ansi0")
        #expect(TerminalTokens.names[19] == "terminal.ansi15")
        for name in TerminalTokens.names { #expect(TerminalTokens.purposes[name] != nil, "\(name)") }
    }

    @Test func explicitTokensWinOverFallbacks() {
        let red = ThemeRGBA(r: 1, g: 0, b: 0)
        let colors: [String: ThemeRGBA] = [
            "terminal.background": red, "terminal.foreground": red, "terminal.cursor": red, "terminal.selection": red,
            "terminal.ansi1": red, "terminal.ansi9": red, "surface": ThemeRGBA(r: 0, g: 0, b: 0), "errorInk": ThemeRGBA(r: 0, g: 1, b: 0),
        ]
        let p = TerminalPalette.resolve(colors: colors, appearance: .dark)
        #expect(p.background == red && p.foreground == red && p.cursor == red && p.selection == red)
        #expect(p.ansi[1] == red && p.ansi[9] == red)
    }

    @Test func emptyColorsFallBackToEditorPalette() throws {
        let theme = try #require(Self.library.resolve("alloy-dark"))
        let p = TerminalPalette.resolve(colors: theme.colors, appearance: theme.appearance)
        #expect(p.background == theme.colors["surface"])
        #expect(p.foreground == theme.colors["textPrimary"])
        #expect(p.selection == theme.colors["codeSelectionFill"])
        #expect(p.ansi[1] == theme.colors["errorInk"])
        #expect(p.ansi[2] == theme.colors["syntax.string"])
        #expect(p.ansi[0] == theme.colors["background"])
        #expect(p.ansi[9] != p.ansi[1])
    }

    @Test func fallbackNeverMissesEvenWithBareColors() {
        for appearance in [ThemeAppearance.dark, .light] {
            let p = TerminalPalette.resolve(colors: [:], appearance: appearance)
            #expect(p.ansi.count == 16)
        }
    }

    @Test func everyBuiltInThemeResolvesWithFallbacksAndPassesContrast() {
        for theme in BuiltInThemes.all {
            let resolved = Self.library.resolve(theme.id)
            #expect(resolved != nil, "\(theme.id)")
            guard let resolved else { continue }
            let bad = ThemeContrast.findings(resolved).filter { $0.pair.contains("terminal.") }
            #expect(bad.isEmpty, "\(theme.id): \(bad)")
        }
    }
}
