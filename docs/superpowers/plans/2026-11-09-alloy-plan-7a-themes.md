# Plan 7a: Themes, step 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A theme restyles all of Alloy. Six built-in themes ship, with Dracula as the default. The user picks one theme, or a light/dark pair that follows macOS, in Settings. Theme files the user drops in Alloy's themes folder appear in the picker and reload live.

**Architecture:**
- **AlloyCore** parses theme files (JSON) into plain RGBA values and resolves each theme's `base` chain. It knows nothing about MetalUI.
- **AlloyKit** maps slot names onto MetalUI: the `ColorToken` fields on `Theme`, Alloy's `ThemeColorKey`s, and new keys for syntax and session colours. It installs the result on the app's `lightTheme`/`darkTheme` and `preferredColorScheme`.
- **Switching** is a palette change, so MetalUI only repaints. No view, tab or session is rebuilt.

**Tech Stack:** Swift 6.1, SwiftPM, MetalUI (sibling `../MetalUI`), Swift Testing, CoreServices FSEvents (the existing `FSEventsSource`).

**Spec:** `docs/superpowers/specs/2026-11-09-alloy-themes-design.md`, approved 2026-11-09. This plan is step 1 of §7. `/theme`, the theme tools, preview and the contrast-check tool are Plan 7b.

## Global Constraints

- MetalUI only. Theme tokens only, never inline hex in AlloyKit views. Every interactive view gets an accessibility identifier.
- Never write to `~/.claude` or the project's `.claude/`. Never brand anything "Claude Code".
- Zero warnings in `swift build`, `swift test` and `swift build -c release`.
- The default is one theme, Dracula.
- Built-ins: Dracula, Alloy Dark (today's dark look), Alloy Light (today's light look), Solarized Dark, Solarized Light, One Dark. Each is MIT-licensed and credited in `docs/themes.md` and in its theme file.
- Theme file: JSON with `name`, `appearance` (`dark` | `light`), `base`, `author`, `source` or `credit` (optional), and `colors: { slot: "#RRGGBB" | "#RRGGBBAA" }`. Unknown slots are ignored, and missing slots fall back to `base`.
- User themes live in `<Alloy app support>/Themes/*.json`, honouring `ALLOY_DATA_DIR`. The folder is watched, so a hand edit applies live.
- A theme switch must not rebuild views or reopen files; it only repaints.
- Faithful palettes: use each palette's published colours. Where a published colour fails the existing contrast audit, nudge only its lightness until it passes, and record the original and adjusted value in `docs/themes.md` (§4 anti-goal: an unreadable app).
- Every commit carries the project's usual Co-Authored-By trailer.

## Rulings (the controller's calls inside the spec's latitude)

1. **Theme ids.**
   - Built-ins use `dracula`, `alloy-dark`, `alloy-light`, `solarized-dark`, `solarized-light` and `one-dark`.
   - A user theme's id is `user/<file stem>`.
   - A file's `base` names a built-in id first, then a user file stem.
2. **Session colours.** A top-level `"sessionColors": ["#…", …]` array with 6–12 entries replaces the base theme's list wholesale. Per-slot merging couldn't shrink a list.
   - Alloy has 12 session keys. Key *n* takes `list[(n-1) % count]`.
   - New sessions take `records.count % 12`. Old saved indices (0–7) stay valid.
3. **No base.** A file without a `base` falls back to `alloy-dark` or `alloy-light` by its `appearance`. Those two define every slot.
   - An unknown `base` falls back the same way, with a warning in the library's errors.
   - A base cycle, or a chain deeper than 8, is an error and the theme is skipped.
4. **Broken file while in use.** If the active user theme's file stops parsing, Alloy keeps the last version that loaded during this run and shows the error in Settings.
   - With no last-good version, Alloy uses Dracula, or `alloy-light` for the Light slot.
   - The spec's "falls back to the theme's base" can't be read from a file that doesn't parse.
5. **Built-ins are compiled in** as JSON string literals in `Sources/AlloyCore/Themes/BuiltIn/`. Bundle resources would be the app's first, and `Bundle.module` traps when the packaged app lacks the bundle.
6. **Match-system pickers** list only themes of their appearance. The one-theme picker lists all themes.
   - **One theme:** force `preferredColorScheme` to the theme's appearance, and install it in both slots.
   - **Match system:** clear the forced scheme.
7. **`addedRowTint` / `removedRowTint`** stay aliases of `editAddTint` / `editRemoveTint`. They are not slots.
8. **Text levels.** Secondary and tertiary text stay derived from `textPrimary` until MetalUI G27 lands. Alloy's own muted text is the `mutedInk` slot.

## Review Focus

1. **Editing the active theme file with a typo mid-edit.** Expect no crash and no flash to another theme. The last good version stays, and Settings shows the error. Pinned in Task 4: `brokenActiveFileKeepsLastGood`.
2. **Deleting the active user theme, or a settings.json naming a theme that no longer exists.** Expect a fallback to Dracula with a notice in Settings, and settings.json is not rewritten behind the user's back. Pinned in Task 4: `missingSelectedThemeFallsBackWithNotice`.
3. **Switching theme with tabs open, scrolled, mid-turn.** Expect nothing to reload: same tabs, same scroll, no session relaunch. Pinned in Task 4: `switchingOnlyRepaints`.
4. **Junk in the themes folder** (`.DS_Store`, a 50 MB file, non-JSON, a JSON array, a hex like `#FFF` or `red`). Expect it to be ignored or listed as an error; the app keeps working. Pinned in Task 1: `junkFilesAreSkippedOrReported`.
5. **macOS flipping appearance while in match-system mode, and switching between modes.** Expect the right theme to follow, and leaving one-theme mode to clear the forced scheme. Pinned in Task 4: `matchSystemFollowsAppearanceAndClearsForce`.

---

### Task 1: Theme files and the theme library (AlloyCore)

**Files:**
- Create: `Sources/AlloyCore/Themes/ThemeRGBA.swift`, `Sources/AlloyCore/Themes/ThemeFile.swift`, `Sources/AlloyCore/Themes/ThemeLibrary.swift`, `Sources/AlloyCore/Themes/BuiltIn/BuiltInThemes.swift`
- Test: `Tests/AlloyCoreTests/ThemeFileTests.swift`, `Tests/AlloyCoreTests/ThemeLibraryTests.swift`

**Interfaces:**
- Produces:
  - `public struct ThemeRGBA: Equatable, Hashable, Sendable`, with `r, g, b, a: Double` (0…1).
    - `public init?(hex: String)` accepts exactly `#RRGGBB` and `#RRGGBBAA`, case-insensitive.
    - `public var hex: String` returns uppercase `#RRGGBB`, or `#RRGGBBAA` when `a < 1`.
  - `public enum ThemeAppearance: String, Sendable { case dark, light }`
  - `public struct ThemeFile: Equatable, Sendable` with `name: String`, `appearance: ThemeAppearance`, `base: String?`, `author: String?`, `credit: String?`, `colors: [String: ThemeRGBA]`, `sessionColors: [ThemeRGBA]?`.
    - `public static func parse(_ data: Data) throws(ThemeFileError) -> ThemeFile` reads JSON keys `name`, `appearance`, `base`, `author`, `credit` (or `source` as an alias) and `colors`.
  - `public enum ThemeFileError: Error, Equatable` with cases `.notJSON`, `.missingName`, `.badAppearance(String)`, `.badColor(slot: String, value: String)`, `.sessionColorCount(Int)`, `.tooLarge(Int)`.
    - `public var message: String` gives a one-line, human-readable message.
  - `public struct ThemeEntry: Equatable, Sendable` with `id: String`, `file: ThemeFile`, `isBuiltIn: Bool`, `url: URL?`.
  - `public struct ThemeLoadError: Equatable, Sendable` with `fileName: String` and `message: String`.
  - `public struct ResolvedTheme: Equatable, Sendable` with `id`, `name`, `appearance`, `colors: [String: ThemeRGBA]` (fully merged) and `sessionColors: [ThemeRGBA]`.
  - `public struct ThemeLibrary: Equatable, Sendable` with:
    - `builtIns: [ThemeEntry]`, `user: [ThemeEntry]`, `errors: [ThemeLoadError]`;
    - `public static func userDirectory(appSupport: URL) -> URL`, which returns `appSupport/Alloy/Themes`;
    - `public static func load(builtIns: [ThemeEntry], userDirectory: URL, previous: ThemeLibrary?) -> ThemeLibrary`;
    - `public func entry(_ id: String) -> ThemeEntry?`;
    - `public func resolve(_ id: String) -> ResolvedTheme?`;
    - `public var all: [ThemeEntry]`, which is built-ins in registry order, then user themes sorted by name.
  - `public enum BuiltInThemes { public static var all: [ThemeEntry] }`. Tasks 2 and 3 append to its source list. It parses each literal once and traps in DEBUG on a parse failure.

- [ ] **Step 1: Write the failing tests**
  - `hexParsesSixAndEightDigits`:
    - `ThemeRGBA(hex: "#282a36")` gives `r ≈ 40/255`, `a == 1`.
    - `ThemeRGBA(hex: "#FF000080")!.a ≈ 128/255`.
    - `"#FFF"`, `"red"`, `"282a36"` and `"#GG0000"` give nil.
    - `ThemeRGBA(hex: "#abcdef")!.hex == "#ABCDEF"`.
  - `parseReadsAllFields`: a file using `source` gives `credit` its value. Its `sessionColors` of 6 entries parse.
  - `parseRejects`:
    - missing name → `.missingName`;
    - `"appearance":"dim"` → `.badAppearance("dim")`;
    - `"colors":{"accent":"blue"}` → `.badColor(slot:"accent", value:"blue")`;
    - 5 or 13 session colours → `.sessionColorCount`;
    - `[]` → `.notJSON`.
  - `unknownSlotsAreKept`: `colors["notASlot"]` parses. AlloyKit ignores it later.
  - `baseChainMerges`, using three in-memory entries:
    - `a`: dark, `accent` and `background`;
    - `b`: base `a`, `accent` only;
    - `c`: base `b`.
    - `resolve("user/c")` gives `accent` from `b` and `background` from `a`.
  - `noBaseFallsBackByAppearance`: with built-ins `alloy-dark` and `alloy-light` as test entries, a dark user file without a base inherits `alloy-dark`'s colours.
  - `unknownBaseFallsBackWithError`: the theme resolves using `alloy-dark`, and `errors` contains its file name.
  - `baseCycleIsSkipped`:
    - `x→y→x`: neither resolves, and both are reported.
    - A chain of depth 9 is reported.
  - `userIdsAreNamespaced`: `dracula.json` in the folder gets id `user/dracula`, and `entry("dracula")` is still the built-in.
  - `junkFilesAreSkippedOrReported`: in a temp folder,
    - `.DS_Store`, `notes.txt` and a hidden `.x.json` are ignored;
    - `big.json` over 256 KB is reported `.tooLarge`;
    - `arr.json` = `[]` is reported;
    - `good.json` loads.
  - `brokenFileKeepsPreviousGoodVersion`: load once with a good `t.json`, rewrite it as `{`, and load with `previous:`. Then `user` still contains `user/t` with the old colours, and `errors` names `t.json`.
  - `missingFolderIsEmptyNotAnError`.
- [ ] **Step 2: Run** `swift test --filter "ThemeFileTests|ThemeLibraryTests"`. Expected: FAIL to compile, because the types are missing.
- [ ] **Step 3: Implement** the types above.
  - Use `JSONSerialization` so key order doesn't matter, and `source` aliases `credit`.
  - Read only `*.json`, skip names starting with `.`, and check the size before reading.
  - Resolution walks the `base` links with a visited set and a depth cap of 8, then merges from the root down.
  - When the chain has no `sessionColors`, use the nearest ancestor's list. The root defaults, `alloy-dark`/`alloy-light`, carry 8.
- [ ] **Step 4: Run** the same filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): theme files and library`.

### Task 2: Theme slots, Alloy Dark/Light, and applying a theme (AlloyKit, AlloyHighlight)

**Files:**
- Create:
  - `Sources/AlloyKit/Themes/ThemeSlots.swift`
  - `Sources/AlloyKit/Themes/ThemeApplier.swift`
  - `Sources/AlloyCore/Themes/BuiltIn/AlloyDark.swift`
  - `Sources/AlloyCore/Themes/BuiltIn/AlloyLight.swift`
- Modify:
  - `Sources/AlloyKit/Theme.swift`: the session palette at :172-186 becomes 12 `SessionColorN` keys, with keys 1–8 holding today's values and 9–12 repeating 1–4.
  - `Sources/AlloyHighlight/SyntaxPalette.swift`: one `ThemeColorKey` per token, whose `defaultValue` is today's `Color(light:dark:)`.
  - `Sources/AlloyHighlight/FenceHighlighter.swift`: one shared instance using the dynamic key styles.
  - `Sources/AlloyKit/MarkdownText.swift:94` and `ChatCodeBlock.swift:44`: use the shared instance.
  - `Sources/AlloyCore/Workspace.swift:449,577`: `% 8` becomes `% 12`.
  - `Tests/AlloyKitTests/ThemeGuardTests.swift`: also scan `Sources/AlloyHighlight`, allow-listing `SyntaxPalette.swift`.
- Test: `Tests/AlloyKitTests/ThemeSlotTests.swift`

**Interfaces:**
- Consumes: Task 1's `ThemeRGBA`, `ResolvedTheme`, `ThemeLibrary` and `BuiltInThemes`.
- Produces:
  - `struct ThemeSlot: Sendable` with `name: String` and `purpose: String`. The `purpose` is one line, and Plan 7b's tools and `docs/themes.md` use it.
  - `enum ThemeSlots { static let all: [ThemeSlot] }`, in this order:
    1. MetalUI tokens: `background`, `surface`, `surfaceSecondary`, `accent`, `separator`, `textPrimary`, `scrollIndicator`, `scrim`.
    2. Every Alloy key, by its `Color` static name: `thinkingTint`, `readTint`, `shellTint`, `editAddTint`, `editRemoveTint`, `errorTint`, `warningTint`, `questionTint`, `planTint`, `commandTint`, `webTint`, `thinkingInk`, `readInk`, `shellInk`, `editInk`, `webInk`, `linkInk`, `questionInk`, `planInk`, `errorInk`, `warningInk`, `sidebarFill`, `chatFill`, `panelFill`, `markdownCodeFill`, `markdownQuoteBar`, `markdownRule`, `userAuthor`, `outsideAuthor`, `mutedInk`, `sessionSelection`, `controlBorder`, `codeSelectionFill`, `findMatchFill`, `currentFindMatchFill`.
    3. `syntax.<token>` for every `SyntaxToken` except `plain` and `variable`, which use `textPrimary`.
  - `enum ThemeApplier { static func theme(for resolved: ResolvedTheme) -> Theme }`.
    - Start from `Theme.dark` or `Theme.light` by appearance.
    - Set each token field.
    - Set each key with `theme[Key.self] = Color(Hsla)`.
    - Set `SessionColor1…12` from `sessionColors` by Ruling 2.
    - Ignore unknown slot names.
  - `SyntaxPalette.color(_ token: SyntaxToken) -> Color` returns the key colour.
  - `dynamicStyle(_:)` uses it. `style(_:scheme:)` is removed if nothing else needs it.
  - `alloy-dark` and `alloy-light` define every slot in `ThemeSlots.all` plus 8 `sessionColors`, with exactly today's values. `BuiltInThemes.all` begins with these two.

- [ ] **Step 1: Write the failing tests** in `ThemeSlotTests`.
  - `slotNamesAreUniqueAndPurposed`: no duplicates, and every `purpose` is non-empty.
  - `alloyDarkAndLightDefineEverySlot`: every slot name is in `colors`, and there are 8 session colours.
  - `alloyDarkMatchesTodaysLook` (light and dark):
    - Window A has no theme set. Window B has `ThemeApplier.theme(for: resolve("alloy-dark"))` installed as its `darkTheme`, in dark scheme.
    - For every slot, plus session keys 1–8, the resolved colours in A and B are equal within 1/255.
    - Use ContrastAuditTests' `ColorProbe`/`ResolvedBox` resolution approach.
  - `applierSetsKeysTokensAndSyntax`: a resolved theme with `accent #FF0000`, `thinkingInk #00FF00` and `syntax.keyword #0000FF` resolves to those colours in a window.
  - `sessionColorsCycle`: with 6 session colours, key 7 equals key 1, and key 12 equals key 6.
  - `fenceHighlighterFollowsTheTheme`: render a ```` ```swift ```` fenced block in a dark window with `darkTheme[syntax.keyword key]` set to `#0000FF`. The `func` glyph run resolves to that colour.
    - If MetalUI caches the resolved fence styles so this can't pass, STOP and report it as a MetalUI gap. Don't build a per-theme highlighter cache.
  - `newSessionsUseTwelveColours`: the 9th new session gets `colorIndex == 8`.
- [ ] **Step 2: Run** `swift test --filter "ThemeSlotTests|ThemeGuardTests|ContrastAuditTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Write the two built-in JSON literals. Their hex values come from `Theme.swift`, MetalUI `Theme.light`/`.dark` and `SyntaxPalette`.
  - Write the slot table: one entry per slot, holding its name, purpose and setter.
  - Write the applier, the syntax keys and the session keys.
  - Keep the ContrastAudit and ThemeGuard tests green. The audit's syntax pairs now read through the key colours.
- [ ] **Step 4: Run** the full `swift test`. Expected: PASS, all three counts, no warnings.
- [ ] **Step 5: Commit** `feat(kit): theme slots, Alloy Dark/Light built-ins, theme applier`.

### Task 3: Dracula, Solarized Dark/Light, One Dark, and the per-theme contrast audit

**Files:**
- Create:
  - `Sources/AlloyCore/Themes/BuiltIn/Dracula.swift`
  - `SolarizedDark.swift`, `SolarizedLight.swift`, `OneDark.swift`, also in `Sources/AlloyCore/Themes/BuiltIn/`
  - `docs/themes.md`
- Modify:
  - `BuiltInThemes.swift`: the order is `dracula`, `alloy-dark`, `alloy-light`, `solarized-dark`, `solarized-light`, `one-dark`.
  - `Tests/AlloyKitTests/ContrastAuditTests.swift`: run every existing `.alloy` pair once per built-in, in that theme's appearance.
- Test: `Tests/AlloyKitTests/BuiltInThemeTests.swift`

**Interfaces:**
- Consumes: `ThemeSlots.all`, `ThemeApplier`, `BuiltInThemes`.
- Produces: four more built-ins, each with `credit` and `author` set. `docs/themes.md` holds the file format, every slot with its purpose, the credits and licences, and the contrast adjustments.

**Published palettes to map from (use these exact values):**
- **Dracula** (MIT, draculatheme.com):
  - Background `#282A36`, Current Line `#44475A`, Foreground `#F8F8F2`, Comment `#6272A4`
  - Cyan `#8BE9FD`, Green `#50FA7B`, Orange `#FFB86C`, Pink `#FF79C6`, Purple `#BD93F9`, Red `#FF5555`, Yellow `#F1FA8C`
- **Solarized** (MIT, Ethan Schoonover):
  - base03 `#002B36`, base02 `#073642`, base01 `#586E75`, base00 `#657B83`
  - base0 `#839496`, base1 `#93A1A1`, base2 `#EEE8D5`, base3 `#FDF6E3`
  - yellow `#B58900`, orange `#CB4B16`, red `#DC322F`, magenta `#D33682`, violet `#6C71C4`, blue `#268BD2`, cyan `#2AA198`, green `#859900`
  - Dark uses base03/base02 backgrounds and base0 text. Light uses base3/base2 backgrounds and base00 text.
- **One Dark** (MIT, Atom one-dark-syntax):
  - bg `#282C34`, fg `#ABB2BF`, gutter `#4B5263`, selection `#3E4451`, comment `#5C6370`
  - red `#E06C75`, green `#98C379`, yellow `#E5C07B`, blue `#61AFEF`, purple `#C678DD`, cyan `#56B6C2`, orange `#D19A66`

**Mapping guide** (the slot-by-slot choice is the builder's, per the spec §8):
- **Backgrounds:** chat, panel and sidebar take the palette's background shades, darkest or lightest first.
- **Inks:** take the palette's accent hues by meaning. Error is red, warning is yellow or orange, edit is green, web and link are blue, plan and question are purple or violet, read is cyan.
- **Tints:** each is its ink mixed into `chatFill` at about 18%.
- **Syntax:** use each palette's published token mapping. Dracula, for example: keyword pink, string yellow, function green, type cyan, number purple, comment Comment.
- **Session colours:** 8 distinct palette hues.

- [ ] **Step 1: Write the failing tests** in `BuiltInThemeTests`.
  - `sixBuiltInsInOrder`: the ids and order above, and `dracula` comes first.
  - `everyBuiltInIsCreditedAndParses`: `credit` and `author` are non-empty, and every slot resolves.
  - `paletteAnchorsAreFaithful`:
    - Dracula's `chatFill` is `#282A36`, `syntax.keyword` is `#FF79C6` and `syntax.string` is `#F1FA8C`.
    - Solarized Dark's `chatFill` is `#002B36`.
    - Solarized Light's `chatFill` is `#FDF6E3`.
    - One Dark's `chatFill` is `#282C34`.
    - If an anchor had to be nudged for contrast, assert the documented adjusted value instead, and make sure it appears in `docs/themes.md`.
  - `docsListEverySlotAndCredit`: `docs/themes.md` contains every `ThemeSlots.all` name and each built-in's credit line.
  - In ContrastAuditTests, `everyBuiltInMeetsWCAGAA(themeID:)`, parameterised over the six ids. It is the same pair list and minimums as `everyPairMeetsWCAGAA`, resolved in a window whose scheme slot holds that theme.
- [ ] **Step 2: Run** `swift test --filter "BuiltInThemeTests|ContrastAuditTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** the four JSON literals and `docs/themes.md`.
  - Iterate until the audit passes, adjusting only lightness, and record every adjustment as `slot: published → used`.
- [ ] **Step 4: Run** the full `swift test`. Expected: PASS, warning-free.
- [ ] **Step 5: Commit** `feat: Dracula, Solarized, One Dark built-in themes; per-theme contrast audit`.

### Task 4: Choosing, applying and live-reloading the theme

**Files:**
- Create: `Sources/AlloyKit/Themes/ThemeController.swift`, `Sources/AlloyKit/Themes/ThemeHost.swift`
- Modify:
  - `Sources/AlloyCore/Model/AlloySettings.swift`: add fields, `CodingKeys` and `decodeIfPresent` defaults.
  - `Sources/Alloy/main.swift`: create the controller with `App` as the host and an `FSEventsSource` on the themes folder.
- Test: `Tests/AlloyKitTests/ThemeControllerTests.swift`

**Interfaces:**
- Consumes: `ThemeLibrary`, `BuiltInThemes`, `ThemeApplier`, `FileChangeSource`/`FSEventsSource` (`Sources/AlloyCore/Editor/FileWatcher.swift`), and `Workspace.settings` / `updateSettings(_:)`.
- Produces:
  - `public enum ThemeMode: String, Codable, Sendable { case single, matchSystem }`
  - On `AlloySettings`:
    - `themeMode: ThemeMode = .single`
    - `theme: String = "dracula"`
    - `lightTheme: String = "alloy-light"`
    - `darkTheme: String = "dracula"`
  - `@MainActor protocol ThemeHost: AnyObject { var lightTheme: Theme { get set }; var darkTheme: Theme { get set }; var preferredColorScheme: ColorScheme? { get set } }`. `App` and `Window` conform through extensions; check that the property names match MetalUI.
  - `@MainActor @Observable final class ThemeController` with:
    - `init(workspace: Workspace, host: ThemeHost, watcher: FileChangeSource?)`
    - `private(set) var library: ThemeLibrary`
    - `private(set) var notice: String?`
    - `func apply()`
    - `func reload()`
    - `func choose(mode: ThemeMode? = nil, theme: String? = nil, light: String? = nil, dark: String? = nil) throws`, which writes through `workspace.updateSettings` and then calls `apply()`
    - `func backToDracula() throws`, which is `choose(mode: .single, theme: "dracula")`
    - `func openThemesFolder(using open: (URL) -> Void)`, which creates the folder if it's missing
  - **Apply rules:**
    - `.single`: install the resolved theme as both `host.lightTheme` and `host.darkTheme`, and set `host.preferredColorScheme` to its appearance.
    - `.matchSystem`: set `host.preferredColorScheme = nil`, with `lightTheme` from `settings.lightTheme` (fallback `alloy-light`) and `darkTheme` from `settings.darkTheme` (fallback `dracula`).
    - A fallback sets `notice` to `Theme "<id>" isn't available; using Dracula.` (or Alloy Light). Settings is not rewritten.

- [ ] **Step 1: Write the failing tests**, using a `TestWindow` as the host and a fake `FileChangeSource` that yields on demand.
  - `defaultIsDraculaForcedDark`: fresh settings give a dark forced scheme, and the window's `chatFill` resolves to Dracula's.
  - `oldSettingsFileDecodesWithThemeDefaults`: a settings.json without theme keys decodes to `.single` and `dracula`, and its other fields are intact.
  - `matchSystemFollowsAppearanceAndClearsForce`:
    - Choose `.matchSystem` with light `solarized-light` and dark `one-dark`. Then `preferredColorScheme == nil`.
    - `setAppearance(.light)` gives Solarized Light's `chatFill`, and `.dark` gives One Dark's.
    - Choosing `.single` again forces the scheme.
  - `missingSelectedThemeFallsBackWithNotice`: settings name `user/gone`. Dracula is applied, `notice` contains `user/gone`, and the settings.json bytes are unchanged.
  - `liveEditAppliesWithoutRestart`: the active theme is `user/mine`. Rewrite `mine.json` with a new `accent` and fire the fake watcher. The window's accent resolves to the new value.
  - `brokenActiveFileKeepsLastGood`: rewrite the active file as `{"name":`. The colours are unchanged, and `library.errors` names `mine.json`.
  - `switchingOnlyRepaints`:
    - Set up a session mid-turn with a fake transport, a file open in a tab, and the code view scrolled to line 200.
    - `choose(theme: "one-dark")`.
    - The same tabs are open, the same first visible line shows, there is no session relaunch (the relaunch counter is unchanged), and the `Workspace.settingsGeneration` relaunch path is not taken for theme-only changes.
  - `themeChangesDoNotRelaunchSessions`: `updateSettings` with only theme fields changed relaunches nothing.
  - `openThemesFolderCreatesIt`: the folder exists afterwards, and the opener received its URL.
- [ ] **Step 2: Run** `swift test --filter ThemeControllerTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Watch the user directory with the given `FileChangeSource`. Any event calls `reload()` (load with `previous: library`), then `apply()`.
  - In `main.swift`, create the controller after the workspace, pass `FSEventsSource(root: ThemeLibrary.userDirectory(appSupport:))`, and call `apply()` before the first window opens.
- [ ] **Step 4: Run** the full `swift test`. Expected: PASS, warning-free.
- [ ] **Step 5: Commit** `feat: theme controller with match-system, fallbacks and live reload`.

### Task 5: Settings theme section and docs

**Files:**
- Modify: `Sources/AlloyKit/SettingsView.swift` (a theme section at the top, above the claude path), `README.md` (a Themes section), `docs/superpowers/plans/2026-11-07-alloy-roadmap.md` (7a status)
- Create: `Sources/AlloyKit/Themes/ThemeRow.swift`
- Test: `Tests/AlloyKitTests/SettingsThemeTests.swift`

**Interfaces:**
- Consumes: `ThemeController` (`library`, `notice`, `choose`, `backToDracula`, `openThemesFolder`) and `AlloySettings` theme fields.
- Produces:
  - **Section and mode:**
    - `settings-theme-section` (the section container).
    - `settings-theme-mode`: a segmented picker with "One theme" and "Match system".
  - **Theme lists:**
    - One theme: a list `settings-theme-list` of every theme.
    - Match system: two lists, `settings-theme-list-light` (light themes only) and `settings-theme-list-dark` (dark only).
    - Each row is a `ThemeRow` button, `theme-row-<id>` in single mode, or `theme-row-light-<id>` / `theme-row-dark-<id>` in match mode. A row has:
      - a swatch strip of five 12×12 squares: `chatFill`, `accent`, `syntax.keyword`, `syntax.string` and the first session colour;
      - the theme's name;
      - "Built-in", or the author, in `mutedInk`;
      - a checkmark when selected.
  - **Notices and errors:**
    - `settings-theme-notice` shows `controller.notice` when it's set.
    - `settings-theme-error-<fileName>` shows one row per `library.errors` entry, in `errorInk`.
  - **Buttons:** `settings-open-themes` ("Open themes folder") and `settings-back-to-dracula` ("Back to Dracula").
  - **Unchanged:** every existing settings id (`existingSettingsIdsStillWork` stays green).

- [ ] **Step 1: Write the failing tests** in `SettingsThemeTests`.
  - `sectionShowsAllThemesWithDraculaChecked`: there are six rows, `theme-row-dracula` is selected, and each row's accessibility label contains the theme's name.
  - `clickingARowAppliesIt`: clicking `theme-row-one-dark` changes the window's `chatFill`, and settings.json has `"theme":"one-dark"`.
  - `matchSystemShowsTwoFilteredLists`:
    - After choosing "Match system", the light list holds `alloy-light` and `solarized-light` only, and the dark list holds the four dark themes.
    - Selection checkmarks follow the settings.
  - `userThemeAppearsAfterDrop`: write a light `paper.json` and fire the watcher. `theme-row-user/paper` appears, under the light list in match mode.
  - `errorsAndNoticeShow`: a broken file gives an error row, and a missing selected theme gives `settings-theme-notice`.
  - `backToDraculaRestores`: from match mode with other themes, clicking it gives single mode, Dracula, and a dark forced scheme.
  - `openThemesFolderUsesOpener`: the injected opener receives the themes URL.
  - `rowsFitAtMinimumWidth`: at the minimum settings width, no row label overlaps its swatch strip.
- [ ] **Step 2: Run** `swift test --filter "SettingsThemeTests|SettingsViewTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** the section and `ThemeRow`, using theme tokens only, then the docs.
  - **README:** a Themes section covering the built-ins, picking, the user themes folder path (`~/Library/Application Support/Alloy/Themes`, or `$ALLOY_DATA_DIR/Alloy/Themes`), and a link to `docs/themes.md`. Note that making themes with Claude (`/theme`) is coming in 7b.
  - **Roadmap:** 7a is "implemented; hands-on check pending".
- [ ] **Step 4: Run** the full `swift test` and `swift build -c release`. Expected: PASS, with 0 warnings.
- [ ] **Step 5: Commit** `feat(ui): theme picker in Settings; docs`.
