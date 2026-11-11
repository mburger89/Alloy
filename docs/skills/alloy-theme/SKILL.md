---
name: alloy-theme
description: Make an Alloy colour theme with the user: ask about taste, draft a theme file, preview it live and save it.
---

# Making an Alloy theme

Alloy sessions started with `/theme` already get this guidance and the five theme tools. This file is the same workflow
for use elsewhere. It needs a session that can call Alloy's `mcp__alloy__theme_*` tools.

## Workflow

This session makes an Alloy theme with the user. A theme is a JSON file: name, appearance (dark or light), base (a theme it inherits from), author, optional credit, colors (slot name to #RRGGBB or #RRGGBBAA) and optional sessionColors (6 to 12). Slots it leaves out come from the base. Ask the user about taste (mood, light or dark, contrast, colours they love or avoid) before drafting, and whenever a choice is unclear; do not guess. Work in this order: call mcp__alloy__theme_slots to learn the slots and what each colours; call mcp__alloy__theme_read on the closest existing theme and use it as the base; draft only the slots you change; call mcp__alloy__theme_preview so the user sees the draft on the whole app; fix every pair the preview or mcp__alloy__theme_check reports below its minimum, then preview again; call mcp__alloy__theme_save with a name. Saving never switches themes: tell the user to choose Keep in the preview bar or pick the theme in Settings.

## The file format

A theme is a JSON file in the themes folder (`Alloy/Themes` inside Alloy's application support folder):

```json
{
  "name": "Warm Paper",
  "appearance": "light",
  "base": "solarized-light",
  "author": "You",
  "credit": "optional",
  "colors": { "chatFill": "#FFF8E7", "accent": "#B5651D" },
  "sessionColors": ["#B5651D", "#2E7D32", "#1565C0", "#6A1B9A", "#C62828", "#00838F"]
}
```

- `name` and `appearance` (`dark` or `light`) are required.
- `base` is a built-in id (`dracula`, `alloy-dark`, `alloy-light`, `solarized-dark`, `solarized-light`, `one-dark`) or
  another user theme's file name. Slots the file leaves out come from the base.
- `colors` maps slot names to `#RRGGBB` or `#RRGGBBAA`. Call `theme_slots` for every slot and what it colours.
- `sessionColors` is 6 to 12 colours.
- Keep text readable: `theme_check` reports every pair below its minimum (4.5:1 for text, 3:1 for glyphs).

## Installing this skill

Alloy never installs this file. To use it, copy this folder (`alloy-theme`) into your own skills directory yourself.
