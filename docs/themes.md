# Themes

Alloy's colours all come from a theme. A theme is a small JSON file. Alloy ships six built-in themes and loads any
number of your own.

## Built-in themes

| Theme | Appearance | Source |
| --- | --- | --- |
| Dracula (default) | dark | Dracula Theme, MIT licence, draculatheme.com |
| Alloy Dark | dark | Alloy |
| Alloy Light | light | Alloy |
| Solarized Dark | dark | Solarized, MIT licence, Ethan Schoonover (ethanschoonover.com/solarized) |
| Solarized Light | light | Solarized, MIT licence, Ethan Schoonover (ethanschoonover.com/solarized) |
| One Dark | dark | One Dark, MIT licence, Atom's one-dark-syntax |

## Your own themes

Put `*.json` files in the user themes folder. Alloy watches it, so an edit applies live.

- `~/Library/Application Support/Alloy/Themes`
- or `$ALLOY_DATA_DIR/Alloy/Themes` when the `ALLOY_DATA_DIR` environment variable is set

A user theme's id is `user/<file name without .json>`.

## Theme file format

```json
{
  "name": "My Theme",
  "appearance": "dark",
  "base": "dracula",
  "author": "You",
  "credit": "Where the palette comes from (optional)",
  "colors": {
    "chatFill": "#282A36",
    "syntax.keyword": "#FF79C6",
    "scrim": "#0000006B"
  },
  "sessionColors": ["#BD93F9", "#FFB86C", "#50FA7B", "#FF79C6", "#8BE9FD", "#F1FA8C"]
}
```

- `name` and `appearance` (`dark` or `light`) are required.
- `base` names the theme to fall back on: a built-in id (`dracula`, `alloy-dark`, `alloy-light`, `solarized-dark`,
  `solarized-light`, `one-dark`) or another user theme's file name. Any slot the file leaves out comes from `base`. Without
  a `base`, Alloy uses `alloy-dark` or `alloy-light` by `appearance`; both define every slot. An unknown `base` falls
  back the same way, and a cycle or a chain deeper than 8 skips the theme.
- `author`, and `credit` (or `source`), are optional text.
- `colors` maps slot names to `#RRGGBB` or `#RRGGBBAA`. Unknown slot names are ignored.
- `sessionColors` is a list of 6 to 12 colours that replaces the base theme's list. Alloy has 12 session colour keys; key
  *n* takes `list[(n - 1) % count]`.

Keep text readable. The built-in themes are checked by the contrast audit in `ContrastAuditTests`, which renders each one
and tests every pair of colours the app draws in two tiers: 4.5:1 for text and 3:1 for glyphs, with 3:1 also allowed for
comments and for text on highlight fills. Alloy Dark and Alloy Light meet 4.5:1 throughout; see
[Contrast adjustments](#contrast-adjustments) for the tiers and what was changed in each built-in.

## Slots

Every slot name a theme file can set, with its purpose. MetalUI tokens come first, then Alloy's keys, then syntax colours.

| Slot | Purpose |
| --- | --- |
| `background` | The window background behind everything. |
| `surface` | Raised surfaces: the composer box and the code view. |
| `surfaceSecondary` | Secondary surfaces: segmented-picker tracks and unselected tabs. |
| `accent` | The accent: selection, focus, toggles and the sidebar plus button. |
| `separator` | Hairline separators between panes and rows. |
| `textPrimary` | Primary text everywhere; secondary levels are derived from it. |
| `textSecondary` | Secondary text drawn by MetalUI controls: placeholders, captions. Optional; derived from textPrimary when absent. |
| `textTertiary` | Tertiary text drawn by MetalUI controls. Optional; derived from textPrimary when absent. |
| `scrollIndicator` | The scroll indicator thumb (usually translucent). |
| `scrim` | The dimming behind modal presentations (usually translucent). |
| `thinkingTint` | Background of thinking blocks in the chat. |
| `readTint` | Background of file-read blocks. |
| `shellTint` | Background of shell command blocks. |
| `editAddTint` | Background of added lines in edit diffs and the code panel. |
| `editRemoveTint` | Background of removed lines in edit diffs and the code panel. |
| `errorTint` | Background of error blocks. |
| `warningTint` | Background of warning blocks and notices. |
| `questionTint` | Background of question cards. |
| `planTint` | Background of plan cards. |
| `commandTint` | Background of slash-command blocks and the selected suggestion. |
| `webTint` | Background of web fetch and search blocks. |
| `thinkingInk` | Icon and accent colour of thinking blocks. |
| `readInk` | Icon and accent colour of file-read blocks. |
| `shellInk` | Icon and accent colour of shell blocks. |
| `editInk` | Icon and accent colour of edit blocks. |
| `webInk` | Icon and accent colour of web blocks. |
| `linkInk` | Links in chat text and code. |
| `questionInk` | Icon and accent colour of question cards. |
| `planInk` | Icon and accent colour of plan cards. |
| `errorInk` | Error text and icons. |
| `warningInk` | Warning text and icons. |
| `sidebarFill` | Background of the sidebar and user messages. |
| `chatFill` | Background of the chat column. |
| `panelFill` | Background of the code panel, settings and suggestion lists. |
| `markdownCodeFill` | Background of Markdown code blocks. |
| `markdownQuoteBar` | The bar beside Markdown block quotes. |
| `markdownRule` | Markdown horizontal rules. |
| `userAuthor` | Marker for edits you made in Alloy. |
| `outsideAuthor` | Marker for edits made outside Alloy. |
| `mutedInk` | Secondary text and glyphs; must read on every fill. |
| `sessionSelection` | Fill of the selected session row. |
| `controlBorder` | Border of the composer box. |
| `codeSelectionFill` | Selection fill in code views. |
| `findMatchFill` | Highlight of find matches in code views. |
| `currentFindMatchFill` | Highlight of the current find match. |
| `syntax.keyword` | Keywords. |
| `syntax.string` | String literals. |
| `syntax.comment` | Comments. |
| `syntax.number` | Numeric literals. |
| `syntax.type` | Type names. |
| `syntax.function` | Function and method names. |
| `syntax.property` | Properties, fields and parameters. |
| `syntax.constant` | Constants and booleans. |
| `syntax.builtin` | Built-in names. |
| `syntax.operator` | Operators. |
| `syntax.punctuation` | Punctuation and delimiters. |
| `syntax.attribute` | Attributes and decorators. |
| `syntax.tag` | Markup tags. |
| `syntax.heading` | Markdown headings. |
| `syntax.link` | Links in code and Markdown. |

## Credits and licences

- **Dracula**: Dracula Theme by Zeno Rocha and contributors, MIT licence, https://draculatheme.com
- **Solarized**: Solarized by Ethan Schoonover, MIT licence, https://ethanschoonover.com/solarized
- **One Dark**: Atom's one-dark-syntax by the Atom team, MIT licence

Alloy Dark and Alloy Light are Alloy's own.

The menu shadow (`ColorToken.shadow`) is intentionally not a slot: a shadow is not a theme colour.

## Contrast adjustments

The built-ins use each palette's published colours wherever they pass the contrast audit, which renders every built-in
theme and checks every pair of colours the app draws. The audit has two tiers:

- 3:1 for comments (`syntax.comment`) on any background, and for text or syntax colours drawn on a highlight fill: find
  matches, the code selection, diff rows (added and removed lines), author-run highlights, the active file row in the sidebar and the selected session row, including its badges. (Badges and chips on ordinary rows stay at 4.5:1.)
- 4.5:1 for everything else: text and inks on the chat, panel, sidebar and code backgrounds, each ink on its own block
  tint, and every syntax colour other than comments on the code background. Glyphs keep their 3:1.

Where a published colour still failed its tier, only its lightness was changed (hue and saturation kept) until it passed.
Each change is `slot: published → used`; where an in-palette colour passed it was used instead of a lightness nudge and is marked `(in-palette: baseNN)`. Colours that are not in a palette (muted text, borders, selection and find fills,
panel and sidebar shades, author markers) were chosen to pass and are not listed. Block tints mix each ink into the chat
fill at 18% where the palette allows it, and lower (Solarized Dark 10%, Solarized Light 10%, One Dark 10%) where a stronger
tint would push a published ink or text colour under its minimum. Solarized follows its own design: base03 (dark) or base3 (light) are the content backgrounds of every surface, and base02 or base2 appear only in highlight fills (selection). Solarized Dark's base0 text is 4.75:1 on base03 but only about 3.95 to 4.27:1 on the block tints behind chat titles, which is why its `textPrimary` starts from base1 (lightened further, see its entry). Alloy Dark and Alloy Light needed no changes.

### Text levels

`textSecondary` and `textTertiary` are MetalUI's own secondary and tertiary text (placeholders, captions, Markdown code captions). Both are optional: a theme that leaves them out gets MetalUI's derivation from `textPrimary`. Every built-in sets both. Tertiary text is drawn nowhere that Alloy audits, so the tertiary values are the palettes' own muted colours and are not adjusted: Dracula comment #6272A4, Solarized Dark base01 #586E75, Solarized Light base1 #93A1A1, One Dark comment #5C6370; Alloy Dark and Alloy Light use #7B8294 and #7D838E. The text levels are ordered on `surface`: primary has a higher contrast ratio than secondary, and secondary than tertiary (enforced for every built-in). The unselected segmented-picker label, `textPrimary` on the track, is audited at 4.5:1 for every built-in. Secondary is audited at 4.5:1 on the background, surface, sidebar, chat, panel and Markdown code fills, and at 4.5:1 on the segmented-picker track and tab bar (`surfaceSecondary`, also under a hovered tab's 6% textPrimary wash), because MetalUI draws the unselected tab ink (label, close glyph, dirty dot) in `textSecondary` (MetalUI 0aec3e03). Alloy Dark and Alloy Light use their `mutedInk` (#C2C8D3, #4E545F) at 4.5:1 throughout, and the four adjustments are listed under Dracula, Solarized Dark, Solarized Light and One Dark.

### Dracula

- `questionInk`: #BD93F9 → #E2CFFC
- `textSecondary`: #6272A4 → #BEC5DA
- `errorInk`: #FF5555 → #FF8C8C
- `syntax.comment`: #6272A4 → #97A2C3
- `sessionColors[6]`: #FF5555 → #FF5D5D
- `sessionColors[7]`: #6272A4 → #8794BA

### Solarized Dark

- `textSecondary`: #839496 → #95A3A5 (base0 lightened until the unselected tab ink reads on a hovered tab)
- `questionInk`: #6C71C4 → #ACAFDE
- `errorInk`: #DC322F → #E77472
- `warningInk`: #B58900 → #BF9100
- `textPrimary`: #839496 → #9EAAAA (base1 lightened so it reads stronger than `textSecondary`: 6.28:1 against 5.76:1 on the page)
- `linkInk`: #268BD2 → #4EA3DF
- `syntax.comment`: #586E75 → #839496 (in-palette: base0)
- `syntax.number`: #D33682 → #DD639E
- `syntax.function`: #268BD2 → #3194DA
- `syntax.property`: #6C71C4 → #8589CE
- `syntax.constant`: #CB4B16 → #E96630
- `syntax.builtin`: #DC322F → #E56663
- `syntax.operator`: #6C71C4 → #8589CE
- `syntax.attribute`: #CB4B16 → #E96630
- `syntax.tag`: #268BD2 → #3194DA
- `syntax.link`: #268BD2 → #3194DA
- `sessionColors[1]`: #CB4B16 → #D44E17
- `sessionColors[3]`: #6C71C4 → #6F74C5
- `sessionColors[4]`: #D33682 → #D54088
- `sessionColors[7]`: #DC322F → #DE403D

### Solarized Light

- `readInk`: #2AA198 → #27948B
- `editInk`: #859900 → #7C8F00
- `questionInk`: #6C71C4 → #484EB5
- `errorInk`: #DC322F → #C52421
- `warningInk`: #B58900 → #826100
- `surfaceSecondary`: #D3D3C5 → #C0C4BB (halfway between base2 and in-palette base1; the picker track and unselected tabs now read darker than the page and the selected thumb, both base3, by 1.64:1)
- `textPrimary`: #657B83 → #3E494D (darker than `textSecondary` so the hierarchy holds: 8.60:1 against 8.09:1 on the page; also reads 5.23:1 as the unselected picker label on the track)
- `textSecondary`: #93A1A1 → #434D4D (base1 darkened until it reads on the page and on the unselected-tab bar, where a hovered tab is the tightest fill at 4.5:1)
- `linkInk`: #268BD2 → #1D6AA0
- `syntax.keyword`: #859900 → #627000
- `syntax.string`: #2AA198 → #1F756F
- `syntax.comment`: #93A1A1 → #5E6C6C
- `syntax.number`: #D33682 → #C02A73
- `syntax.type`: #B58900 → #846400
- `syntax.function`: #268BD2 → #1E6EA7
- `syntax.property`: #6C71C4 → #5B60BD
- `syntax.constant`: #CB4B16 → #B74414
- `syntax.builtin`: #DC322F → #CC2522
- `syntax.operator`: #6C71C4 → #5B60BD
- `syntax.punctuation`: #657B83 → #596D74
- `syntax.attribute`: #CB4B16 → #B74414
- `syntax.tag`: #268BD2 → #1E6EA7
- `syntax.heading`: #B58900 → #846400
- `syntax.link`: #268BD2 → #1E6EA7
- `sessionColors[0]`: #268BD2 → #268AD0
- `sessionColors[2]`: #859900 → #7A8D00
- `sessionColors[5]`: #2AA198 → #26928A
- `sessionColors[6]`: #B58900 → #A77E00

### One Dark

- `questionInk`: #C678DD → #DDAEEA
- `errorInk`: #E06C75 → #E5848B
- `textPrimary`: #ABB2BF → #BCC2CC (lightened so it reads stronger than `textSecondary`: 7.82:1 against 7.28:1 on the page)
- `textSecondary`: #7F848E → #B8BBC1
- `syntax.keyword`: #C678DD → #CC85E0
- `syntax.comment`: #5C6370 → #9198A5
- `syntax.property`: #E06C75 → #E5848B
- `syntax.tag`: #E06C75 → #E5848B
- `syntax.heading`: #E06C75 → #E5848B
- `sessionColors[7]`: #BE5046 → #CD7870
