import Foundation

/// The optional `terminal.*` colour tokens a theme file can carry next to the editor slots. They are not part of
/// `ThemeSlots.all` (a theme need not set them) and are never installed into MetalUI's `Theme`.
public enum TerminalTokens {
    /// `terminal.background`, `terminal.foreground`, `terminal.cursor`, `terminal.selection`, then `terminal.ansi0` ... `terminal.ansi15`.
    public static let names: [String] =
        ["terminal.background", "terminal.foreground", "terminal.cursor", "terminal.selection"]
        + (0..<16).map { "terminal.ansi\($0)" }

    public static let purposes: [String: String] = {
        var out: [String: String] = [
            "terminal.background": "Terminal panel background. Falls back to `surface`.",
            "terminal.foreground": "Default terminal text. Falls back to `textPrimary`.",
            "terminal.cursor": "Terminal cursor. Falls back to `textPrimary`.",
            "terminal.selection": "Selected text in the terminal, drawn over the background. Falls back to `codeSelectionFill`.",
        ]
        let basic = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        let sources = ["`background`", "`errorInk`", "`syntax.string`", "`warningInk`", "`syntax.function`", "`syntax.keyword`",
                       "`syntax.type`", "`textPrimary` at reduced alpha"]
        for i in 0..<8 {
            out["terminal.ansi\(i)"] = "ANSI \(basic[i]). Falls back to \(sources[i])."
            out["terminal.ansi\(i + 8)"] = "ANSI bright \(basic[i]). Falls back to ANSI \(basic[i]) moved toward the foreground."
        }
        return out
    }()
}

/// The resolved terminal colours: explicit `terminal.*` tokens win, anything missing is derived from the editor palette.
public struct TerminalPalette: Equatable, Sendable {
    public var background: ThemeRGBA
    public var foreground: ThemeRGBA
    public var cursor: ThemeRGBA
    public var selection: ThemeRGBA
    /// Exactly 16 entries.
    public var ansi: [ThemeRGBA]

    /// How far a bright colour moves from its base toward the foreground.
    static let brightMix = 0.3
    /// Alpha of the derived ANSI white.
    static let whiteAlpha = 0.8

    public static func resolve(colors: [String: ThemeRGBA], appearance: ThemeAppearance) -> TerminalPalette {
        let black = ThemeRGBA(r: 0, g: 0, b: 0), white = ThemeRGBA(r: 1, g: 1, b: 1)
        let text = colors["textPrimary"] ?? (appearance == .dark ? white : black)
        let back = colors["background"] ?? (appearance == .dark ? black : white)
        func editor(_ name: String) -> ThemeRGBA { colors[name] ?? text }

        let background = colors["terminal.background"] ?? colors["surface"] ?? back
        let foreground = colors["terminal.foreground"] ?? text
        let cursor = colors["terminal.cursor"] ?? text
        let selection = colors["terminal.selection"] ?? colors["codeSelectionFill"] ?? text

        var dimmed = text
        dimmed.a *= whiteAlpha
        let base: [ThemeRGBA] = [
            back, editor("errorInk"), editor("syntax.string"), editor("warningInk"),
            editor("syntax.function"), editor("syntax.keyword"), editor("syntax.type"), dimmed,
        ]
        var ansi: [ThemeRGBA] = []
        for i in 0..<16 {
            if let explicit = colors["terminal.ansi\(i)"] {
                ansi.append(explicit)
            } else if i < 8 {
                ansi.append(base[i])
            } else {
                ansi.append(mix(base[i - 8], toward: foreground, brightMix))
            }
        }
        return TerminalPalette(background: background, foreground: foreground, cursor: cursor, selection: selection, ansi: ansi)
    }

    private static func mix(_ a: ThemeRGBA, toward b: ThemeRGBA, _ t: Double) -> ThemeRGBA {
        ThemeRGBA(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t, a: a.a + (b.a - a.a) * t)
    }
}
