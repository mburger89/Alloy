# Alloy: islands and glass (design)

Status: approved by the user (2026-11-13), including §6.7 and §6.8. Extends the themes design (`2026-11-09-alloy-themes-design.md`).
Mockups (the chosen look, "D"): `assets/2026-11-13-islands-D.html` and, for the "heavy" blur reference,
`assets/2026-11-13-islands-D-heavy-blur.png`.

## 1. Why

The user wants Alloy to look like Apple's Liquid Glass and like JetBrains' "Islands" UI, both of which they like:
each part of the window is its own rounded island, separated by small gutters, with the title bar and traffic lights
inside an island of their own. They also want to make the look their own, so the shape and the glass are settings,
not fixed values.

## 2. Goals

1. **Islands.** The window becomes rounded islands on a window background, separated by a small gutter:
   - a **title island** across the top, holding the traffic lights, the project name and branch, and the title-bar
     buttons (New Session, Quick Open, Settings);
   - the **sessions sidebar**, the **chat** and the **file panel** as three islands below it, still resizable by
     dragging the gutters between them.
2. **Glass islands (user decision: mockup D).** The islands are translucent glass. Once MetalUI supports it, the
   desktop shows through the window behind them (see §6.5); until then a theme-coloured window background does.
3. **Floating glass controls (user decision).** The controls float over their island's content as glass, and the
   content scrolls underneath them:
   - the file tabs and the file header (path, diff layout toggle) over the code, as two rounded bars;
   - the composer (mode, model, message field, Send) over the chat transcript, as a rounded panel.
4. **Readable controls (user decision).** The controls' background is 60% opaque by default, over a heavy blur, so
   text scrolling beneath them is only a faint smudge (`assets/2026-11-13-islands-D-heavy-blur.png`).
5. **Pill buttons.** Buttons are capsules throughout the app (Auto, model, Inline / Side by side, the title-bar
   buttons, the active tab, Settings buttons).
6. **Make it yours (user decision: themes plus sliders).**
   - A theme sets the shape and glass values, next to its colours, so a Claude-made or hand-made theme carries a
     complete look.
   - Settings gets an **Appearance** section with live sliders for the values people tweak most. Slider values sit
     on top of whichever theme is active, and "Reset to theme" clears them.

## 3. Non-goals

- **No in-app colour editor.** Colours still come from themes (via `/theme` or the theme file), as decided in the
  themes design. Only the shape and glass values get sliders.
- **No per-session or per-project look.** Appearance is app-wide, like themes.
- **No new layout.** The same three areas in the same order; this is a restyle, not a rearrangement.

## 4. Anti-goals

- **Slower typing or more memory.** The standing goal is "as lite and fast as possible without giving up quality".
  Typing latency (today p50 about 16 ms, p95 about 23 ms), memory (about 54 MiB with a large file open, 45 MiB idle)
  and idle CPU must stay within run-to-run noise of today, measured with the GUI benchmark before merging each step.
- **Hard-to-read text.** Glass must never make code, chat or control text hard to read. The contrast check from the
  themes design covers the new values, and macOS's Reduce Transparency setting makes everything solid.
- **Hard-coded look values.** Every gutter, radius, opacity and blur in views comes from the appearance values
  (theme plus override), like colours come from theme slots. The existing "no inline colour" test extends to them.

## 5. Constraints

All constraints from the Alloy and themes designs apply (MetalUI only, theme tokens only, accessibility ids on every
interactive view, never write `~/.claude` or `.claude/`, zero warnings). MetalUI is read-only from Alloy: every
missing piece is forwarded to the MetalUI session as a gap with file:line evidence, never worked around.

What MetalUI already has (checked 2026-11-13):
- Liquid Glass: `glassEffect(_:in:)` with `.regular` / `.clear`, tint and interactive (`Sources/MetalUI/Glass.swift`);
- materials (`ultraThinMaterial` … `ultraThickMaterial`, `background(_ material:)`);
- the hidden title bar (`windowStyle: .hiddenTitleBar`) and moving the traffic lights:
  `windowTitleBarMetrics(height:controlsLeading:)` (`WindowPreferences.swift:90`);
- `HSplitView` with a fixed 1-point divider and a 6-point hit area (`SplitView.swift:230-250`).

## 6. How it works (decided parts)

### 6.1 Layout

- The window uses the hidden title bar. The title island is the top row; the traffic lights are centred vertically
  in it with `windowTitleBarMetrics`, inset to sit inside the island's rounded corner.
- Everything sits on the window background with one gutter of space around and between islands.
- The three lower islands stay in the `HSplitView`, so dragging still resizes them; the divider sits in the gutter
  (see §6.5 for hiding its line).
- The Settings view keeps opening over the chat area, inside the chat island.

### 6.2 Appearance values

New values, each with a default (the mockup D look) and a range:

| Value | Default | Range | Slider in Settings |
|---|---|---|---|
| Gutter | 6 pt | 0–16 pt | yes |
| Corner roundness | 10 pt | 0–20 pt | yes |
| Island opacity (how solid the islands are; 100% shows no desktop) | 70% | 40–100% | yes, labelled "See-through" (inverted: 30% default) |
| Control opacity (floating controls' background) | 60% | 40–100% | yes |
| Control blur | heavy | light / medium / heavy | yes, three steps |
| Pill buttons | on | on / off | no (theme only) |

- **Themes** gain an optional `"style"` object in the theme file with these keys. A missing key falls back to the
  base theme's value; the built-in themes all use the defaults above.
- **Slider overrides** are stored in `AlloySettings` as optional values (nil means "use the theme"), decoded with
  `decodeIfPresent` like the other settings. "Reset to theme" sets them all back to nil.
- **Live:** moving a slider repaints the window immediately, without rebuilding views or reopening files (the same
  rule as a theme switch).
- **Colours** the islands need become theme slots: window background, island fill, control fill (the 60% layer's
  colour), and the island and control rim highlight. Light themes get light islands on a slightly darker background.

### 6.3 Glass and blur

- **Floating controls** use MetalUI's glass (`.regular`), tinted with the control fill at the control opacity. The
  three blur steps map to MetalUI's strengths (for example clear glass, regular glass, regular glass over a thick
  material); which combination gives "barely see text behind" for "heavy" is the builder's call, checked against
  `assets/2026-11-13-islands-D-heavy-blur.png`. If MetalUI can't reach that strength, file a gap for a stronger glass blur.
- **Islands** are translucent fills over the window background, not in-window blur. Before §6.5 lands the window
  background is a flat theme colour, so islands need no blur; after it lands, macOS blurs the desktop behind the
  window. Either way, typing never pays for a backdrop blur over the code or the chat.
- **Reduce Transparency:** when macOS's Reduce Transparency is on, islands and controls draw solid (opacity 100%)
  whatever the settings say. MetalUI exposes it as `accessibilityReduceTransparency` (`EnvironmentValues.swift:191`).

### 6.4 Settings: Appearance section

- Placed under the existing theme pickers in Settings.
- Sliders for gutter, corner roundness, see-through and control opacity, and a three-step control for blur, each
  with an accessibility id (`settings-appearance-<name>`).
- "Reset to theme" (`settings-appearance-reset`).
- A note when Reduce Transparency is on: "Reduce Transparency is on in macOS, so glass is drawn solid."

### 6.5 Order (user decision: build now, add the see-through window later)

1. **Step 1, Alloy only:** the title island with the traffic lights, the three glass islands on a theme-coloured
   window background, the floating glass controls, pill buttons, the appearance values in themes, the Settings
   section, and the contrast check extended to control text over the control fill. Ships on its own.
2. **MetalUI gaps, sent to the MetalUI session at the start of step 1:**
   - **See-through window:** a window whose background shows the desktop, blurred by macOS (SwiftUI's
     `.containerBackground(.thinMaterial, for: .window)` / AppKit's behind-window `NSVisualEffectView`). The amount is
     Alloy's island opacity.
   - **Split divider without a line:** keep the drag area but draw no 1-point line, so the gutter between islands is
     clean (SwiftUI has no spelling for this; MetalUI-only, like `windowTitleBarMetrics`).
   - Only if needed: a stronger glass blur (§6.3).
3. **Step 2:** adopt each gap as it lands. Until the divider gap lands, a faint line in the gutters is acceptable.

### 6.6 Measuring

Before merging each step, run the GUI benchmark (typing latency, memory, idle CPU) against `master`, alternating
builds, and record the numbers in `docs/parity.md`. Remember that `alloy-bench` does not rebuild Alloy: build the
release product first.

### 6.7 Calls settled after the builder check (Claude's calls unless marked)

- **Measure glass first.** The floating controls' glass blurs live content (the code under the file header, the
  transcript under the composer), so it re-runs when that content changes. Step 1 starts with a measured prototype:
  the glass composer and file header only, run through the GUI benchmark (typing in the code view and in the
  composer, scrolling, streaming) before the rest is built. If it is over budget, first ask MetalUI for a cheaper
  path (for example caching the blur while the content under it is unchanged). FALLBACK: see §6.8.
- **Blur strength.** If MetalUI's existing glass and materials can't reach the "heavy" reference, that is a MetalUI
  gap; step 1 ships with the strongest existing combination meanwhile and does not block.
- **"See-through" slider before the see-through window.** Hidden until the MetalUI gap lands; until then islands use
  the theme's island fill at its theme opacity, over the theme's window background colour.
- **Gutter and the split divider.** The gutter value is the whole space between islands. The divider's line and hit
  area sit centred inside it; at gutter 0 the hit area may overlap the islands' edges, which is acceptable.
- **Title island and traffic lights.** The title island has a fixed height (38 pt). The lights' inset follows the
  gutter and corner values and may update live (a `windowTitleBarMetrics` change is a cheap window call, not a view
  rebuild).
- **Contrast.** Control text is checked against the control fill at its opacity composited over the island fill (the
  blurred content beneath averages out to roughly the island fill). AA rules as in the themes design.
- **Theme preview.** `theme_preview` previews style values too; Keep and Discard cover them. Slider overrides apply
  on top of a preview, as on top of any theme.
- **Recovery.** "Reset to theme" clears all slider overrides. "Back to Dracula" also clears them.

### 6.8 If the glass controls slow typing

User decision (2026-11-13): **a setting.** Glass stays on by default. If, after asking MetalUI for a cheaper path,
the glass controls still keep typing outside today's noise, Appearance gets a "Reduce glass for speed" switch
(`settings-appearance-reduce-glass`, stored in `AlloySettings`, default off). On, the floating controls keep their
shape, position and 60% fill but draw no blur beneath them. The switch is added only if the measurement calls for it.

## 7. Left to the builder

- Exact view structure: which component owns each island and the floating controls.
- The exact rim and highlight treatment of glass edges, matched to the mockup.
- How the theme tools (`theme_slots`, `theme_preview`, `theme_save`) describe the new style keys.
- Test strategy beyond the anti-goals above (for example, a test that no view uses an inline gutter, radius or
  opacity, and that slider overrides and "Reset to theme" persist).
