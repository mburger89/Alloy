import MetalUI

// Syntax colours are palette keys, one per token, so a theme can set each (`Theme[Key.self] = colour`). The defaults are
// the light/dark values Alloy shipped with; each is readable on `.panelFill` (`F4F5F7` light, `1A1D23` dark) and on the
// Markdown code fill. This file holds the only colour literals in AlloyHighlight (`ThemeGuardTests` allow-lists it).

struct SyntaxKeywordKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xBF1D29), dark: Color(hex: 0xFF8F88))
}
struct SyntaxStringKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x0A3069), dark: Color(hex: 0xA5D6FF))
}
struct SyntaxCommentKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x59636E), dark: Color(hex: 0xA8B0BA))
}
struct SyntaxNumberKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x0550AE), dark: Color(hex: 0x79C0FF))
}
struct SyntaxTypeKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x953800), dark: Color(hex: 0xFFA657))
}
struct SyntaxFunctionKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x6F3FC9), dark: Color(hex: 0xD2A8FF))
}
struct SyntaxPropertyKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x0A6B8F), dark: Color(hex: 0x56D4DD))
}
struct SyntaxConstantKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x0550AE), dark: Color(hex: 0x79C0FF))
}
struct SyntaxBuiltinKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x0B6B73), dark: Color(hex: 0x4FC3CF))
}
struct SyntaxOperatorKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x57606A), dark: Color(hex: 0xC9D1D9))
}
struct SyntaxPunctuationKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x59636E), dark: Color(hex: 0xA8B0BA))
}
struct SyntaxAttributeKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x8A5A00), dark: Color(hex: 0xE3B341))
}
struct SyntaxTagKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x116329), dark: Color(hex: 0x7EE787))
}
struct SyntaxHeadingKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x0550AE), dark: Color(hex: 0x79C0FF))
}
struct SyntaxLinkKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x0858B8), dark: Color(hex: 0x70B4FF))
}

/// The colours of syntax tokens, read through the window's theme at paint time.
public struct SyntaxPalette: Sendable {
    public init() {}

    /// The colour `token` is drawn in. The tokens that keep the text colour (`variable`, `plain`) answer `textPrimary`.
    public static func color(_ token: SyntaxToken) -> Color {
        switch token {
        case .keyword: Color(SyntaxKeywordKey.self)
        case .string: Color(SyntaxStringKey.self)
        case .comment: Color(SyntaxCommentKey.self)
        case .number: Color(SyntaxNumberKey.self)
        case .type: Color(SyntaxTypeKey.self)
        case .function: Color(SyntaxFunctionKey.self)
        case .property: Color(SyntaxPropertyKey.self)
        case .constant: Color(SyntaxConstantKey.self)
        case .builtin: Color(SyntaxBuiltinKey.self)
        case .operator_: Color(SyntaxOperatorKey.self)
        case .punctuation: Color(SyntaxPunctuationKey.self)
        case .attribute: Color(SyntaxAttributeKey.self)
        case .tag: Color(SyntaxTagKey.self)
        case .heading: Color(SyntaxHeadingKey.self)
        case .link: Color(SyntaxLinkKey.self)
        case .variable, .plain: .textPrimary
        }
    }

    /// Sets `token`'s colour in `theme`. `variable` and `plain` follow `textPrimary` and have no key, so they are ignored.
    public static func setColor(_ color: Color, for token: SyntaxToken, in theme: inout Theme) {
        switch token {
        case .keyword: theme[SyntaxKeywordKey.self] = color
        case .string: theme[SyntaxStringKey.self] = color
        case .comment: theme[SyntaxCommentKey.self] = color
        case .number: theme[SyntaxNumberKey.self] = color
        case .type: theme[SyntaxTypeKey.self] = color
        case .function: theme[SyntaxFunctionKey.self] = color
        case .property: theme[SyntaxPropertyKey.self] = color
        case .constant: theme[SyntaxConstantKey.self] = color
        case .builtin: theme[SyntaxBuiltinKey.self] = color
        case .operator_: theme[SyntaxOperatorKey.self] = color
        case .punctuation: theme[SyntaxPunctuationKey.self] = color
        case .attribute: theme[SyntaxAttributeKey.self] = color
        case .tag: theme[SyntaxTagKey.self] = color
        case .heading: theme[SyntaxHeadingKey.self] = color
        case .link: theme[SyntaxLinkKey.self] = color
        case .variable, .plain: break
        }
    }

    /// A style whose colour is the token's key colour, resolved at paint time; tokens that keep the text colour answer a
    /// style with no foreground.
    public func dynamicStyle(_ token: SyntaxToken) -> CodeStyle {
        switch token {
        case .variable, .plain: CodeStyle()
        default: CodeStyle(foreground: Self.color(token))
        }
    }
}
