import AlloyCore
import Foundation

/// The files of the `alloy-theme` skill, as `[relative path: contents]`. One source feeds both the installer behind
/// Settings and the tracked hand-install copy in `docs/skills/alloy-theme` (a test keeps them equal).
///
/// To regenerate the docs copy after changing anything here:
/// `ALLOY_WRITE_SKILL_DOCS=1 swift test --filter docsCopyMatchesGeneratedSkill`
public enum ThemeSkill {
    /// The themes folder the tracked docs copy names; the installer passes the real path instead.
    public static let docsThemesFolder = "~/Library/Application Support/Alloy/Themes"

    public static func files(themesFolder: String) -> [String: String] {
        var files: [String: String] = [
            "SKILL.md": skillText(themesFolder: themesFolder),
            "reference/slots.md": slotsText(),
        ]
        let library = ThemeLibrary(builtIns: BuiltInThemes.all)
        for entry in BuiltInThemes.all {
            guard let resolved = library.resolve(entry.id), let json = referenceJSON(resolved) else { continue }
            files["reference/\(entry.id).json"] = json
        }
        return files
    }

    /// A built-in with every slot resolved, in the theme file format.
    private static func referenceJSON(_ theme: ResolvedTheme) -> String? {
        let file = ThemeFile(name: theme.name, appearance: theme.appearance, colors: theme.colors,
                             sessionColors: theme.sessionColors.isEmpty ? nil : theme.sessionColors)
        guard let data = try? file.encoded() else { return nil }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func slotsText() -> String {
        var lines = [
            "# Theme slots",
            "",
            "Every colour slot a theme file can set under `colors`, in file order, with what it colours. The values are",
            "`#RRGGBB` or `#RRGGBBAA`. A slot a theme leaves out comes from its `base`.",
            "",
        ]
        for slot in ThemeSlots.all { lines.append("- `\(slot.name)`: \(slot.purpose)") }
        lines.append("")
        lines.append("`sessionColors` is a separate list of 6 to 12 colours, one per session row in the sidebar.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// One bullet per `ThemeContrast.rules` entry, so the skill never drifts from the app's own check.
    private static func contrastList() -> String {
        func ratio(_ value: Double) -> String { value == value.rounded() ? "\(Int(value)):1" : "\(value):1" }
        return ThemeContrast.rules.map { rule in
            let fgs = rule.foregrounds.map { "`\($0)`" }.joined(separator: ", ")
            let bgs = rule.backgrounds.map { "`" + $0.joined(separator: "` over `") + "`" }.joined(separator: ", ")
            return "   - \(fgs) on \(bgs): \(ratio(rule.minimum))" + (rule.note.map { " (\($0))" } ?? "")
        }.joined(separator: "\n")
    }

    private static func skillText(themesFolder: String) -> String {
        """
        ---
        name: alloy-theme
        description: "Make or edit an Alloy colour theme. Ask about taste, draft a theme file from a built-in base, check contrast and save it for Alloy's Settings."
        ---

        # Making an Alloy theme

        Alloy is a code editor. A theme is a JSON file that colours the whole app. This skill works in two modes; pick the
        one that matches your session.

        ## In an Alloy theme session

        Use this mode when the `mcp__alloy__theme_*` tools are available (Alloy starts such a session with `/theme`).

        \(ThemeGuidance.text)

        ## Anywhere else

        Use this mode when there are no `mcp__alloy__theme_*` tools. You write the theme file yourself, straight into
        Alloy's themes folder:

        `\(themesFolder)`

        1. Ask the user about taste (mood, light or dark, contrast, colours they love or avoid) before drafting, and
           whenever a choice is unclear; do not guess.
        2. Pick the closest built-in as `base`. Each one is in `reference/<id>.json` with every slot filled in:
           `dracula`, `alloy-dark`, `alloy-light`, `solarized-dark`, `solarized-light`, `one-dark`.
           `reference/slots.md` lists every slot and what it colours.
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

        ## The file format

        A theme is a JSON file in the themes folder (`\(themesFolder)`):

        ```json
        {
          "name": "Warm Paper",
          "appearance": "light",
          "base": "solarized-light",
          "author": "You",
          "credit": "optional",
          "colors": { "chatFill": "#FFF8E7", "accent": "#B5651D" },
          "sessionColors": ["#B5651D", "#2E7D32", "#1565C0", "#6A1B9A", "#C62828", "#00838F"],
          "style": { "gutter": 6, "cornerRadius": 10, "islandOpacity": 0.7, "controlOpacity": 0.6, "controlBlur": "heavy", "pillButtons": true }
        }
        ```

        - `name` and `appearance` (`dark` or `light`) are required.
        - `base` is a built-in id (`dracula`, `alloy-dark`, `alloy-light`, `solarized-dark`, `solarized-light`,
          `one-dark`) or another user theme's file name without `.json`. Slots the file leaves out come from the base.
        - `colors` maps slot names to `#RRGGBB` or `#RRGGBBAA`. `reference/slots.md` lists every slot and what it colours.
        - `sessionColors` is 6 to 12 colours.
        - `style` is optional and sets the layout and glass look; a key left out comes from the base. `gutter` 0 to 16,
          `cornerRadius` 0 to 20, `islandOpacity` and `controlOpacity` fractions 0.40 to 1.0, `controlBlur` `light`,
          `medium` or `heavy`, `pillButtons` true or false. `theme_slots` lists the keys with ranges.
        - Keep text readable: 4.5:1 for text, 3:1 for glyphs and outlines.
        """ + "\n"
    }
}
