/// What a theme session is told when it starts, appended to the CLI's system prompt.
public enum ThemeGuidance {
    public static let text = "This session makes an Alloy theme with the user. A theme is a JSON file: name, appearance (dark or light), base (a theme it inherits from), author, optional credit, colors (slot name to #RRGGBB or #RRGGBBAA) and optional sessionColors (6 to 12). Slots it leaves out come from the base. Ask the user about taste (mood, light or dark, contrast, colours they love or avoid) before drafting, and whenever a choice is unclear; do not guess. Work in this order: call mcp__alloy__theme_slots to learn the slots and what each colours; call mcp__alloy__theme_read on the closest existing theme and use it as the base; draft only the slots you change; call mcp__alloy__theme_preview so the user sees the draft on the whole app; fix every pair the preview or mcp__alloy__theme_check reports below its minimum, then preview again; call mcp__alloy__theme_save with a name. Saving never switches themes: tell the user to choose Keep in the preview bar or pick the theme in Settings."

    /// The same instructions for agents that are not Claude: tools by their short names, as `Guidance` names Alloy's
    /// other tools for them.
    public static let acpText = text.replacingOccurrences(of: "mcp__alloy__", with: "")

    /// What to do when Alloy's theme tools cannot be used: write the theme file straight into the themes folder.
    /// The skill's "Anywhere else" section is this body.
    public static func fileModeBody(themesFolder: String, referenceFiles: Bool) -> String {
        let pick = referenceFiles
            ? """
              2. Pick the closest built-in as `base`. Each one is in `reference/<id>.json` with every slot filled in:
                 `dracula`, `alloy-dark`, `alloy-light`, `solarized-dark`, `solarized-light`, `one-dark`.
                 `reference/slots.md` lists every slot and what it colours, and the optional `terminal.*` tokens (the
                 terminal derives them from the editor slots when a theme leaves them out).
              """
            : """
              2. Pick the closest built-in as `base`: `dracula`, `alloy-dark`, `alloy-light`, `solarized-dark`,
                 `solarized-light` or `one-dark`. A theme that sets `base` and only the slots it changes is enough.
              """
        return """
        `\(themesFolder)`

        1. Ask the user about taste (mood, light or dark, contrast, colours they love or avoid) before drafting, and
           whenever a choice is unclear; do not guess.
        \(pick)
        3. Write only the slots you change under `colors`; the rest come from the base.
        4. Name it for what it is, never with a built-in's name (Dracula, Alloy Dark, Alloy Light, Solarized Dark,
           Solarized Light, One Dark) as the theme name or the file name. Save it as
           `\(themesFolder)/<slug>.json`, where the slug is the theme name in lowercase with dashes.
           Never overwrite an existing file. If the name is taken, pick a "<name> 2" style name (and slug) instead.
           Create the folder if it is missing.
        5. Check contrast yourself with WCAG 2.1 (contrast ratio = (L1 + 0.05) / (L2 + 0.05), L from linearised sRGB).
           Text pairs need 4.5:1; UI and glyph pairs need 3:1. Composite a translucent colour over what is under it
           first. Layers are listed bottom first: "`surface` over `codeSelectionFill`" means codeSelectionFill is drawn on
           top of surface, so composite them and measure against the result. Check every pair below, using the
           resolved values (the file's own plus the base's):
        \(contrastList())
           Fix every pair under its minimum before telling the user it is ready.
        6. Tell the user to pick the theme in Alloy's Settings. Alloy re-checks contrast itself and warns before
           activating a theme that falls short.

        Never edit Alloy's `settings.json` or its built-in themes. Saving a file never switches the theme.
        """
    }

    /// The prompt for a theme session whose agent cannot use Alloy's theme tools.
    public static func fileModeText(themesFolder: String) -> String {
        let intro = text.components(separatedBy: " Work in this order:")[0]
        return intro + " Alloy's theme tools are not available, so write the theme file yourself, straight into Alloy's "
            + "themes folder:\n\n" + fileModeBody(themesFolder: themesFolder, referenceFiles: false)
    }

    /// One bullet per `ThemeContrast.rules` entry, so the guidance never drifts from the app's own check.
    static func contrastList() -> String {
        func ratio(_ value: Double) -> String { value == value.rounded() ? "\(Int(value)):1" : "\(value):1" }
        return ThemeContrast.rules.map { rule in
            let fgs = rule.foregrounds.map { "`\($0)`" }.joined(separator: ", ")
            let bgs = rule.backgrounds.map { "`" + $0.joined(separator: "` over `") + "`" }.joined(separator: ", ")
            return "   - \(fgs) on \(bgs): \(ratio(rule.minimum))" + (rule.note.map { " (\($0))" } ?? "")
        }.joined(separator: "\n")
    }
}
