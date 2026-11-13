import MetalUI

// App palette tokens (docs/mockups/chat-detail.html for the dark values). Each is a `ThemeColorKey`:
// one value per scheme through `Color(light:dark:)`, read anywhere a colour goes.

struct ThinkingTint: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xEEE7FB), dark: Color(hex: 0x2A2340))
}
struct ReadTint: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xDFF1F8), dark: Color(hex: 0x17303C))
}
struct ShellTint: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xFAF0D6), dark: Color(hex: 0x3A2D14))
}
struct EditAddTint: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xE0F3E4), dark: Color(hex: 0x1C3324))
}
struct EditRemoveTint: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xF9E1E3), dark: Color(hex: 0x3A1F22))
}
/// The code panel's diff rows reuse the chat's edit tints.
struct AddedRowTint: ThemeColorKey {
    static let defaultValue = EditAddTint.defaultValue
}
struct RemovedRowTint: ThemeColorKey {
    static let defaultValue = EditRemoveTint.defaultValue
}
struct ErrorTint: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xF8DADE), dark: Color(hex: 0x3A1A1E))
}
struct WarningTint: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xFBEFD3), dark: Color(hex: 0x3B2F17))
}
struct QuestionTint: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xE5E7FB), dark: Color(hex: 0x23264A))
}
struct PlanTint: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xECE8FB), dark: Color(hex: 0x2A2750))
}
struct CommandTint: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xE9ECEF), dark: Color(hex: 0x262A31))
}
struct WebTint: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xDDEBFB), dark: Color(hex: 0x172A44))
}
struct ThinkingInk: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x6B46C1), dark: Color(hex: 0xB79BF5))
}
struct ReadInk: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x0E7C86), dark: Color(hex: 0x4FC3CF))
}
struct ShellInk: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x9A6700), dark: Color(hex: 0xE3B341))
}
struct EditInk: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x1A7F37), dark: Color(hex: 0x56D364))
}
struct WebInk: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x0969DA), dark: Color(hex: 0x58A6FF))
}
struct LinkInk: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x0757B8), dark: Color(hex: 0x58A6FF))
}
struct QuestionInk: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x4338CA), dark: Color(hex: 0x9AA5FF))
}
struct PlanInk: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x5B50D6), dark: Color(hex: 0xA5A0FF))
}
struct ErrorInk: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xB81D28), dark: Color(hex: 0xFF7B72))
}
struct WarningInk: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x875A00), dark: Color(hex: 0xE3B341))
}
struct SidebarFillKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xEFF0F3), dark: Color(hex: 0x1D2027))
}
struct ChatFillKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xFAFAFB), dark: Color(hex: 0x16181D))
}
struct PanelFillKey: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xF4F5F7), dark: Color(hex: 0x1A1D23))
}
struct MarkdownCodeFill: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xECEEF2), dark: Color(hex: 0x20242B))
}
struct MarkdownQuoteBar: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xC5C9D1), dark: Color(hex: 0x3A3F4A))
}
struct MarkdownRule: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xD6D9DF), dark: Color(hex: 0x2C313A))
}
struct UserAuthorInk: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x5F6672), dark: Color(hex: 0xC9CCD3))
}
struct OutsideAuthorInk: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x7B808B), dark: Color(hex: 0x6B707A))
}

/// Secondary text and glyphs. Replaces MetalUI's `.secondary` (textPrimary at 0.588 light / 0.648 dark), which falls under
/// 4.5:1 on several tints and on the selection fill. Held to 4.5:1 on every fill the views draw it on (`ContrastAuditTests`).
struct MutedInk: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x4E545F), dark: Color(hex: 0xC2C8D3))
}
/// The fill of the selected session row, given to the sidebar's `List` as its tint (MetalUI draws the selection in the
/// tint, else the accent). Pale in light and deep in dark, so primary and muted text and the session dots all read on it.
struct SessionSelectionFill: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xDCE7FA), dark: Color(hex: 0x263B5E))
}
/// The 1 pt border of the composer box: 3:1 on its fill (WCAG 1.4.11), unlike the hairline `separator`.
struct ControlBorder: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x8A8F99), dark: Color(hex: 0x6B7385))
}
/// The code view's selection: opaque, so syntax colours keep 4.5:1 on it (MetalUI's default is the accent at 0.3).
struct CodeSelectionFill: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xDDE8FC), dark: Color(hex: 0x26406B))
}
/// The code view's find highlights: opaque so the text reads on them in both schemes.
struct FindMatchFill: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xFFF1C0), dark: Color(hex: 0x3A3217))
}
struct CurrentFindMatchFill: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xFFDD9E), dark: Color(hex: 0x4D3E12))
}
/// Diagnostic marks in the code view: the gutter bar, a tint over the range (at `diagnosticTintAlpha`) and the message row.
struct DiagnosticErrorKey: ThemeColorKey {
    static let defaultValue = ErrorInk.defaultValue
}
struct DiagnosticWarningKey: ThemeColorKey {
    static let defaultValue = WarningInk.defaultValue
}
struct DiagnosticInfoKey: ThemeColorKey {
    static let defaultValue = LinkInk.defaultValue
}

/// Session hues. Dark values from the mockup; light variants darkened to at least 3:1 on the light sidebar fill.
struct SessionColor1: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x1F72D6), dark: Color(hex: 0x5AA9FF))
}
struct SessionColor2: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xB85F00), dark: Color(hex: 0xF2A65A))
}
struct SessionColor3: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x2E7D32), dark: Color(hex: 0x8BD17C))
}
struct SessionColor4: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x7A4FD6), dark: Color(hex: 0xC3A8FF))
}
struct SessionColor5: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xC2307E), dark: Color(hex: 0xF08FC0))
}
struct SessionColor6: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x00796F), dark: Color(hex: 0x5FD4C8))
}
struct SessionColor7: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0x8A7400), dark: Color(hex: 0xE6D35A))
}
struct SessionColor8: ThemeColorKey {
    static let defaultValue = Color(light: Color(hex: 0xC62F3B), dark: Color(hex: 0xF07178))
}
struct SessionColor9: ThemeColorKey { static let defaultValue = SessionColor1.defaultValue }
struct SessionColor10: ThemeColorKey { static let defaultValue = SessionColor2.defaultValue }
struct SessionColor11: ThemeColorKey { static let defaultValue = SessionColor3.defaultValue }
struct SessionColor12: ThemeColorKey { static let defaultValue = SessionColor4.defaultValue }

/// Opacity of the background that marks the text one author wrote on a line more than one author wrote on.
let authorRunAlpha = 0.28
/// Opacity of the diagnostic colour as a tint over the text and message rows of a problem.
let diagnosticTintAlpha = 0.22

extension Color {
    static let thinkingTint = Color(ThinkingTint.self)
    static let readTint = Color(ReadTint.self)
    static let shellTint = Color(ShellTint.self)
    static let editAddTint = Color(EditAddTint.self)
    static let editRemoveTint = Color(EditRemoveTint.self)
    static let addedRowTint = Color(AddedRowTint.self)
    static let removedRowTint = Color(RemovedRowTint.self)
    static let errorTint = Color(ErrorTint.self)
    static let warningTint = Color(WarningTint.self)
    static let questionTint = Color(QuestionTint.self)
    static let planTint = Color(PlanTint.self)
    static let commandTint = Color(CommandTint.self)
    static let webTint = Color(WebTint.self)
    static let thinkingInk = Color(ThinkingInk.self)
    static let readInk = Color(ReadInk.self)
    static let shellInk = Color(ShellInk.self)
    static let editInk = Color(EditInk.self)
    static let webInk = Color(WebInk.self)
    static let linkInk = Color(LinkInk.self)
    static let questionInk = Color(QuestionInk.self)
    static let planInk = Color(PlanInk.self)
    static let errorInk = Color(ErrorInk.self)
    static let warningInk = Color(WarningInk.self)
    static let sidebarFill = Color(SidebarFillKey.self)
    static let chatFill = Color(ChatFillKey.self)
    static let panelFill = Color(PanelFillKey.self)
    static let markdownCodeFill = Color(MarkdownCodeFill.self)
    static let markdownQuoteBar = Color(MarkdownQuoteBar.self)
    static let markdownRule = Color(MarkdownRule.self)
    /// The dot for edits made by the user in Alloy.
    static let userAuthor = Color(UserAuthorInk.self)
    /// The dot for edits made outside Alloy.
    static let outsideAuthor = Color(OutsideAuthorInk.self)
    static let mutedInk = Color(MutedInk.self)
    /// MetalUI's own secondary text level (`Theme.textSecondary`), for the `textSecondary` theme slot only.
    static let metalUISecondary = Color.secondary
    /// MetalUI's tertiary text level as its default derivation (`textPrimary` at 0.306), for the `textTertiary` slot only.
    static let metalUITertiary = Color.primary.opacity(0.306)
    static let sessionSelection = Color(SessionSelectionFill.self)
    static let controlBorder = Color(ControlBorder.self)
    /// The 1 px outline of the selected segment in a segmented picker (MetalUI `SegmentedThumbEdge`).
    static let pickerThumbEdge = Color(SegmentedThumbEdge.self)
    static let codeSelectionFill = Color(CodeSelectionFill.self)
    static let findMatchFill = Color(FindMatchFill.self)
    static let currentFindMatchFill = Color(CurrentFindMatchFill.self)
    static let diagnosticError = Color(DiagnosticErrorKey.self)
    static let diagnosticWarning = Color(DiagnosticWarningKey.self)
    static let diagnosticInfo = Color(DiagnosticInfoKey.self)

    /// One of twelve session hues (`SessionColor1…12`); `index` is taken mod 12 (negative indices wrap too). Keys 9-12
    /// repeat 1-4 until a theme sets them.
    static func sessionColor(_ index: Int) -> Color {
        sessionColors[((index % 12) + 12) % 12]
    }

    private static let sessionColors: [Color] = [
        Color(SessionColor1.self), Color(SessionColor2.self), Color(SessionColor3.self), Color(SessionColor4.self),
        Color(SessionColor5.self), Color(SessionColor6.self), Color(SessionColor7.self), Color(SessionColor8.self),
        Color(SessionColor9.self), Color(SessionColor10.self), Color(SessionColor11.self), Color(SessionColor12.self),
    ]
}

extension CodeTheme {
    /// MetalUI's default code theme with the colours that fail 4.5:1 replaced: selection, line numbers and the find highlights.
    static let alloy = CodeTheme(selection: .codeSelectionFill, gutterForeground: .mutedInk, findMatch: .findMatchFill, currentFindMatch: .currentFindMatchFill)
}
