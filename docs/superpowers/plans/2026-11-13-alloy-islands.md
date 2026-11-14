# Islands and Glass (step 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle Alloy as glass islands with floating glass controls, a title island and pill buttons, with shape and glass values set by themes and overridable by sliders in Settings.

**Architecture:** A pure `AppearanceStyle` value (AlloyCore) is resolved from the theme's new `style` object along the `base` chain, then overlaid with optional `AppearanceOverrides` from `AlloySettings`. `ThemeController` publishes the resolved style and views read it (no literals). Islands are rounded translucent fills on a theme window background inside the existing `HSplitView`; the composer floats as glass over the transcript; the code panel's tab bar and header become glass bars above the code until MetalUI G43 lets code scroll beneath them.

**Tech Stack:** Swift 6, MetalUI (read-only, `../MetalUI`), Swift Testing, `MetalUITesting` for view tests.

**Spec:** `docs/superpowers/specs/2026-11-13-alloy-islands-design.md` (and the themes design it extends, `2026-11-09-alloy-themes-design.md`).

## Global Constraints

- MetalUI is read-only. A missing API is a gap sent to "Mini MetalUI", never a workaround. Open gaps: G40 see-through window, G41 lineless divider, G42 stronger blur (on hold), G43 content scrolling under an overlay.
- Defaults (spec §6.2): gutter 6 pt (0–16), corner roundness 10 pt (0–20), island opacity 70% (40–100%), control opacity 60% (40–100%), control blur `heavy` (`light` / `medium` / `heavy`), pill buttons on.
- Title island height fixed at 38 pt (§6.7).
- Every gutter, radius, opacity and blur in views comes from the resolved `AppearanceStyle`, and every colour from a theme slot. No literals.
- Accessibility ids on every interactive view: `settings-appearance-<name>`, `settings-appearance-reset`, `title-new-session`, `title-quick-open`, `title-settings`. Do not rename existing ids (`file-panel`, `code-view`, `composer`, `send`, `tab-<path>`, `new-session`, `file-panel-*`, `settings-*`).
- Keep `alloyFilePanelIdealWidth` at 360 (RootView.swift:10). The benchmark clicks at windowFrame.maxX − 180, which must stay inside the code view.
- Never write `~/.claude` or the project's `.claude`. Never launch the GUI app from a subagent. Never `pkill`; kill only your own PIDs.
- Zero warnings. Full `swift test` green before each commit's task is reported done.
- Commit trailer on every commit:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  plus the session's `Claude-Session:` trailer

## Review Focus

1. A user theme file with no `style` object, or a partial one, must still load: missing keys come from the base chain, then the defaults. Owned by Task 1 (test `missingStyleKeysFallBackAlongBase`).
2. Out-of-range values in a theme file or settings.json (gutter 40, opacity 5%, blur "extreme") must clamp or fall back, never crash or produce an unusable window. Owned by Task 1 (test `outOfRangeValuesClamp`).
3. A slider change must repaint without rebuilding views or reopening files: the open document keeps its identity and the composer keeps focus. Owned by Task 5 (test `sliderChangeKeepsDocumentAndFocus`).
4. Reduce Transparency on: islands and controls draw solid whatever the sliders say, and Settings shows the note. Owned by Task 3 (test `reduceTransparencyDrawsSolid`) and Task 5 (note test).
5. The transcript's last message must stay readable above the floating composer, including while streaming and after the composer grows to several lines. Owned by Task 3 (test `lastMessageClearsTheComposer`).

---

### Task 1: Appearance model, theme `style`, settings overrides

**Files:**
- Create: `Sources/AlloyCore/Themes/AppearanceStyle.swift`
- Modify: `Sources/AlloyCore/Themes/ThemeFile.swift` (field, `parse` branch, `encoded()` branch)
- Modify: `Sources/AlloyCore/Themes/ThemeLibrary.swift` (`ResolvedTheme.style`, fallback in `resolve(_:)` and `resolve(draft:)`)
- Modify: `Sources/AlloyCore/Model/AlloySettings.swift` (`appearance: AppearanceOverrides`, CodingKey `appearance`, `decodeIfPresent`, lenient like the theme keys)
- Test: `Tests/AlloyCoreTests/AppearanceStyleTests.swift`

**Interfaces:**
- Produces:
  - `public enum ControlBlur: String, Sendable, Codable, CaseIterable { case light, medium, heavy }`
  - `public struct AppearanceStyle: Equatable, Sendable { var gutter: Double; var cornerRadius: Double; var islandOpacity: Double; var controlOpacity: Double; var controlBlur: ControlBlur; var pillButtons: Bool; static let defaults; func clamped() -> AppearanceStyle; func applying(_ o: AppearanceOverrides) -> AppearanceStyle }`. Opacities are 0…1 fractions. The ranges are in Global Constraints.
  - `public struct AppearanceStyleFile: Equatable, Sendable` holds the same six fields, all optional (the theme file's `style`).
  - `ThemeFile.style: AppearanceStyleFile?`. JSON keys: `gutter`, `cornerRadius`, `islandOpacity`, `controlOpacity`, `controlBlur`, `pillButtons`. Opacities are written as fractions.
  - `ResolvedTheme.style: AppearanceStyle`: the nearest value along the base chain per key, then `.defaults`, then `clamped()`.
  - `public struct AppearanceOverrides: Equatable, Sendable, Codable { var gutter, cornerRadius, islandOpacity, controlOpacity: Double?; var controlBlur: ControlBlur?; var isEmpty: Bool }`. There is no `pillButtons` override (theme only).
  - `AlloySettings.appearance: AppearanceOverrides` (default empty).

- [ ] **Step 1: Write the failing tests** in `AppearanceStyleTests`:
  - `defaultsMatchTheSpec`: `.defaults` == (6, 10, 0.70, 0.60, .heavy, true).
  - `styleRoundTripsThroughTheThemeFile`: parse → `encoded()` → parse is equal for a file with all six keys.
  - `missingStyleKeysFallBackAlongBase`: base theme sets `gutter: 4`, child sets `cornerRadius: 14` → resolved child has gutter 4, radius 14 and default opacities. A file with no `style` resolves to `.defaults` (all built-ins do).
  - `outOfRangeValuesClamp`: a theme with gutter 40, controlOpacity 0.05 and controlBlur "extreme" → gutter 16, controlOpacity 0.40, blur `.heavy` (unknown string falls back), and the file still parses.
  - `overridesApplyOnTopAndEmptyIsTheTheme`: `applying` with gutter 12 changes only the gutter; empty overrides return the style unchanged.
  - `settingsWithoutAppearanceDecode`: an old settings.json without `appearance` decodes with empty overrides; one with `{"appearance":{"gutter":8}}` round-trips.
- [ ] **Step 2: Run** `swift test --filter AppearanceStyleTests`. Expected: fails to compile (types missing).
- [ ] **Step 3: Implement** the types and the three file changes. A wrong-typed `style` key is ignored (falls back), not a parse error, so a theme never fails to load because of style.
- [ ] **Step 4: Run** `swift test --filter AppearanceStyleTests`, then the full `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(themes): appearance style in themes and settings overrides`.

### Task 2: Island colour slots and the control-text contrast pair

**Files:**
- Modify: `Sources/AlloyKit/Theme.swift` (four `ThemeColorKey`s)
- Modify: `Sources/AlloyKit/Themes/ThemeSlots.swift` (`key(...)` entries with purposes)
- Modify: `Sources/AlloyCore/Themes/BuiltIn/*.swift` (values for all six built-ins)
- Modify: `Sources/AlloyCore/Themes/ThemeContrast.swift` (`findings` and `rules`)
- Test: extend `Tests/AlloyKitTests/` theme slot tests and `Tests/AlloyCoreTests/` contrast tests (existing files; `rulesMatchFindings` must stay green)

**Interfaces:**
- Produces slots and keys:
  - `windowBackground` / `WindowBackgroundKey`: the colour behind the islands.
  - `islandFill` / `IslandFillKey`: the islands' fill, drawn at island opacity.
  - `controlFill` / `ControlFillKey`: the floating controls' fill, drawn at control opacity.
  - `glassRim` / `GlassRimKey`: the 1 pt rim highlight on islands and controls.
  - `Color.windowBackground`, `.islandFill`, `.controlFill`, `.glassRim` statics, like `Color.sidebarFill`.
- Dark built-ins:
  - `windowBackground` is the theme's darkest background, or a step darker;
  - `islandFill` equals its current `chatFill`;
  - `controlFill` is `#2C2E3E` for Alloy Dark, and the nearest equivalent in each other palette;
  - `glassRim` is white at about 12–18% alpha.
- Light built-ins: `windowBackground` is a step darker than `islandFill`, which is near-white.
- Contrast pair: `"control text on control fill"`. The foreground is the text token, over `controlFill` at the default control opacity, composited over `islandFill`. Minimum 4.5.

- [ ] **Step 1: Write failing tests:**
  - `islandSlotsAreListedWithPurposes`: the four names are in `ThemeSlots.all`, each with a non-empty purpose.
  - `builtInsFillIslandSlots`: every built-in resolves all four.
  - `controlTextContrastIsChecked`: a theme whose control fill equals its text colour produces a `control text on control fill` finding.
  - `builtInsPassControlContrast`: no built-in yields that finding.
- [ ] **Step 2: Run** the new tests. Expected: they fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the full `swift test`. Expected: green, including `rulesMatchFindings` and the theme guard test.
- [ ] **Step 5: Commit** `feat(themes): island colour slots and control-text contrast`.

### Task 3: Floating glass composer and glass code-panel bars (measurement gate)

**Files:**
- Create: `Sources/AlloyKit/Glass/GlassControl.swift`
- Modify: `Sources/AlloyKit/Themes/ThemeController.swift` (publish `style: AppearanceStyle`, resolved theme ⊕ settings overrides; recomputed in `apply()`, `bind(_:)` and preview)
- Modify: `Sources/AlloyKit/ChatView.swift` (composer as an overlay at the bottom of the transcript area instead of a sibling below a `Divider()`; the transcript's `LazyVStack` ends with a spacer the height of the composer plus one gutter)
- Modify: `Sources/AlloyKit/FilePanelView.swift` (`FileTabStrip` + `FilePanelHeader` inside one glass bar above `CodePanel`; drop the `Divider()`)
- Test: `Tests/AlloyKitTests/GlassControlTests.swift`

**Interfaces:**
- Consumes: Task 1 `AppearanceStyle`, Task 2 `Color.controlFill`, `.glassRim`.
- Produces:
  - `struct GlassControl<Content: ElementGroup>: Component`, with `init(style: AppearanceStyle, cornerRadius: Double, @ElementGroupBuilder content: () -> Content)`. It draws `glassEffect(glass(for: style), in: RoundedRectangle(cornerRadius:))`, with the `controlFill` tint at `style.controlOpacity` and a `glassRim` stroke.
  - `static func glass(for style: AppearanceStyle) -> Glass`, mapping blur steps to strength:
    - `light` → `.clear`;
    - `medium` → `.regular`;
    - `heavy` → `.regular` over `.thickMaterial`.

    Check `heavy` by eye against `docs/superpowers/specs/assets/2026-11-13-islands-D-heavy-blur.png` (controller step). If it can't get close, report that for G42.
  - `ThemeController.style: AppearanceStyle` (observable).
  - Process env var `ALLOY_GLASS=0`, read once at launch: the controls draw `controlFill` at full opacity with no glass. This is only the measurement switch. It becomes the "Reduce glass for speed" setting only if the gate below calls for it (spec §6.8).
- Do not use `GlassEffectContainer`, because its subtree refuses retention.

- [ ] **Step 1: Write failing tests** with `MetalUITesting` in the style of `SettingsViewTests`:
  - `composerFloatsOverTheTranscript`: the composer's frame overlaps the transcript's scroll frame, and its bottom edge is one gutter above the chat area's bottom.
  - `lastMessageClearsTheComposer`: append messages until the transcript scrolls. The last message's frame bottom is ≤ the composer's frame top. This also holds after typing three lines into the composer.
  - `codePanelBarsSitAboveTheCode`: the frame top of `code-view` is ≥ the frame bottom of the glass bar (the G43 interim).
  - `reduceTransparencyDrawsSolid`: with `accessibilityReduceTransparency` set in the test environment, `GlassControl.glass(for:)` is not used and the fill is opaque. If MetalUITesting can't set that environment, test a `GlassControl.Resolved` value (glass or solid) computed from `(style, reduceTransparency, glassEnv)` instead.
  - `glassMapsBlurSteps`: `.light`, `.medium` and `.heavy` map as specified.
- [ ] **Step 2: Run** the new tests. Expected: they fail.
- [ ] **Step 3: Implement.** Keep ids `composer`, `send`, `file-panel*` and `tab-<path>` unchanged.
- [ ] **Step 4: Run** the full `swift test`. Expected: green.
- [ ] **Step 5: Commit** `feat(ui): floating glass composer and glass code-panel bars`.
- [ ] **Step 6 (controller, not the implementer): GUI measurement gate.**
  - Build release.
  - Run `alloy-bench run --apps alloy --metrics typingLatency,memory,memoryIdle --alloy-build <path>` with `METALUI_LATENCY_TRACE`. Alternate `ALLOY_GLASS=1` and `0`, and the merge base, with three runs each.
  - Record per-frame GPU time for typing in the editor, typing in the composer and streaming chat (a demo turn).
  - Send the numbers to Mini MetalUI and record them in `docs/parity.md`.
  - If glass is outside noise: ask MetalUI for the blur cache. If it's still outside noise after that, add the switch in Task 5 (spec §6.8).

### Task 4: Islands layout and the title island

**Files:**
- Create: `Sources/AlloyKit/Islands/Island.swift`, `Sources/AlloyKit/Islands/TitleIsland.swift`
- Modify: `Sources/AlloyKit/RootView.swift` (window background, gutter padding, each pane wrapped in `Island`, title island on top)
- Modify: `Sources/Alloy/main.swift` (`openWindow(..., windowStyle: .hiddenTitleBar)`)
- Modify: `Sources/AlloyCore/Model/Workspace.swift` (`public private(set) var branchName: String?`. Read `.git/HEAD` (`ref: refs/heads/<name>` → name; a detached HEAD → the short hash) at open and on the existing HEAD-change event (`GitBaseline`). Nil outside git.)
- Test: `Tests/AlloyKitTests/IslandsTests.swift`, `Tests/AlloyCoreTests/BranchNameTests.swift`

**Interfaces:**
- Consumes: Task 1 style, Task 2 colours, Task 3 `ThemeController.style`.
- Produces:
  - `struct Island<Content>: Component`: content clipped to `RoundedRectangle(cornerRadius: style.cornerRadius)`, filled with `islandFill` at `style.islandOpacity` (solid under Reduce Transparency), with a `glassRim` stroke.
  - `TitleIsland` contains, in order:
    - space for the traffic lights;
    - the project folder name and the branch with a "⎇" glyph;
    - a spacer;
    - three pill buttons: New Session (`title-new-session`, same action as ⌘N via `newSessionFromUser`), Quick Open (`title-quick-open`, toggles `quickOpen`), and Settings (`title-settings`, a gear, calls `workspace.openSettings`).

    The window applies `windowTitleBarMetrics(height: 38 + 2 × gutter, controlsLeading: gutter + 14)`, so the lights sit centred inside the island and follow the gutter live.
  - The window background is `windowBackground`. The gutter is space around and between islands. Before G41 it's padding inside each `HSplitView` pane, with half a gutter on each side of a divider.
- Keep the sidebar's existing "+" (`new-session`) as it is.

- [ ] **Step 1: Write failing tests:**
  - `islandsAreInsetByTheGutter`: with gutter 6, the sidebar island's frame starts 6 pt from the window's left, and the chat island starts about 6 pt after the sidebar island ends (allow the 1 pt divider).
  - `gutterChangeRelayoutsWithoutRebuild`: change the override gutter to 12. The island frames move, the open document's id is unchanged, and the composer keeps focus.
  - `titleIslandButtonsAct`: clicking `title-new-session` creates and selects a session, `title-quick-open` shows quick open, and `title-settings` shows `settings-view`.
  - `titleShowsProjectAndBranch`: the title text shows the folder name, and the branch when `branchName` is set.
  - `BranchNameTests`: reads `ref: refs/heads/feat/x` as `feat/x`, a detached HEAD as a 7-character hash, and no `.git` as nil.
- [ ] **Step 2: Run.** Expected: they fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the full `swift test`. Expected: green.
- [ ] **Step 5: Commit** `feat(ui): islands layout and title island`.

### Task 5: Pill buttons and the Settings Appearance section

**Files:**
- Create: `Sources/AlloyKit/Glass/PillButtonStyle.swift`
- Modify: buttons in `ComposerView.swift`, `FilePanelView.swift`, `SettingsView.swift`, `SidebarView.swift` and `TitleIsland.swift` (`.buttonStyle(PillButtonStyle(style:))`, excluding `.plain` icon buttons)
- Modify: `Sources/AlloyKit/SettingsView.swift` (`AppearanceSection` after `ThemeSection`)
- Modify: `Sources/AlloyKit/Themes/ThemeController.swift` (`backToDracula()` also clears `settings.appearance`)
- Test: `Tests/AlloyKitTests/SettingsAppearanceTests.swift`

**Interfaces:**
- Consumes: Task 1 `AppearanceOverrides`, `Workspace.updateSettings(_:)`.
- Produces:
  - `struct PillButtonStyle: ButtonStyle`: a capsule when `style.pillButtons` is true, otherwise a rounded rectangle with radius `style.cornerRadius / 2`. The fill is `controlFill` at a light alpha, with a `glassRim` stroke.
  - `AppearanceSection` contains:
    - sliders `settings-appearance-gutter` (0–16), `settings-appearance-corners` (0–20) and `settings-appearance-control-opacity` (40–100%);
    - a three-step segmented picker `settings-appearance-blur`;
    - `settings-appearance-see-through`, built but hidden until G40 lands (a `static let seeThroughAvailable = false`);
    - `settings-appearance-reset`.

    Under Reduce Transparency, a note `settings-appearance-reduce-transparency-note` reads "Reduce Transparency is on in macOS, so glass is drawn solid." Each control writes `settings.appearance` through `updateSettings`.

- [ ] **Step 1: Write failing tests:**
  - `slidersWriteOverrides`: moving the gutter slider to 10 stores `appearance.gutter == 10` and persists after reload.
  - `resetClearsOverrides`: reset leaves `appearance.isEmpty` true.
  - `backToDraculaClearsOverrides`
  - `seeThroughIsHiddenUntilAvailable`
  - `sliderChangeKeepsDocumentAndFocus`: move a slider while a file is open. The document id is unchanged and no file is reread.
  - `reduceTransparencyShowsTheNote` (environment permitting, as in Task 3).
- [ ] **Step 2: Run.** Expected: they fail.
- [ ] **Step 3: Implement.** If Task 3's gate called for it, also add `settings-appearance-reduce-glass`: a Bool in `AlloySettings`, default off, which replaces the `ALLOY_GLASS` env check.
- [ ] **Step 4: Run** the full `swift test`. Expected: green.
- [ ] **Step 5: Commit** `feat(ui): pill buttons and Appearance settings`.

### Task 6: Theme tools and preview carry style; guard test

**Files:**
- Modify: `Sources/AlloyKit/Themes/ThemeTools.swift` (`ThemeSlotsTool` returns `style: {key: {value, range, purpose}}`; `ThemeTools.format` documents the `style` object; `theme_preview` and `theme_save` accept it)
- Modify: `Sources/AlloyKit/Themes/ThemeController.swift` (`preview`, `discardPreview`, `keepPreview` and `sameContent` include style)
- Modify: `Tests/AlloyKitTests/ThemeGuardTests.swift` (new rules: in `Sources/AlloyKit/Islands/` and `Sources/AlloyKit/Glass/`, no numeric literal in `cornerRadius:`, `.opacity(` or `RoundedRectangle(cornerRadius:`. Values come from `style`.)
- Test: extend the existing theme tool and preview tests.

- [ ] **Step 1: Write failing tests:**
  - `themeSlotsDescribeStyle`: the output lists six style keys with ranges.
  - `previewAppliesStyleAndDiscardRestores`: preview a draft with gutter 14, check that `ThemeController.style.gutter == 14`, then discard and check it is back to the previous value.
  - `saveWritesStyle`: a saved file contains `style`.
  - `guardRejectsInlineRadius`: the rule flags a fixture line `RoundedRectangle(cornerRadius: 8)` in an Islands path.
- [ ] **Step 2: Run.** Expected: they fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the full `swift test`. Expected: green.
- [ ] **Step 5: Commit** `feat(themes): theme tools and preview carry appearance style`.

### Task 7: Adopt MetalUI G40, G41 follow-ups, G43 and G44

MetalUI landed: G40 `.containerBackground(_:for: .window)` (29a7222b), G43 `contentMargins(_:_:for:)` for ScrollView/List (d3a8258d) and CodeView (de44a640), and G44 test helper `TestWindow.allGlyphs` (#293, adopt only once merged). G41 is already adopted in Task 4.

**Files:**
- Modify: `Sources/AlloyKit/RootView.swift` / `LauncherView.swift` (window `.containerBackground(.thinMaterial, for: .window)` when see-through is enabled; `windowBackground` drawn at `1 - seeThrough` so the desktop shows through)
- Modify: `Sources/AlloyCore/Themes/AppearanceStyle.swift` + `AlloySettings` (no new type: `islandOpacity` is the see-through control; add `windowSeeThrough: Bool` derived = islandOpacity < 1)
- Modify: `Sources/AlloyKit/SettingsView.swift` (`settings-appearance-see-through` slider, 0–60%, = 1 − islandOpacity, shown now)
- Modify: `Sources/AlloyKit/ChatView.swift` (replace the transcript's trailing spacer with `.contentMargins(.bottom, composerHeight + gutter, for: .scrollContent)`)
- Modify: `Sources/AlloyKit/FilePanelView.swift` (glass bar floats OVER the code: overlay at top, `.contentMargins(.top, barHeight + gutter, for: .scrollContent)` on the CodeView)
- Modify: island content clip: `.clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))` on each island's content; switch `fenceHighlighterFollowsTheTheme` and CodeBlockTests to `window.allGlyphs` (requires MetalUI #293 merged; if not merged when this task runs, leave clip out and report)
- Test: extend IslandsTests, GlassControlTests, SettingsAppearanceTests

- [ ] **Step 1: Write failing tests:** `seeThroughSliderWritesIslandOpacity` (slider at 30% stores islandOpacity 0.70; 0% stores 1.0 and removes the window material); `codeScrollsUnderTheBar` (code-view frame top ≤ bar frame top, i.e. the code starts under the bar, and the first line's glyph y ≥ bar bottom at scroll 0); `transcriptUsesContentMargins` (no trailing spacer element; last message bottom ≤ composer top); `islandsClipToCorners` (a full-bleed child's drawn rect is clipped — via allGlyphs/scene clip records as MetalUITesting allows).
- [ ] **Step 2: Run, see them fail. Step 3: Implement. Step 4: full `swift test`. Step 5: Commit** `feat(ui): see-through window, content under the glass bars, rounded island clip`.

### Task 8: Retention fixes (composer split, stable title island) and a per-frame guard

From MetalUI's A0 attribution: ComposerView's Menu/Picker (`graft ineligible because presentation`) and `.dropDestination` (`prepaint ineligible because dragAndDrop`) taint every ancestor; the title island's IslandBackdrop rect changes after the first layouts, which suspends prepaint replay window-wide for ~9 builds.

**Files:**
- Modify: `Sources/AlloyKit/ComposerView.swift` (thin outer wrapper carrying `.dropDestination`; `.equatable()` leaves: toolbar with the Menu/Picker, the editor, attachments)
- Modify: `Sources/AlloyKit/Islands/TitleIsland.swift` / `RootView.swift` (find what moves the title island backdrop rect after first layout — likely titleBarInsets/windowTitleBarMetrics taking effect a frame later — and make the island's frame stable from frame 1)
- Modify: `Tests/AlloyKitTests/ViewRerunTests.swift` (warm-up ≥ 10 settle frames; assert per steady frame: every counted frame ≤ measured steady cost + 2 requests; keep the total as a secondary check)

- [ ] **Step 1: Measure** the steady per-frame request count before changes (record in report). **Step 2: Write failing tests:** `composerToolbarDoesNotTaintAncestors` (after warm-up, typing in the code view: ChatColumn/AlloyScreen retained hits > 0 per frame, if MetalUITesting exposes retained hits; else the per-frame request count drops below the pre-change steady cost); `titleIslandRectIsStableFromFirstLayout` (its frame after frame 1 equals frame 10). **Step 3: Implement. Step 4: Measure** again and record both numbers. **Step 5: full `swift test`, commit** `perf(ui): composer split and stable title island for retention`.

### Finish (controller)

- Final whole-branch review.
- GUI benchmark of the branch against `master`: typing latency, memory, memoryIdle and idle CPU, with alternated builds. Record the results in `docs/parity.md`.
- Show the user screenshots of the real app (dark and light themes; gutter 0 and 16).
- Merge to `master`, push privately, then `tools/publish-public.sh`.
- Step 2 (later plan): adopt G40 (the See-through slider and window material), G41 (the divider thickness as the gutter, no line), G43 (`contentMargins(_:_:for:)`: code and transcript scroll under the bars; replaces the transcript spacer) and G42 if needed, as each lands.
