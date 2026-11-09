# Alloy: themes (design)

Status: written; awaiting the user's review of the settled calls. Extends the Alloy design (`2026-11-07-alloy-design.md`) and depends on Plan 5a's Settings view and Alloy MCP server (`2026-11-09-alloy-shared-knowledge-design.md`).

## 1. Why

The user wants Alloy to look the way they like. That means a good default (Dracula), a handful of well-known themes in the box, and themes of their own. They want Claude to help make those themes, not hand-edit colour codes.

## 2. Goals

1. **A theme restyles the whole app.**
   - Code syntax colours.
   - The sidebar, chat and panel backgrounds.
   - Chat block tints and inks.
   - The diff and author tints.
   - The colours that tell sessions apart.
   - Text, accent and borders.
2. **Built-in themes:**
   - **Dracula** (the default);
   - **Alloy Dark** (today's dark look);
   - **Alloy Light** (today's light look);
   - **Solarized Dark**;
   - **Solarized Light**;
   - **One Dark**.

   All of these are openly licensed palettes (MIT). Credit each theme's source in `docs/themes.md` and the theme file.
3. **Choosing a theme** happens in the Settings view (Plan 5a). The user decision offers both of these options:
   - **One theme**: always this theme, whatever the Mac's appearance.
   - **Match system**: one theme for light mode and one for dark mode, switching with macOS.

   Default: one theme, Dracula.
4. **User-made themes** are theme files in Alloy's themes folder. They appear in the picker next to the built-ins and can be edited by hand.
5. **Making themes with Claude** (user decision: Claude helps rather than the user editing files):
   - **`/theme [description]`** starts a session that has the theme-making guide loaded. The user describes the look, for example "warm, low contrast, like old paper".
   - **Theme tools for Claude.** Alloy exposes these on its MCP server (`mcp__alloy__*`):
     - list the theme's colour slots and what each is for;
     - read an existing theme;
     - preview a draft live;
     - check its contrast;
     - save it under a name.
   - **Live preview.** Alloy applies each draft to the whole app as a preview. The user's real theme is untouched until they save and pick the new theme. A visible "Previewing <name>: Keep / Discard" bar makes the preview state obvious.
6. **Readability check.** Before saving, Alloy checks text-on-background contrast for the pairs that matter:
   - text on each background;
   - code text on the code background;
   - inks on their tints.

   Pairs below WCAG AA (4.5:1 for normal text, 3:1 for large text and UI) come back from the tool so Claude can fix them, and the user sees a warning. The user can still save if they insist.

## 3. Non-goals

- **No in-app colour-picker editor.** Making themes goes through Claude or a text editor (user decision).
- **No theme marketplace or sharing service.** A theme is a file; people share files.
- **Not installing a Claude skill.** Alloy never writes to `~/.claude` or the project's `.claude/`, so the "skill" is delivered as Alloy's own session guidance plus MCP tools (§6.3). The repo may also carry a skill file in `docs/` for people who want to install it themselves.
- **No per-session or per-project themes.** A theme is app-wide.

## 4. Anti-goals

- **An unreadable app.** The contrast check, plus a one-click "Back to Dracula" in Settings, guarantees the user can always recover.
- **Preview leaking into the saved theme.** A discarded preview leaves no trace.
- **Hard-coded colours that ignore the theme.** Every colour in views must come from a theme slot. A test fails on any inline colour.

## 5. Constraints

All constraints from the Alloy design apply:
- MetalUI only;
- theme tokens only, no inline hex;
- accessibility ids on every interactive view;
- never write `~/.claude` or `.claude/`;
- never brand anything "Claude Code";
- zero warnings.

MetalUI already supports this. Apps define palette keys (`ThemeColorKey`), and a window's `lightTheme`/`darkTheme` can override any key at runtime (`window.darkTheme[Key.self] = …`). Built-in MetalUI tokens (text, accent and so on) live on its `Theme`. A theme switch must not rebuild views or reopen files, only repaint. Any MetalUI gap found here is forwarded to the MetalUI session.

## 6. How it works (decided parts)

### 6.1 Theme slots

A theme fills a fixed set of named slots. The slots are:
- every Alloy palette key in `Sources/AlloyKit/Theme.swift` (about 32 today: tints, inks, author colours, fills);
- the MetalUI built-in tokens Alloy shows (text levels, accent, separators, control fills);
- the syntax palette (`AlloyHighlight/SyntaxPalette`: keyword, string, comment, type, function and the rest);
- the session colour list. Today that is 8 colours in a fixed order; a theme may give 6–12.

Each slot has a one-line purpose, used by the theme tools and the docs. Unknown slots in a file are ignored. Missing slots fall back to the base theme the file names (`"base": "dracula"`), so a user theme can change just a few colours.

### 6.2 Theme files

- **Format:** JSON, with `name`, `appearance` (`dark` | `light`), `base`, `author`, `source` or `credit` (optional), and `colors: { slot: "#RRGGBB" | "#RRGGBBAA" }`.
- **Location:** built-ins ship inside the app. User themes live in `<Alloy app support>/Themes/*.json` (this honours `ALLOY_DATA_DIR`).
- **Loading:** Alloy watches the themes folder, so a hand edit applies live when that theme is in use. A file that doesn't parse shows an error in Settings and is skipped, and Alloy falls back to the theme's base.

### 6.3 Making a theme with Claude

- **`/theme [description]`** opens a new session named "Theme: <description or 'new'>". Its guidance, appended at launch like Plan 5a's, explains:
  - the slots;
  - the workflow: list slots, read the base theme, draft, preview, check contrast, adjust, save;
  - that it should ask the user about taste rather than guess.
- **MCP tools** (on Alloy's server; names are the builder's call):
  - `theme_slots`: slot names, their purposes and the current values;
  - `theme_read(name)`
  - `theme_preview(json)`: applies the draft as a preview and returns contrast findings;
  - `theme_save(name, json)`: writes the user theme file and returns contrast findings.

  These tools only touch Alloy's own theme state and themes folder, so like the notes tools they are allowed without asking. They follow Plan 5a's "Ask before sessions use shared notes" setting, extended to "Ask before sessions use Alloy's tools".
- **Preview bar:** "Previewing <name> — Keep · Discard". Keep saves the theme, if it isn't saved yet, and selects it. Discard restores the user's theme. Closing the session also discards an unsaved preview.

### 6.3a Calls settled after the builder check (my calls; check these)

**Saving a theme that fails the contrast check.**
- `theme_save` always writes the file and returns the contrast findings, so Claude fixes them before it calls save.
- Only the user can make a theme active, through Keep in the preview bar or the Settings picker. Claude can't.
- When the user activates a theme with findings, Alloy shows the warning ("3 colour pairs are hard to read") with "Use anyway" and "Cancel". This keeps the "insist" decision with the user, in Alloy's own UI, out of Claude's reach.

**Who gets the theme tools.**
- Only sessions started with `/theme`, or with "Make a theme with Claude…", get them. They are scoped by the per-session token from Plan 5a, so ordinary coding sessions never see them.
- `theme_save` never overwrites a built-in, and never overwrites a user theme that another session or the user made. A clashing name is saved as "<name> 2". The session may overwrite only themes it saved itself.

**Text levels and MetalUI.** MetalUI's theme has one text colour, `textPrimary`. Secondary and tertiary text are fixed opacities of it, but faithful Dracula and Solarized need independent text-level colours.
- Alloy files a MetalUI gap for independent secondary and tertiary text colours in the theme.
- Until that lands, the built-ins ship with the derived levels, so step 1 doesn't wait.
- The syntax palette (`SyntaxPalette`, `FenceHighlighter`) moves onto theme keys as ordinary builder work.

### 6.4 Settings

- **Theme mode:** One theme | Match system.
  - One theme: a single picker.
  - Match system: a Light picker and a Dark picker.
- **Pickers:** each lists the built-ins and then the user themes, with a small swatch strip per theme.
- **Buttons:**
  - "Open themes folder";
  - "Make a theme with Claude…" (the same as `/theme`);
  - "Back to Dracula".

## 7. Order and sizing

This is a separate plan after Plan 5a, because it needs 5a's Settings view and MCP server. The builder can split it into two steps:
1. theme slots, files, built-ins and the Settings picker, which stand alone;
2. `/theme`, the theme tools, preview and the contrast check.

Plan numbering goes in the roadmap (proposed: Plan 7, Themes).

## 8. Left to the builder

- The exact slot list, and how MetalUI built-in tokens map to slots.
- Tool names and schemas.
- The swatch strip design.
- The guidance wording (under about 200 words; never "Claude Code").
- How the Dracula, Solarized and One Dark palettes map onto Alloy's slots. Stay faithful to each palette's published colours.
