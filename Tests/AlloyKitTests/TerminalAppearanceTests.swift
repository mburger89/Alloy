@testable import AlloyCore
@testable import AlloyKit
import MetalUI
import MetalUITerminalUI
import Testing

@Suite struct TerminalAppearanceTests {
    private let red = ThemeRGBA(r: 1, g: 0, b: 0)
    private let blue = ThemeRGBA(r: 0, g: 0, b: 1)

    private func make(_ colors: [String: ThemeRGBA] = [:], _ appearance: ThemeAppearance = .dark,
                      _ settings: TerminalSettings = TerminalSettings()) -> TerminalAppearance {
        TerminalAppearance.make(colors: colors, appearance: appearance, settings: settings)
    }

    @Test func explicitTokensWin() {
        let a = make(["terminal.background": red, "terminal.ansi1": blue])
        #expect(a.palette.background == Color(red.hsla))
        #expect(a.palette.ansi[1] == Color(blue.hsla))
    }

    @Test func missingTokensFallBackToEditorSlots() {
        let text = ThemeRGBA(r: 0.2, g: 0.4, b: 0.6)
        let a = make(["textPrimary": text])
        #expect(a.palette.foreground == Color(text.hsla))
        #expect(a.palette.ansi.count == 16)
    }

    @Test func backgroundIsOpaque() {
        let a = make(["terminal.background": ThemeRGBA(r: 1, g: 0, b: 0, a: 0.5)])
        #expect(a.palette.background == Color(red.hsla))
    }

    @Test func selectionIsTranslucent() {
        #expect(make(["terminal.selection": blue]).palette.selection == Color(ThemeRGBA(r: 0, g: 0, b: 1, a: 0.4).hsla))
        let faint = ThemeRGBA(r: 0, g: 0, b: 1, a: 0.2)
        #expect(make(["terminal.selection": faint]).palette.selection == Color(faint.hsla))
    }

    @Test func cursorTextIsTheBackground() {
        let a = make(["terminal.background": red])
        #expect(a.palette.cursorText == a.palette.background)
    }

    @Test func boldIsBrightIsFalse() {
        #expect(make().palette.boldIsBright == false)
    }

    @Test func fontSizeFollowsSettingsElseDefault() {
        #expect(make().fontSize == 13)
        var s = TerminalSettings()
        s.fontSize = 15
        #expect(make([:], .dark, s).fontSize == 15)
    }

    @Test func blinkAndMetaPassThrough() {
        var s = TerminalSettings()
        s.cursorBlink = true
        s.optionAsMeta = true
        let a = make([:], .dark, s)
        #expect(a.cursorBlink && a.optionAsMeta)
        s.cursorBlink = false
        s.optionAsMeta = false
        let b = make([:], .dark, s)
        #expect(!b.cursorBlink && !b.optionAsMeta)
    }

    @Test func equalInputsAreEqual() {
        // swiftlint:disable:next identical_operands - two separately built values must compare equal (Equatable check)
        #expect(make(["terminal.ansi2": red]) == make(["terminal.ansi2": red]))
        #expect(make(["terminal.ansi2": red]) != make(["terminal.ansi2": blue]))
    }
}
