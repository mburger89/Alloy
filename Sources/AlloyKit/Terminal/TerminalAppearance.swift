import AlloyCore
import MetalUI
import MetalUITerminalUI

/// How a terminal pane looks: MetalUI's palette from Alloy's `terminal.*` theme tokens (with their editor-slot
/// fallbacks), the font size and the cursor and meta flags from `TerminalSettings`. Pure and cheap to compare, so a
/// pane rebuilds only when the theme or the settings change.
struct TerminalAppearance: Equatable, Sendable {
    /// The selection colour's alpha ceiling: the selection is composited over the cell backgrounds.
    static let selectionAlpha = 0.4
    /// The size when the settings follow the editor and no editor size is given.
    static let defaultFontSize = 13.0

    var palette: MetalUITerminalUI.TerminalPalette
    var fontSize: Double
    var cursorBlink: Bool
    var optionAsMeta: Bool

    var font: Font { .system(size: fontSize, design: .monospaced) }

    static func make(colors: [String: ThemeRGBA], appearance: ThemeAppearance, settings: TerminalSettings) -> TerminalAppearance {
        let resolved = ThemeTerminalPalette.resolve(colors: colors, appearance: appearance)
        func color(_ rgba: ThemeRGBA) -> Color { Color(rgba.hsla) }
        var background = resolved.background
        background.a = 1
        var selection = resolved.selection
        selection.a = min(selection.a, selectionAlpha)
        let palette = MetalUITerminalUI.TerminalPalette(
            ansi: resolved.ansi.map(color), foreground: color(resolved.foreground), background: color(background),
            cursor: color(resolved.cursor), cursorText: color(background), selection: color(selection), boldIsBright: false)
        return TerminalAppearance(palette: palette, fontSize: settings.fontSize ?? defaultFontSize,
                                  cursorBlink: settings.cursorBlink, optionAsMeta: settings.optionAsMeta)
    }
}
