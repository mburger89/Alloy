---
name: alloy-theme
description: "Make or edit an Alloy colour theme. Ask about taste, draft a theme file from a built-in base, check contrast and save it for Alloy's Settings."
---

# Making an Alloy theme

Alloy is a code editor. A theme is a JSON file that colours the whole app. This skill works in two modes; pick the
one that matches your session.

## In an Alloy theme session

Use this mode when the `mcp__alloy__theme_*` tools are available (Alloy starts such a session with `/theme`).

This session makes an Alloy theme with the user. A theme is a JSON file: name, appearance (dark or light), base (a theme it inherits from), author, optional credit, colors (slot name to #RRGGBB or #RRGGBBAA) and optional sessionColors (6 to 12). Slots it leaves out come from the base. Ask the user about taste (mood, light or dark, contrast, colours they love or avoid) before drafting, and whenever a choice is unclear; do not guess. Work in this order: call mcp__alloy__theme_slots to learn the slots and what each colours; call mcp__alloy__theme_read on the closest existing theme and use it as the base; draft only the slots you change; call mcp__alloy__theme_preview so the user sees the draft on the whole app; fix every pair the preview or mcp__alloy__theme_check reports below its minimum, then preview again; call mcp__alloy__theme_save with a name. Saving never switches themes: tell the user to choose Keep in the preview bar or pick the theme in Settings.

## Anywhere else

Use this mode when there are no `mcp__alloy__theme_*` tools. You write the theme file yourself, straight into
Alloy's themes folder:

`~/Library/Application Support/Alloy/Themes`

1. Ask the user about taste (mood, light or dark, contrast, colours they love or avoid) before drafting, and
   whenever a choice is unclear; do not guess.
2. Pick the closest built-in as `base`. Each one is in `reference/<id>.json` with every slot filled in:
   `dracula`, `alloy-dark`, `alloy-light`, `solarized-dark`, `solarized-light`, `one-dark`.
   `reference/slots.md` lists every slot and what it colours.
3. Write only the slots you change under `colors`; the rest come from the base.
4. Name it for what it is, never with a built-in's name (Dracula, Alloy Dark, Alloy Light, Solarized Dark,
   Solarized Light, One Dark) as the theme name or the file name. Save it as
   `~/Library/Application Support/Alloy/Themes/<slug>.json`, where the slug is the theme name in lowercase with dashes.
   Never overwrite an existing file. If the name is taken, pick a "<name> 2" style name (and slug) instead.
   Create the folder if it is missing.
5. Check contrast yourself with WCAG 2.1 (contrast ratio = (L1 + 0.05) / (L2 + 0.05), L from linearised sRGB).
   Text pairs need 4.5:1; UI and glyph pairs need 3:1. Composite a translucent colour over what is under it
   first. Layers are listed bottom first: "`surface` over `codeSelectionFill`" means codeSelectionFill is drawn on
   top of surface, so composite them and measure against the result. Check every pair below, using the
   resolved values (the file's own plus the base's):
   - `textPrimary`, `mutedInk`, `textSecondary` on `background`, `surface`, `sidebarFill`, `chatFill`, `panelFill`, `markdownCodeFill`: 4.5:1 (textSecondary not set: textPrimary at alpha 0.648 in a dark theme, 0.588 in a light one)
   - `textPrimary`, `textSecondary` on `surfaceSecondary`: 4.5:1
   - `textPrimary`, `mutedInk` on `thinkingTint`, `readTint`, `shellTint`, `editAddTint`, `editRemoveTint`, `errorTint`, `warningTint`, `questionTint`, `planTint`, `commandTint`, `webTint`: 4.5:1
   - `syntax.*` on `markdownCodeFill`, `surface`: 4.5:1 (except syntax.comment, which needs 3)
   - `syntax.comment` on `markdownCodeFill`, `surface`: 3:1
   - `syntax.*` on `editAddTint`, `editRemoveTint`, `surface` over `codeSelectionFill`: 3:1
   - `thinkingInk` on `thinkingTint`: 3:1
   - `readInk` on `readTint`: 3:1
   - `shellInk` on `shellTint`: 3:1
   - `editInk` on `editAddTint`: 3:1
   - `webInk` on `webTint`: 3:1
   - `questionInk` on `questionTint`: 3:1
   - `planInk` on `planTint`: 3:1
   - `errorInk` on `errorTint`, `panelFill`: 4.5:1
   - `warningInk` on `warningTint`: 4.5:1
   - `linkInk` on `chatFill`, `markdownCodeFill`: 4.5:1
   - `pickerThumbEdge` on `surfaceSecondary`, `surfaceSecondary` over `pickerThumb`: 3:1 (pickerThumb is the selected segment: surface in a light theme, textPrimary at alpha 0.18 over surfaceSecondary in a dark one)
   - `island text` on `windowBackground` over `islandFill`: 4.5:1 (island text is textPrimary; islandFill is drawn at the theme's island opacity over windowBackground, which is what chat, sidebar and code sit on; the pair is named "text on island")
   - `control text` on `islandFill` over `controlFill`: 4.5:1 (control text is textPrimary; controlFill is drawn at the theme's controlOpacity over islandFill; the pair is named "control text on control fill")
   - `sessionColors[*]` on `sidebarFill`: 3:1
   Fix every pair under its minimum before telling the user it is ready.
6. Tell the user to pick the theme in Alloy's Settings. Alloy re-checks contrast itself and warns before
   activating a theme that falls short.

Never edit Alloy's `settings.json` or its built-in themes. Saving a file never switches the theme.

## The file format

A theme is a JSON file in the themes folder (`~/Library/Application Support/Alloy/Themes`):

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
