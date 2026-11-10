import AlloyCore
import AlloyHighlight
import MetalUI

/// One colour a theme file can set: its name in the file, a one-line purpose (for the docs and tooling), the colour the
/// app draws it in, and how a resolved colour is installed into a MetalUI `Theme`.
public struct ThemeSlot: Sendable {
    public let name: String
    public let purpose: String
    let color: Color
    let apply: @Sendable (inout Theme, ThemeRGBA) -> Void
}

/// Every slot a theme file can set, in file order: MetalUI tokens, then Alloy's keys, then syntax colours.
public enum ThemeSlots {
    public static let all: [ThemeSlot] = tokens + keys + syntax

    private static let tokens: [ThemeSlot] = [
        ThemeSlot(name: "background", purpose: "The window background behind everything.", color: Color(ColorToken.background), apply: { theme, rgba in theme.background = rgba.hsla }),
        ThemeSlot(name: "surface", purpose: "Raised surfaces: the composer box and the code view.", color: Color(ColorToken.surface), apply: { theme, rgba in theme.surface = rgba.hsla }),
        ThemeSlot(name: "surfaceSecondary", purpose: "Secondary surfaces: segmented-picker tracks and unselected tabs.", color: Color(ColorToken.surfaceSecondary), apply: { theme, rgba in theme.surfaceSecondary = rgba.hsla }),
        ThemeSlot(name: "accent", purpose: "The accent: selection, focus, toggles and the sidebar plus button.", color: Color(ColorToken.accent), apply: { theme, rgba in theme.accent = rgba.hsla }),
        ThemeSlot(name: "separator", purpose: "Hairline separators between panes and rows.", color: Color(ColorToken.separator), apply: { theme, rgba in theme.separator = rgba.hsla }),
        ThemeSlot(name: "textPrimary", purpose: "Primary text everywhere; secondary levels are derived from it.", color: Color(ColorToken.textPrimary), apply: { theme, rgba in theme.textPrimary = rgba.hsla }),
        ThemeSlot(name: "textSecondary", purpose: "Secondary text drawn by MetalUI controls: placeholders, captions. Optional; derived from textPrimary when absent.", color: Color.metalUISecondary, apply: { theme, rgba in theme.textSecondary = rgba.hsla }),
        ThemeSlot(name: "textTertiary", purpose: "Tertiary text drawn by MetalUI controls. Optional; derived from textPrimary when absent.", color: Color.metalUITertiary, apply: { theme, rgba in theme.textTertiary = rgba.hsla }),
        ThemeSlot(name: "scrollIndicator", purpose: "The scroll indicator thumb (usually translucent).", color: Color(ColorToken.scrollIndicator), apply: { theme, rgba in theme.scrollIndicator = rgba.hsla }),
        ThemeSlot(name: "scrim", purpose: "The dimming behind modal presentations (usually translucent).", color: Color(ColorToken.scrim), apply: { theme, rgba in theme.scrim = rgba.hsla }),
    ]

    /// A slot backed by the palette key `K`; `also` is a second key that follows it (the code panel's diff row tints
    /// follow the chat's edit tints).
    private static func key<K: ThemeColorKey & SendableMetatype, A: ThemeColorKey & SendableMetatype>(_ name: String, _ key: K.Type, also: A.Type, _ purpose: String) -> ThemeSlot {
        ThemeSlot(name: name, purpose: purpose, color: Color(key), apply: { theme, rgba in
            let color = Color(rgba.hsla)
            theme[key] = color
            theme[A.self] = color
        })
    }

    private static func key<K: ThemeColorKey & SendableMetatype>(_ name: String, _ key: K.Type, _ purpose: String) -> ThemeSlot {
        ThemeSlot(name: name, purpose: purpose, color: Color(key), apply: { theme, rgba in theme[key] = Color(rgba.hsla) })
    }

    private static let keys: [ThemeSlot] = [
        key("thinkingTint", ThinkingTint.self, "Background of thinking blocks in the chat."),
        key("readTint", ReadTint.self, "Background of file-read blocks."),
        key("shellTint", ShellTint.self, "Background of shell command blocks."),
        key("editAddTint", EditAddTint.self, also: AddedRowTint.self, "Background of added lines in edit diffs and the code panel."),
        key("editRemoveTint", EditRemoveTint.self, also: RemovedRowTint.self, "Background of removed lines in edit diffs and the code panel."),
        key("errorTint", ErrorTint.self, "Background of error blocks."),
        key("warningTint", WarningTint.self, "Background of warning blocks and notices."),
        key("questionTint", QuestionTint.self, "Background of question cards."),
        key("planTint", PlanTint.self, "Background of plan cards."),
        key("commandTint", CommandTint.self, "Background of slash-command blocks and the selected suggestion."),
        key("webTint", WebTint.self, "Background of web fetch and search blocks."),
        key("thinkingInk", ThinkingInk.self, "Icon and accent colour of thinking blocks."),
        key("readInk", ReadInk.self, "Icon and accent colour of file-read blocks."),
        key("shellInk", ShellInk.self, "Icon and accent colour of shell blocks."),
        key("editInk", EditInk.self, "Icon and accent colour of edit blocks."),
        key("webInk", WebInk.self, "Icon and accent colour of web blocks."),
        key("linkInk", LinkInk.self, "Links in chat text and code."),
        key("questionInk", QuestionInk.self, "Icon and accent colour of question cards."),
        key("planInk", PlanInk.self, "Icon and accent colour of plan cards."),
        key("errorInk", ErrorInk.self, "Error text and icons."),
        key("warningInk", WarningInk.self, "Warning text and icons."),
        key("sidebarFill", SidebarFillKey.self, "Background of the sidebar and user messages."),
        key("chatFill", ChatFillKey.self, "Background of the chat column."),
        key("panelFill", PanelFillKey.self, "Background of the code panel, settings and suggestion lists."),
        key("markdownCodeFill", MarkdownCodeFill.self, "Background of Markdown code blocks."),
        key("markdownQuoteBar", MarkdownQuoteBar.self, "The bar beside Markdown block quotes."),
        key("markdownRule", MarkdownRule.self, "Markdown horizontal rules."),
        key("userAuthor", UserAuthorInk.self, "Marker for edits you made in Alloy."),
        key("outsideAuthor", OutsideAuthorInk.self, "Marker for edits made outside Alloy."),
        key("mutedInk", MutedInk.self, "Secondary text and glyphs; must read on every fill."),
        key("sessionSelection", SessionSelectionFill.self, "Fill of the selected session row."),
        key("controlBorder", ControlBorder.self, "Border of the composer box."),
        key("codeSelectionFill", CodeSelectionFill.self, "Selection fill in code views."),
        key("findMatchFill", FindMatchFill.self, "Highlight of find matches in code views."),
        key("currentFindMatchFill", CurrentFindMatchFill.self, "Highlight of the current find match."),
    ]

    private static let syntax: [ThemeSlot] = [
        ThemeSlot(name: "syntax.keyword", purpose: "Keywords.", color: SyntaxPalette.color(.keyword), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .keyword, in: &theme) }),
        ThemeSlot(name: "syntax.string", purpose: "String literals.", color: SyntaxPalette.color(.string), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .string, in: &theme) }),
        ThemeSlot(name: "syntax.comment", purpose: "Comments.", color: SyntaxPalette.color(.comment), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .comment, in: &theme) }),
        ThemeSlot(name: "syntax.number", purpose: "Numeric literals.", color: SyntaxPalette.color(.number), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .number, in: &theme) }),
        ThemeSlot(name: "syntax.type", purpose: "Type names.", color: SyntaxPalette.color(.type), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .type, in: &theme) }),
        ThemeSlot(name: "syntax.function", purpose: "Function and method names.", color: SyntaxPalette.color(.function), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .function, in: &theme) }),
        ThemeSlot(name: "syntax.property", purpose: "Properties, fields and parameters.", color: SyntaxPalette.color(.property), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .property, in: &theme) }),
        ThemeSlot(name: "syntax.constant", purpose: "Constants and booleans.", color: SyntaxPalette.color(.constant), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .constant, in: &theme) }),
        ThemeSlot(name: "syntax.builtin", purpose: "Built-in names.", color: SyntaxPalette.color(.builtin), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .builtin, in: &theme) }),
        ThemeSlot(name: "syntax.operator", purpose: "Operators.", color: SyntaxPalette.color(.operator_), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .operator_, in: &theme) }),
        ThemeSlot(name: "syntax.punctuation", purpose: "Punctuation and delimiters.", color: SyntaxPalette.color(.punctuation), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .punctuation, in: &theme) }),
        ThemeSlot(name: "syntax.attribute", purpose: "Attributes and decorators.", color: SyntaxPalette.color(.attribute), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .attribute, in: &theme) }),
        ThemeSlot(name: "syntax.tag", purpose: "Markup tags.", color: SyntaxPalette.color(.tag), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .tag, in: &theme) }),
        ThemeSlot(name: "syntax.heading", purpose: "Markdown headings.", color: SyntaxPalette.color(.heading), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .heading, in: &theme) }),
        ThemeSlot(name: "syntax.link", purpose: "Links in code and Markdown.", color: SyntaxPalette.color(.link), apply: { theme, rgba in SyntaxPalette.setColor(Color(rgba.hsla), for: .link, in: &theme) }),
    ]
}
