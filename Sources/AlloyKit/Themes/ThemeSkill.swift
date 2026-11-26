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
        lines.append("")
        lines.append("## Terminal tokens (optional)")
        lines.append("")
        lines.append("The integrated terminal reads these optional `colors` keys. A theme does not need to set them: any token left")
        lines.append("out is derived from the editor slots above, so every theme already works. Set them only to tune the terminal.")
        lines.append("")
        for name in TerminalTokens.names { lines.append("- `\(name)`: \(TerminalTokens.purposes[name] ?? "")") }
        return lines.joined(separator: "\n") + "\n"
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

        Use this mode when Alloy's theme tools (`theme_slots`, `theme_read`, `theme_check`, `theme_preview`,
        `theme_save`; Claude Code shows them as `mcp__alloy__theme_*`) are available (Alloy starts such a session with
        `/theme`).

        \(ThemeGuidance.acpText)

        ## Anywhere else

        Use this mode when Alloy's theme tools are not available. You write the theme file yourself, straight into
        Alloy's themes folder:

        \(ThemeGuidance.fileModeBody(themesFolder: themesFolder, referenceFiles: true))

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
          `medium` or `heavy`, `pillButtons` true or false, `backgroundGradient` true or false (a diagonal gradient from `windowBackground`
          towards `accent` behind the islands), `backgroundGradientStrength` 0 to 0.40 (default 0.18), `backgroundImage` (a file name
          or relative path of an image that sits in the themes folder next to the theme file; drawn cropped to fill behind the islands
          instead of the gradient; a missing file is ignored), `backgroundImageDim` 0 to 0.80 (default 0.30; how strongly `windowBackground`
          is laid over the image to keep text readable). `theme_slots` lists the keys with ranges.
        - Keep text readable: 4.5:1 for text, 3:1 for glyphs and outlines.
        """ + "\n"
    }
}
