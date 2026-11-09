import MetalUI

/// The colours of syntax tokens: a light and a dark value each, readable on `.panelFill`
/// (`F4F5F7` light, `1A1D23` dark) and on the Markdown code fill.
public struct SyntaxPalette: Sendable {
    public init() {}

    private func hex(_ t: SyntaxToken) -> (light: UInt32, dark: UInt32)? {
        switch t {
        case .keyword: (0xBF1D29, 0xFF8F88)
        case .string: (0x0A3069, 0xA5D6FF)
        case .comment: (0x59636E, 0xA8B0BA)
        case .number: (0x0550AE, 0x79C0FF)
        case .type: (0x953800, 0xFFA657)
        case .function: (0x6F3FC9, 0xD2A8FF)
        case .property: (0x0A6B8F, 0x56D4DD)
        case .constant: (0x0550AE, 0x79C0FF)
        case .builtin: (0x0B6B73, 0x4FC3CF)
        case .operator_: (0x57606A, 0xC9D1D9)
        case .punctuation: (0x59636E, 0xA8B0BA)
        case .attribute: (0x8A5A00, 0xE3B341)
        case .tag: (0x116329, 0x7EE787)
        case .heading: (0x0550AE, 0x79C0FF)
        case .link: (0x0858B8, 0x70B4FF)
        case .variable, .plain: nil
        }
    }

    /// The style of `token` in `scheme`; tokens that keep the text colour answer a style with no foreground.
    public func style(_ token: SyntaxToken, scheme: ColorScheme) -> CodeStyle {
        guard let pair = hex(token) else { return CodeStyle() }
        return CodeStyle(foreground: Color(hex: scheme == .dark ? pair.dark : pair.light))
    }

    /// A style whose colour follows the window's scheme at paint time (`Color(light:dark:)`), so one
    /// registration serves both.
    public func dynamicStyle(_ token: SyntaxToken) -> CodeStyle {
        guard let pair = hex(token) else { return CodeStyle() }
        return CodeStyle(foreground: Color(light: Color(hex: pair.light), dark: Color(hex: pair.dark)))
    }
}
