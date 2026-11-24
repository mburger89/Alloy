# Theme slots

Every colour slot a theme file can set under `colors`, in file order, with what it colours. The values are
`#RRGGBB` or `#RRGGBBAA`. A slot a theme leaves out comes from its `base`.

- `background`: The window background behind everything.
- `surface`: Raised surfaces: the composer box and the code view.
- `surfaceSecondary`: Secondary surfaces: segmented-picker tracks and unselected tabs.
- `accent`: The accent: selection, focus, toggles and the sidebar plus button.
- `separator`: Hairline separators between panes and rows.
- `textPrimary`: Primary text everywhere; secondary levels are derived from it.
- `textSecondary`: Secondary text drawn by MetalUI controls: placeholders, captions. Optional; derived from textPrimary when absent.
- `textTertiary`: Tertiary text drawn by MetalUI controls. Optional; derived from textPrimary when absent.
- `scrollIndicator`: The scroll indicator thumb (usually translucent).
- `scrim`: The dimming behind modal presentations (usually translucent).
- `pickerThumbEdge`: The 1 px outline of the selected segment in segmented pickers; needs 3:1 against surfaceSecondary and against the selected segment.
- `thinkingTint`: Background of thinking blocks in the chat.
- `readTint`: Background of file-read blocks.
- `shellTint`: Background of shell command blocks.
- `editAddTint`: Background of added lines in edit diffs and the code panel.
- `editRemoveTint`: Background of removed lines in edit diffs and the code panel.
- `errorTint`: Background of error blocks.
- `warningTint`: Background of warning blocks and notices.
- `questionTint`: Background of question cards.
- `planTint`: Background of plan cards.
- `commandTint`: Background of slash-command blocks and the selected suggestion.
- `webTint`: Background of web fetch and search blocks.
- `thinkingInk`: Icon and accent colour of thinking blocks.
- `readInk`: Icon and accent colour of file-read blocks.
- `shellInk`: Icon and accent colour of shell blocks.
- `editInk`: Icon and accent colour of edit blocks.
- `webInk`: Icon and accent colour of web blocks.
- `linkInk`: Links in chat text and code.
- `questionInk`: Icon and accent colour of question cards.
- `planInk`: Icon and accent colour of plan cards.
- `errorInk`: Error text and icons.
- `warningInk`: Warning text and icons.
- `sidebarFill`: Background of the sidebar and user messages.
- `chatFill`: Background of the launcher (the chat column sits on the island: see `islandFill`).
- `panelFill`: Background of the code panel, settings and suggestion lists.
- `windowBackground`: The colour behind the islands, in the gutters around them.
- `islandFill`: Fill of the islands, drawn at island opacity.
- `controlFill`: Fill of the floating controls, drawn at control opacity; control text must read on it.
- `glassRim`: The 1 pt rim highlight on islands and controls (translucent white in a dark theme, translucent black in a light one).
- `markdownCodeFill`: Background of Markdown code blocks.
- `markdownQuoteBar`: The bar beside Markdown block quotes.
- `markdownRule`: Markdown horizontal rules.
- `userAuthor`: Marker for edits you made in Alloy.
- `outsideAuthor`: Marker for edits made outside Alloy.
- `mutedInk`: Secondary text and glyphs; must read on every fill.
- `sessionSelection`: Fill of the selected session row.
- `controlBorder`: Border of the composer box.
- `codeSelectionFill`: Selection fill in code views.
- `codeInactiveSelectionFill`: Selection fill in code views that are not the focused view of the key window.
- `findMatchFill`: Highlight of find matches in code views.
- `currentFindMatchFill`: Highlight of the current find match.
- `snippetPlaceholderFill`: Tint of the placeholders of a running snippet other than the current one.
- `diagnosticError`: Errors from language servers: gutter bar, text tint and message row.
- `diagnosticWarning`: Warnings from language servers: gutter bar, text tint and message row.
- `diagnosticInfo`: Information from language servers: gutter bar and text tint.
- `syntax.keyword`: Keywords.
- `syntax.string`: String literals.
- `syntax.comment`: Comments.
- `syntax.number`: Numeric literals.
- `syntax.type`: Type names.
- `syntax.function`: Function and method names.
- `syntax.property`: Properties, fields and parameters.
- `syntax.constant`: Constants and booleans.
- `syntax.builtin`: Built-in names.
- `syntax.operator`: Operators.
- `syntax.punctuation`: Punctuation and delimiters.
- `syntax.attribute`: Attributes and decorators.
- `syntax.tag`: Markup tags.
- `syntax.heading`: Markdown headings.
- `syntax.link`: Links in code and Markdown.

`sessionColors` is a separate list of 6 to 12 colours, one per session row in the sidebar.

## Terminal tokens (optional)

The integrated terminal reads these optional `colors` keys. A theme does not need to set them: any token left
out is derived from the editor slots above, so every theme already works. Set them only to tune the terminal.

- `terminal.background`: Terminal panel background. Falls back to `surface`.
- `terminal.foreground`: Default terminal text. Falls back to `textPrimary`.
- `terminal.cursor`: Terminal cursor. Falls back to `textPrimary`.
- `terminal.selection`: Selected text in the terminal, drawn over the background. Falls back to `codeSelectionFill`.
- `terminal.ansi0`: ANSI black. Falls back to `background`.
- `terminal.ansi1`: ANSI red. Falls back to `errorInk`.
- `terminal.ansi2`: ANSI green. Falls back to `syntax.string`.
- `terminal.ansi3`: ANSI yellow. Falls back to `warningInk`.
- `terminal.ansi4`: ANSI blue. Falls back to `syntax.function`.
- `terminal.ansi5`: ANSI magenta. Falls back to `syntax.keyword`.
- `terminal.ansi6`: ANSI cyan. Falls back to `syntax.type`.
- `terminal.ansi7`: ANSI white. Falls back to `textPrimary` at reduced alpha.
- `terminal.ansi8`: ANSI bright black. Falls back to ANSI black moved toward the foreground.
- `terminal.ansi9`: ANSI bright red. Falls back to ANSI red moved toward the foreground.
- `terminal.ansi10`: ANSI bright green. Falls back to ANSI green moved toward the foreground.
- `terminal.ansi11`: ANSI bright yellow. Falls back to ANSI yellow moved toward the foreground.
- `terminal.ansi12`: ANSI bright blue. Falls back to ANSI blue moved toward the foreground.
- `terminal.ansi13`: ANSI bright magenta. Falls back to ANSI magenta moved toward the foreground.
- `terminal.ansi14`: ANSI bright cyan. Falls back to ANSI cyan moved toward the foreground.
- `terminal.ansi15`: ANSI bright white. Falls back to ANSI white moved toward the foreground.
