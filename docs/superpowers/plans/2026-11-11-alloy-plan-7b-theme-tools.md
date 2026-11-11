# Plan 7b: Themes, step 2 (making themes with Claude) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `/theme [description]` (and Settings' "Make a theme with Claude…") starts a "Theme: …" session that has the theme-making guidance and five theme tools on Alloy's MCP server. Claude drafts a theme, previews it live on the whole app, checks contrast and saves it. Only the user activates it, through Keep in a preview bar or the Settings picker, with a warning when colour pairs are hard to read. In every built-in, the selected segment of a segmented picker is outlined at 3:1 against its track and against the thumb.

**Architecture:**
- **AlloyCore** gets four things:
  - tool scopes on the loopback MCP server, so a session's bearer token decides which tools it sees;
  - a pure contrast check over a resolved theme (`ThemeContrast`);
  - a theme store that saves user theme files with clash renaming and per-session ownership (`ThemeStore`);
  - the five theme tools. The tools reach the UI side through a `@MainActor` protocol, `ThemeWorkshop`, that `Workspace` holds weakly.
- **Workspace** gives sessions a `purpose` (`coding` or `theme`). A theme session's token carries the theme scope, its launch appends the theme guidance, and its end ends any preview it started.
- **AlloyKit:** `ThemeController` conforms to `ThemeWorkshop`. It installs a preview on the host without touching settings, and it owns Keep, Discard and the activation warning. A bar above the chat shows the preview state.

**Tech Stack:** Swift 6.1, SwiftPM, MetalUI (sibling `../MetalUI`, read-only), Swift Testing, CryptoKit (SHA-256 for ownership).

**Spec:** `docs/superpowers/specs/2026-11-09-alloy-themes-design.md` (approved 2026-11-09, binding). This plan is step 2 of its §7. Step 1 shipped as `docs/superpowers/plans/2026-11-09-alloy-plan-7a-themes.md`; read its Rulings, which still hold (theme ids, `user/<stem>`, session-colour lists, base fallback).

## Global Constraints

- MetalUI only. Theme tokens only, never inline hex in AlloyKit views (`ThemeGuardTests`). Every interactive view gets an accessibility identifier.
- Never write to `~/.claude` or a project's `.claude/`. The theme "skill" ships as Alloy's own session guidance plus MCP tools; the repo copy in `docs/` is for people to install themselves.
- Never pass `--bare`, `--permission-mode` or `--setting-sources` to the claude CLI.
- `updatedPermissions`, if any code sends it, only with the `session` or `cliArg` destination.
- Never brand anything "Claude Code" (code, copy, guidance, docs, tool descriptions).
- MetalUI gaps are written up in `docs/metalui-gaps.md` as requests to forward to the MetalUI session. Never edit `../MetalUI`.
- Tests that hold a DB lock use short timeouts (the injectable pool busy timeout, 50 ms, as in Plan 5c).
- Swift Testing only. Zero warnings in `swift build`, `swift test` and `swift build -c release`.
- Implementers never launch the GUI app. Tests drive `TestWindow` and `ScriptedTransport` only.
- The theme tools touch only Alloy's theme state and themes folder. They are pre-approved by exact name unless "Ask before sessions use Alloy's tools" (`askBeforeSharedNotes`) is on (spec §6.3).
- `theme_save` never makes a theme active. Only the user does, through Keep or the Settings picker (spec §6.3a).
- `theme_save` never overwrites a built-in, or a user theme that the user or another session made. A clash is saved as "<name> 2" (then 3, …). A session may overwrite only files it saved itself and that are unchanged since (spec §6.3a).
- A discarded preview leaves no trace. `settings.json` and the themes folder are unchanged by preview and Discard (spec §4).
- WCAG AA minimums: 4.5:1 for normal text, 3:1 for large text and UI (spec §2.6).
- Guidance wording is under about 200 words.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and the `Claude-Session:` trailer line the controller gives in its brief. The session URL is never written into any tracked file.

## Rulings (the controller's calls inside the spec's latitude)

1. **Tool names:**
   - `theme_slots`
   - `theme_read`
   - `theme_check`: an extra tool. The spec's goals list "check its contrast" as its own action, and checking without repainting the app is cheaper for the model.
   - `theme_preview`
   - `theme_save`

   Full names are `mcp__alloy__theme_*`.
2. **Theme tools do not depend on sharing.** A theme session gets the theme scope even with "Share knowledge" off. Its token then carries only `.theme`: no notes tools, no hooks, no notes guidance. If the server can't start, the session launches without tools and shows the notice `Theme tools are unavailable: Alloy's local server is not running.`
3. **First message.** `/theme warm, low contrast` creates the session and sends `warm, low contrast` as its first user message. Bare `/theme` and the Settings button send `Help me make an Alloy theme.` (stream-json waits for input, so a session with no first message would sit silent.) The `/theme` text itself is not added to the session it was typed in.
4. **Session name.** `Theme: <description>`, with the description trimmed and cut to 40 characters plus `…`, or `Theme: new` when there is none. The name goes through `allowedName`.
5. **Purpose is persisted.** `SessionRecord.purpose` makes a theme session restored after a restart, relaunched after a settings change, or forked still get the theme scope and guidance.
6. **One preview at a time, app-wide.**
   - A newer `theme_preview` from any theme session replaces the current one.
   - The preview forces the scheme to the draft's appearance and installs the draft in both host slots, whatever the theme mode.
   - Discard, or the owning session ending (stopped, exited, failed to launch, Alloy quitting), runs `apply()`, which restores the user's theme. A theme the session had already saved stays in the picker.
   - A themes-folder reload while previewing keeps the preview on screen. Discard then shows the reloaded user theme.
7. **Keep.**
   - If the previewed draft is unsaved, Keep saves it first, through `ThemeStore`, owned by the previewing session.
   - It then activates the theme: in `.single` mode it sets `theme`; in `.matchSystem` mode it sets `lightTheme` or `darkTheme` by the draft's appearance.
   - Activation goes through the contrast warning (Ruling 9).
   - "Saved" means a `theme_save` from the same session whose file equals the previewed draft, comparing `appearance`, `base`, `colors` and `sessionColors`.
8. **Ownership.**
   - `<appSupport>/Alloy/theme-owners.json` maps a file stem to `{ "session": "<uuid>", "sha256": "<hex of the bytes written>" }`.
   - Overwriting is allowed only when the owner is the calling session and the file on disk still has that hash. A hand edit makes the file the user's.
   - The owners file lives outside `Themes/`, so writing it never wakes the folder watcher.
9. **Activation warning.**
   - When the user activates a theme with contrast findings (Keep, or a row click in Settings), the controller doesn't apply it. It sets `pendingActivation`, and a strip shows `3 colour pairs are hard to read` (singular: `1 colour pair is hard to read`) with "Use anyway" and "Cancel".
   - Built-ins have no findings, so they never warn. `choose(...)` stays the unconditional API (tests, Back to Dracula). The new `request(...)` is the checked one.
10. **Draft input.**
    - `theme_preview`, `theme_check` and `theme_save` take `theme`: a JSON object in the theme-file format, or a string holding one.
    - `theme_save`'s `name` argument replaces the draft's `name`.
    - `author` defaults to `Made in an Alloy theme session`.
    - Unknown slots are reported back as `ignoredSlots`, not as errors.
11. **What `theme_slots` returns as "current values".** The theme the app shows right now: the preview when one is active, else the user's active theme for the current appearance.
12. **Picker thumb edge (user decisions, 2026-11-11).**
    - **Decision 1:** the selected segment is outlined by a themeable thumb edge. The track fill isn't darkened.
    - **Decision 2:** all six built-ins get their own edge colour, at 3:1 or better against both the track and the thumb. The contrast audit enforces this, with no exemptions and no "known gap".
    - **Why not darken the track.** In Alloy Light the thumb measures 1.24:1 against the track (`#FFFFFF` on `#E4E7EC`). Fixing that through the fill would take `surfaceSecondary` to about `#8F8F8F`, which breaks `textSecondary` and the tab ink on the same fill (about 2.4:1 where 4.5:1 is needed).
    - **The thumb**, for these checks, is the audit's existing `pill`:
      - light: `surface`;
      - dark: `textPrimary` at 0.18 over `surfaceSecondary`.
    - **Dependency.** This needs MetalUI G31 (`SegmentedThumbEdge`, default today's colour). It has been forwarded to the MetalUI session. Task 8 STOPs and reports if the key hasn't landed when it runs.

## Review Focus

1. **Garbage drafts.** Inputs: a non-object `theme`, a string that isn't JSON, a 300 KB draft, `#FFF` colours, 5 session colours, `appearance: "dim"`, a `base` that names nothing.
   - Expect an `isError` tool result with the parse message, and no change to the screen or the folder. An unknown base resolves by appearance, with a note in the result.
   - Pinned in Task 4: `badDraftsAreRefusedWithoutSideEffects`.
2. **Hostile or clashing names.** Inputs: `../../x`, `""`, `Dracula`, `dracula`, `alloy-light`, emoji only, a name the user already has a file for, and a second session reusing the first session's name.
   - Expect a file inside `Themes/` only, built-ins and others' files untouched, and a "<name> 2" style rename reported as `renamed: true`.
   - Pinned in Task 3: `namesAreSlugsInsideTheFolder` and `clashesAreRenamed`.
3. **The session ends mid-preview.** Cases: stopped, the process crashes, launch fails, Alloy quits.
   - Expect the user's theme to come back, with `settings.json` byte-identical.
   - Pinned in Task 6: `sessionEndRestoresTheUsersTheme`.
4. **An ordinary session reaching the theme tools.** A coding session's token calls `tools/call theme_save`, and `tools/list` is checked.
   - Expect "Unknown tool" and no theme tools listed. A theme session that is restored, relaunched or forked keeps them.
   - Pinned in Tasks 1 and 5: `toolsOutsideTheCallersScopeAreInvisible` and `themePurposeSurvivesRestoreRelaunchAndFork`.
5. **The user's own theme file edited while a preview shows.**
   - Expect the preview to stay up. Discard shows the edited theme. A later `theme_save` by the session to that name now saves as "<name> 2", because the hash changed.
   - Pinned in Tasks 3 and 6: `handEditedFileIsNoLongerOwned` and `reloadDuringPreviewKeepsPreview`.

---

### Task 1: Tool scopes on the local MCP server

**Files:**
- Modify:
  - `Sources/AlloyCore/Coordination/MCPServer.swift`
  - `Sources/AlloyCore/Coordination/LocalServer.swift`
- Test: `Tests/AlloyCoreTests/MCPServerTests.swift`

**Interfaces:**
- Produces:
  - `public enum MCPToolScope: String, Sendable, Hashable { case shared, theme }`
  - `MCPTool` gains a requirement `var scope: MCPToolScope { get }`, with an extension default of `.shared`, so the notes and coordination tools are unchanged.
  - `MCPCaller` gains `public let scopes: Set<MCPToolScope>`. The init is `init(sessionID: UUID, scopes: Set<MCPToolScope> = [.shared])`.
  - `LocalServer.token(for session: UUID, scopes: Set<MCPToolScope> = [.shared]) -> String`:
    - the token is stable per session as today;
    - a repeat call replaces the stored scopes;
    - `revoke(session:)` drops them;
    - the caller built from a bearer token carries its scopes.
  - `MCPServer.handle`: `tools/list` lists only tools whose `scope` is in `caller.scopes`. `tools/call` of a tool outside them answers exactly like an unknown name: `-32602`, `Unknown tool: <name>`.

- [ ] **Step 1: Write the failing tests** in `MCPServerTests`, using a `.theme`-scoped test tool:
  - `toolsOutsideTheCallersScopeAreInvisible`:
    - With a `[.shared]` token, `tools/list` has no `.theme` tool, and `tools/call` of it gives error code `-32602` with message `Unknown tool: <name>`.
    - With a `[.shared, .theme]` token, both are listed and callable.
    - With a `[.theme]` token, the shared tools are missing.
  - `scopesFollowTheLatestTokenCall`: `token(for: id, scopes: [.shared])`, then `token(for: id, scopes: [.theme])`. The same string is returned, and the list now shows only theme tools.
  - `revokeDropsScopes`: after revoke and a fresh `token(for:)`, the scopes are `[.shared]`.
- [ ] **Step 2: Run** `swift test --filter MCPServerTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement** as above. `LocalServer` keeps `sessionScopes: [UUID: Set<MCPToolScope>]`.
- [ ] **Step 4: Run** `swift test --filter "MCPServerTests|NotesToolsTests|CoordinationToolsTests|HookServerTests"`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): scope MCP tools by session token`.

### Task 2: The contrast check (`ThemeContrast`)

**Files:**
- Create: `Sources/AlloyCore/Themes/ThemeContrast.swift`
- Modify: `Sources/AlloyCore/Themes/ThemeLibrary.swift` (resolving a draft)
- Test:
  - `Tests/AlloyCoreTests/ThemeContrastTests.swift`
  - `Tests/AlloyKitTests/BuiltInThemeTests.swift` (one test added)

**Interfaces:**
- Consumes: `ResolvedTheme`, `ThemeRGBA`, `ThemeLibrary`, `ThemeFile`.
- Produces:
  - `public struct ContrastFinding: Equatable, Sendable, Codable` with:
    - `pair: String`, e.g. `"mutedInk on readTint"`, or `"syntax.keyword on surface over codeSelectionFill"` for layers;
    - `foreground: String`, `layers: [String]`, `ratio: Double` (2 decimals), `minimum: Double`.
  - `public enum ThemeContrast` with:
    - `public static func findings(_ theme: ResolvedTheme) -> [ContrastFinding]`, in table order;
    - `public static func ratio(_ a: ThemeRGBA, _ b: ThemeRGBA) -> Double`: WCAG 2.1, with the same math as `ContrastAuditTests` (sRGB threshold 0.03928);
    - `static func composite(_ layers: [ThemeRGBA]) -> ThemeRGBA`: bottom first, over white.
  - On `ThemeLibrary`:
    - `public func resolve(draft: ThemeFile, id: String = "draft") -> (theme: ResolvedTheme, notes: [String])`, which merges the draft over its `base` chain like `resolve(_:)`;
    - an unknown or missing base falls back by appearance (7a Ruling 3) and adds the note `Unknown base "<x>"; using alloy-dark.` (or `alloy-light`).
  - **Pair table**: the spec's three groups, mirroring the audit's tiers. A pair is skipped when one of its slots is missing from the resolved colours.
    - **Text on backgrounds:**
      - `textPrimary`, `mutedInk` and secondary on each of `background`, `surface`, `sidebarFill`, `chatFill`, `panelFill` and `markdownCodeFill`, at 4.5.
      - `textPrimary` and secondary on `surfaceSecondary`, at 4.5.
      - "Secondary" is `textSecondary` when set, else `textPrimary` at alpha 0.588 (light) or 0.648 (dark), MetalUI's derivation.
    - **Text on tints:** `textPrimary` and `mutedInk` on each of the 11 tints (`thinkingTint` … `webTint`), at 4.5.
    - **Code:**
      - `textPrimary` on `markdownCodeFill` and on `surface`, at 4.5.
      - Every `syntax.*` slot on `markdownCodeFill` and on `surface`, at 4.5 (`syntax.comment` at 3).
      - Every `syntax.*` slot on `editAddTint` and `editRemoveTint`, and on `surface` over `codeSelectionFill`, at 3.
    - **Inks on tints:**
      - At 3: `thinkingInk/thinkingTint`, `readInk/readTint`, `shellInk/shellTint`, `editInk/editAddTint`, `webInk/webTint`, `questionInk/questionTint` and `planInk/planTint`.
      - At 4.5: `errorInk/errorTint`, `warningInk/warningTint`, `linkInk` on `chatFill` and on `markdownCodeFill`, and `errorInk` on `panelFill`.
    - **Session colours:** each session colour on `sidebarFill`, at 3, named `sessionColors[i]`.

- [ ] **Step 1: Write the failing tests.**
  - `ratioIsWCAG`:
    - black on white is 21;
    - white on white is 1;
    - `#767676` on white is 4.54 ± 0.01.
  - `translucentLayersComposite`: `#000000` at alpha 0.5 over white composites to about `#808080`.
  - `lowContrastPairsAreReported`: a draft based on `dracula` with `mutedInk #3A3C4E` reports `mutedInk on chatFill` with `minimum == 4.5` and `ratio < 4.5`.
  - `derivedSecondaryIsChecked`: a light draft without `textSecondary` and with `textPrimary #999999` reports a secondary pair.
  - `draftResolvesOverBase`: a draft with `base: "one-dark"` and only `accent` gives One Dark's `chatFill`. An unknown base yields the fallback note.
  - In `BuiltInThemeTests`, `builtInsHaveNoContrastFindings`: every built-in id gives `ThemeContrast.findings == []`.
    - If one fails, align the table's tier for that pair with the audit's `relaxedForBuiltIn` (the audit already passes every built-in).
    - Never change a built-in's colours here.
- [ ] **Step 2: Run** `swift test --filter "ThemeContrastTests|BuiltInThemeTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** the types and the table above.
- [ ] **Step 4: Run** the same filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): theme contrast check`.

### Task 3: Saving user themes (`ThemeStore`)

**Files:**
- Create: `Sources/AlloyCore/Themes/ThemeStore.swift`
- Modify: `Sources/AlloyCore/Themes/ThemeFile.swift` (encoding)
- Test: `Tests/AlloyCoreTests/ThemeStoreTests.swift`

**Interfaces:**
- Consumes: `ThemeFile`, `ThemeEntry`, `ThemeLibrary.userDirectory(appSupport:)`.
- Produces:
  - `ThemeFile.encoded() -> Data`: pretty-printed with sorted keys. It writes `name`, `appearance`, `base`, `author` and `credit` (the latter three when non-nil), `colors` as uppercase hex, and `sessionColors`. It round-trips through `ThemeFile.parse`.
  - `public struct SavedTheme: Equatable, Sendable` with `id: String` (`user/<stem>`), `name: String`, `url: URL` and `renamed: Bool`.
  - `public struct ThemeStore: Sendable`:
    - `init(appSupport: URL)`, where `directory` is `ThemeLibrary.userDirectory(appSupport:)` and the owners file is `<appSupport>/Alloy/theme-owners.json`;
    - `static func slug(_ name: String) -> String`: lowercase ASCII letters and digits, every other run becomes `-`, trimmed of `-`, at most 64 characters, `theme` when empty;
    - `func save(_ file: ThemeFile, name: String, session: UUID, builtIns: [ThemeEntry]) throws -> SavedTheme`;
    - `func owns(_ id: String, session: UUID) -> Bool`.
  - **Save rules:**
    - The candidate name is `name` trimmed, or `Theme` when empty.
    - A candidate clashes when either:
      - its slug, or its lowercased name, equals a built-in id or a built-in name's slug;
      - `<slug>.json` exists and this session doesn't own it (Ruling 8).
    - On a clash, try `"<name> 2"`, `"<name> 3"`, … up to 99, then throw.
    - Write atomically. The file's `name` is the final name. Record the owner and the SHA-256 of the written bytes.

- [ ] **Step 1: Write the failing tests** (temp app support, as in `ThemeLibraryTests`).
  - `encodedRoundTrips`: parse(encoded(file)) equals the file.
  - `namesAreSlugsInsideTheFolder`:
    - `"../../x"` gives slug `x`.
    - `"Warm Paper!"` gives `warm-paper`.
    - `""` and `"🔥"` give `theme`.
    - Every saved url's parent is the themes directory.
  - `clashesAreRenamed`:
    - Saving `"Dracula"` gives name `Dracula 2`, id `user/dracula-2` and `renamed == true`.
    - A user-made `paper.json` (no owner entry) plus a save of `"Paper"` gives `Paper 2`, and `paper.json` is byte-identical.
    - Session B saving `"Mine"` after session A saved it gives `Mine 2`.
  - `ownerMayOverwriteOwnFile`: session A saves `"Mine"` twice. Both are `user/mine`, `renamed == false`, and the second content is on disk.
  - `handEditedFileIsNoLongerOwned`: after A saves `"Mine"`, append a space to the file. A's next save of `"Mine"` gives `Mine 2`.
  - `ownersSurviveANewStore`: a fresh `ThemeStore` on the same app support still lets A overwrite.
- [ ] **Step 2: Run** `swift test --filter ThemeStoreTests`. Expected: FAIL.
- [ ] **Step 3: Implement** with `CryptoKit.SHA256`. A missing or corrupt owners file reads as empty, so nothing is owned.
- [ ] **Step 4: Run** `swift test --filter "ThemeStoreTests|ThemeFileTests|ThemeLibraryTests"`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): save user themes with clash renaming and session ownership`.

### Task 4: The theme tools and `ThemeWorkshop`

**Files:**
- Create:
  - `Sources/AlloyCore/Themes/ThemeWorkshop.swift`
  - `Sources/AlloyCore/Themes/ThemeTools.swift`
- Modify:
  - `Sources/AlloyCore/Model/Workspace.swift`: `themeWorkshop`, `themeTools`, and the server tool list at `startServer`.
  - `Sources/AlloyCore/Knowledge/Guidance.swift`: `themeToolNames`.
- Test: `Tests/AlloyCoreTests/ThemeToolsTests.swift`

**Interfaces:**
- Consumes:
  - Task 1's `MCPToolScope` and `MCPCaller`;
  - Task 2's `ThemeContrast` and `resolve(draft:)`;
  - Task 3's `ThemeStore` and `SavedTheme`;
  - `WorkspaceRef` (`NotesTools.swift`).
- Produces:
  - `public struct ThemeSlotInfo: Equatable, Sendable { public let name: String; public let purpose: String }`
  - `@MainActor public protocol ThemeWorkshop: AnyObject` with:
    - `var slotCatalog: [ThemeSlotInfo] { get }`
    - `var library: ThemeLibrary { get }`
    - `var shownTheme: ResolvedTheme? { get }` (Ruling 11)
    - `func preview(_ draft: ThemeFile, resolved: ResolvedTheme, session: UUID)`
    - `func didSave(_ saved: SavedTheme, file: ThemeFile, session: UUID) async`, which reloads the library and marks the preview saved (Ruling 7)
    - `func themeSessionEnded(_ session: UUID)`
  - On `Workspace`:
    - `@ObservationIgnored public weak var themeWorkshop: ThemeWorkshop?`
    - `@ObservationIgnored public private(set) var themeTools: [MCPTool]`, built in `init` with `ThemeTools.make(workspace:)`
    - `startServer` passes `notesTools + coordinationTools + themeTools`.
  - `Guidance.themeToolNames`: `["mcp__alloy__theme_slots", "mcp__alloy__theme_read", "mcp__alloy__theme_check", "mcp__alloy__theme_preview", "mcp__alloy__theme_save"]`.
  - `enum ThemeTools { static func make(workspace: Workspace) -> [MCPTool] }`. Every tool has `scope == .theme`, and every result's text is a JSON object:

    | tool | input schema properties (required) | result |
    |---|---|---|
    | `theme_slots` | none | `{ "theme": <shown id>, "appearance", "slots": [{name, purpose, value}], "sessionColors": [hex], "format": <one-line file format> }` |
    | `theme_read` | `name` (required): an id, `user/<stem>`, or a display name, case-insensitive | `{ "id", "builtIn", "file": <theme file object>, "resolved": {slot: hex} }`, or `isError` with `No theme named "<x>". Themes: <comma list of ids>` |
    | `theme_check` | `theme` (required) | `{ "findings": [ContrastFinding], "ignoredSlots": [..], "notes": [..] }` |
    | `theme_preview` | `theme` (required) | as check, plus `"previewing": <name>`. Calls `workshop.preview` |
    | `theme_save` | `name`, `theme` (both required) | as check, plus `"saved": <id>`, `"name"`, `"renamed"`, `"active": false`. Calls `ThemeStore.save`, then `await workshop.didSave` |

  - `theme` accepts an object or a JSON string (Ruling 10). Its schema is `{}`, with a description naming both forms.
  - **Error texts** (`isError: true`):
    - parse failure: `ThemeFileError.message`;
    - no workshop: `Alloy's theme tools are not available right now.`;
    - workspace gone: `NotesTools.closing`.
  - **Tool descriptions** are one or two sentences each. `theme_save`'s must say it never switches the theme and that the user activates it with Keep or in Settings.

- [ ] **Step 1: Write the failing tests**, using a `FakeWorkshop` (records `preview`, `didSave` and `themeSessionEnded` calls, with a fixed catalogue of 3 slots) and calling tools directly with `MCPCaller(sessionID:scopes: [.theme])`.
  - `slotsListsCatalogWithShownValues`: three slots with purposes, with values taken from `shownTheme`.
  - `readFindsByIdAndName`: `dracula`, `Dracula` and `user/<stem>` all resolve. An unknown name is an error that lists the ids.
  - `checkReportsFindingsAndIgnoredSlots`: a draft with `notASlot` and a failing `mutedInk` gives `ignoredSlots == ["notASlot"]` and one finding. It doesn't call `preview`.
  - `previewCallsWorkshopWithResolvedDraft`: the workshop receives the draft, and its resolved `chatFill` comes from the base.
  - `saveWritesFileAndNeverActivates`:
    - The file exists, and the result has `"active": false` and the findings.
    - `didSave` was called.
    - `settings.json` bytes are unchanged.
  - `badDraftsAreRefusedWithoutSideEffects`:
    - Inputs: `theme: 5`, `theme: "{"`, a draft over 256 KB, `colors.accent: "#FFF"`, 5 session colours, `appearance: "dim"`.
    - Each gives `isError`, no `preview`/`didSave` call, and an unchanged folder.
    - `base: "nope"` succeeds with the fallback note.
  - `noWorkshopIsAnError`: with `themeWorkshop` nil, every tool returns the "not available" text.
  - `everyThemeToolIsThemeScoped`: all five names are in `Guidance.themeToolNames`, and every scope is `.theme`.
- [ ] **Step 2: Run** `swift test --filter ThemeToolsTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Tools are `Sendable` structs holding a `WorkspaceRef`.
  - The workshop work runs in `await MainActor.run`. File writes run off the main actor.
- [ ] **Step 4: Run** `swift test --filter "ThemeToolsTests|MCPServerTests|KnowledgeLaunchTests"`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): theme tools on Alloy's MCP server`.

### Task 5: Theme sessions (`/theme`, purpose, launch)

**Files:**
- Create: `Sources/AlloyCore/Themes/ThemeGuidance.swift`
- Modify:
  - `Sources/AlloyCore/Chat/SlashCommands.swift`: `.theme` route.
  - `Sources/AlloyCore/Model/Session.swift`: `purpose`, and `withLocalCommands` adds `theme`.
  - `Sources/AlloyCore/Model/Workspace.swift`: `SessionRecord.purpose`, `newThemeSession`, `launch` and the session-end calls.
- Test:
  - `Tests/AlloyCoreTests/ThemeSessionTests.swift`
  - `Tests/AlloyCoreTests/SlashCommandTests.swift`

**Interfaces:**
- Consumes:
  - Task 1's `token(for:scopes:)`;
  - Task 4's `Guidance.themeToolNames` and `themeWorkshop`.
- Produces:
  - `public enum SessionPurpose: String, Codable, Sendable { case coding, theme }`, with `Session.purpose: SessionPurpose` (`public internal(set)`, default `.coding`).
    - `SessionRecord.purpose: SessionPurpose?` uses `decodeIfPresent`, so nil means `.coding`.
    - Restore and fork copy it (Ruling 5).
  - `SlashRoute.theme(description: String?)`. `/theme` routes there, with an empty argument mapping to nil.
  - `Session.withLocalCommands` also appends `SlashCommandInfo(name: "theme", description: "Make a theme with Claude in a new session", argumentHint: "[description]")` when missing.
  - `@discardableResult public func newThemeSession(description: String?) async -> Session`:
    - it names the session by Ruling 4;
    - it creates it with `purpose = .theme` before launch, through an internal `newSession(name:purpose:)` that the public `newSession(name:)` calls with `.coding`;
    - it selects the session and sends the first message by Ruling 3.
  - `Workspace.send` handles `.theme(let d)` by `await newThemeSession(description: d)`, and returns.
  - `public enum ThemeGuidance { public static let text: String }`, with exactly:

    > This session makes an Alloy theme with the user. A theme is a JSON file: name, appearance (dark or light), base (a theme it inherits from), author, optional credit, colors (slot name to #RRGGBB or #RRGGBBAA) and optional sessionColors (6 to 12). Slots it leaves out come from the base. Ask the user about taste (mood, light or dark, contrast, colours they love or avoid) before drafting, and whenever a choice is unclear; do not guess. Work in this order: call mcp__alloy__theme_slots to learn the slots and what each colours; call mcp__alloy__theme_read on the closest existing theme and use it as the base; draft only the slots you change; call mcp__alloy__theme_preview so the user sees the draft on the whole app; fix every pair the preview or mcp__alloy__theme_check reports below its minimum, then preview again; call mcp__alloy__theme_save with a name. Saving never switches themes: tell the user to choose Keep in the preview bar or pick the theme in Settings.

  - **`launch` changes:**
    - `scopes = (settings.shareKnowledge ? [.shared] : []) ∪ (s.purpose == .theme ? [.theme] : [])`. A token is minted when `scopes` is non-empty.
    - `mcpConfigJSON` is set whenever there is a token and a URL. `extraSettingsJSON` (hooks) is set only when `.shared` is in scopes.
    - `appendSystemPrompt` joins, with `"\n\n"`, `Guidance.text(...)` when shared and `ThemeGuidance.text` when theme.
    - `allowedTools` is `[]` when `askBeforeSharedNotes`, else the shared names (when shared) plus `themeToolNames` (when theme).
    - A theme session with no token or URL gets the Ruling 2 notice.
  - **Session end:** for theme sessions, call `themeWorkshop?.themeSessionEnded(id)` from `stop(_:)`, `markStopped(_:)`, `failLaunch(_:_:)`, the `.exited` branch of `handle(_:session:)` and `stopAll()`.
    - It is not called from `applyPendingRelaunch`. A relaunch isn't an end.

- [ ] **Step 1: Write the failing tests** (use `KnowledgeLaunchTests`' `KHarness` pattern).
  - In `SlashCommandTests`, `themeRoutes`:
    - `/theme` routes to `.theme(description: nil)`.
    - `/theme  warm paper ` routes to `.theme(description: "warm paper")`.
    - `/themes` passes through.
  - `themeCommandStartsANamedThemeSession`:
    - Sending `/theme warm, low contrast` to session A creates `Theme: warm, low contrast`, selected, with purpose `.theme`.
    - Its transport's first user message is `warm, low contrast`.
    - A's transcript has no new user block.
  - `bareThemeSendsTheOpeningLine`: the first message is `Help me make an Alloy theme.`, and the name is `Theme: new`. A 60-character description is cut to 40 characters plus `…`.
  - `themeLaunchHasThemeGuidanceToolsAndScope`:
    - `appendSystemPrompt` contains `Guidance.text()` and `ThemeGuidance.text`.
    - `allowedTools` holds the 7 shared names plus the 5 theme names.
    - Over the real `LocalServer`, `tools/list` with that session's token includes `theme_save`.
  - `codingSessionNeverSeesThemeTools`: a plain session's launch has no theme names in `allowedTools`, no `ThemeGuidance.text`, and its `tools/list` lacks every `theme_*`.
  - `themeToolsWorkWithSharingOff`: with `shareKnowledge = false`, the theme session has `mcpConfigJSON`, no `--settings` hooks, only the theme guidance, and only the theme names allowed.
  - `askBeforeApprovesNothing`: with `askBeforeSharedNotes = true`, `allowedTools == []`.
  - `themePurposeSurvivesRestoreRelaunchAndFork`: after `stopAll` and a fresh workspace `restore()`, a wake gets the theme guidance. So do `relaunchWhenIdle` and a `/fork` of it.
  - `sessionEndTellsTheWorkshop`:
    - The fake workshop sees `themeSessionEnded(id)` after `stop`, and after a scripted `.exited`.
    - It sees nothing after a settings relaunch, or for a coding session.
  - `themeGuidanceIsShortAndUnbranded`: under 200 words, and contains no "Claude Code".
- [ ] **Step 2: Run** `swift test --filter "ThemeSessionTests|SlashCommandTests|KnowledgeLaunchTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** as above.
- [ ] **Step 4: Run** the full `swift test`. Expected: PASS, warning-free.
- [ ] **Step 5: Commit** `feat: /theme sessions with theme guidance and scoped theme tools`.

### Task 6: Preview, Keep, Discard and the activation warning (`ThemeController`)

**Files:**
- Modify: `Sources/AlloyKit/Themes/ThemeController.swift`
- Test: `Tests/AlloyKitTests/ThemePreviewTests.swift`

**Interfaces:**
- Consumes:
  - Task 4's `ThemeWorkshop`, `ThemeSlotInfo` and `SavedTheme`;
  - Task 3's `ThemeStore`;
  - Task 2's `ThemeContrast`;
  - `ThemeSlots.all`, `ThemeApplier`.
- Produces: `ThemeController: ThemeWorkshop`.
  - `bind(_:)` and the `init(workspace:…)` convenience set `workspace.themeWorkshop = self`.
  - `slotCatalog` comes from `ThemeSlots.all`.
  - `public struct ThemePreview: Equatable` with:
    - `name: String`, `session: UUID`, `draft: ThemeFile`, `resolved: ResolvedTheme`;
    - `savedID: String?`;
    - `findings: [ContrastFinding]`.
  - `public private(set) var preview: ThemePreview?`
  - `public struct PendingActivation: Equatable` with `themeID: String`, `findingCount: Int` and `slot: ActivationSlot` (`.single`, `.light` or `.dark`).
  - `public private(set) var pendingActivation: PendingActivation?`
  - **Methods:**
    - `preview(_:resolved:session:)` installs `ThemeApplier.theme(for:)` in both host slots and forces `preferredColorScheme` to the draft's appearance (Ruling 6). Settings are untouched.
    - `apply()` re-installs an active preview after installing the user's theme. A reload therefore keeps the preview.
    - `didSave` reloads the library, then sets `preview.savedID = saved.id` when the session matches and the files are equal (Ruling 7).
    - `public func discardPreview()`: `preview = nil`, then `apply()`.
    - `themeSessionEnded(_:)` discards when the preview belongs to that session.
    - `public func keepPreview() async throws`:
      1. if there is no `savedID`, save through `ThemeStore(appSupport:)` with the preview's session as owner, then reload;
      2. `request(...)` the saved id in the slot chosen by Ruling 7;
      3. clear the preview once activation is applied or pending.
    - `public func request(theme: String? = nil, light: String? = nil, dark: String? = nil) throws` resolves the theme and runs `ThemeContrast.findings`.
      - With no findings it calls `choose`.
      - Otherwise it sets `pendingActivation` and applies nothing.
    - `public func confirmActivation() throws` calls `choose` with the pending choice and clears it.
    - `public func cancelActivation()` clears the pending choice.
    - `shownTheme` is the preview's resolved theme, else the resolved theme in force for the host's current scheme.

- [ ] **Step 1: Write the failing tests**, with a `TestWindow` host and a `Rig` workspace (as in `ThemeControllerTests`).
  - `previewRepaintsWithoutTouchingSettings`:
    - Preview a light draft based on `solarized-light` with `chatFill #FFF8E7`.
    - The window's `chatFill` resolves to it, and the scheme is forced light.
    - `settings.json` bytes and the themes folder listing are unchanged.
  - `discardRestoresTheUsersTheme`: after `discardPreview()`, the colours equal Dracula's, the scheme is forced dark, and `preview == nil`.
  - `sessionEndRestoresTheUsersTheme`: `themeSessionEnded(previewSession)` restores. `themeSessionEnded(otherSession)` doesn't.
  - `reloadDuringPreviewKeepsPreview`:
    - Active `user/mine`, previewing a draft. Rewrite `mine.json` with a new accent and fire the watcher.
    - The draft is still shown. After discard, the new accent shows.
  - `keepSavesUnsavedDraftAndActivates`: keep with no findings. `user/<slug>` exists, is owned by the preview session, `settings.theme` equals it, and `preview == nil`.
  - `keepAfterSaveDoesNotSaveTwice`: `didSave` with an equal file, then Keep. There is exactly one file, and the theme is activated.
  - `keepInMatchSystemSetsTheAppearanceSlot`: a light draft in `.matchSystem` sets `lightTheme`, and `darkTheme` is unchanged.
  - `findingsAskBeforeActivating`:
    - `request(theme:)` on a user theme with 3 findings gives `pendingActivation?.findingCount == 3`, and settings are unchanged.
    - `confirmActivation()` applies it.
    - `cancelActivation()` leaves everything as it was.
  - `builtInsActivateWithoutWarning`: `request(theme: "one-dark")` applies at once.
- [ ] **Step 2: Run** `swift test --filter "ThemePreviewTests|ThemeControllerTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** as above.
- [ ] **Step 4: Run** the same filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(kit): live theme preview, keep/discard, activation warning`.

### Task 7: Preview bar, warning strip, Settings entry, docs and the skill file

**Files:**
- Create: `Sources/AlloyKit/Themes/ThemeBar.swift`, `docs/skills/alloy-theme/SKILL.md`
- Modify:
  - `Sources/AlloyKit/RootView.swift`: `ThemeBar` above `CoordinationNotice` when `themes` is non-nil.
  - `Sources/AlloyKit/SettingsView.swift`: `ThemeSection` gets the Make button, row clicks use `request`, and it shows the warning.
  - `Tests/AlloyKitTests/ContrastAuditTests.swift`: bar pairs.
  - `docs/themes.md`, `README.md`, `docs/superpowers/plans/2026-11-07-alloy-roadmap.md`.
- Test: `Tests/AlloyKitTests/ThemeBarTests.swift`, `Tests/AlloyKitTests/SettingsThemeTests.swift`

**Interfaces:**
- Consumes: Task 6's `preview`, `pendingActivation`, `keepPreview`, `discardPreview`, `request`, `confirmActivation` and `cancelActivation`, plus Task 5's `newThemeSession`.
- Produces:
  - **`ThemeBar(themes:)`**, drawn on `.commandTint` with `.textPrimary` text.
    - With a preview, `theme-preview-bar` holds `Text("Previewing <name>")` and two buttons:
      - "Keep" (`theme-preview-keep`), which runs `keepPreview` and shows a save error inline as `theme-preview-error` in `errorInk`;
      - "Discard" (`theme-preview-discard`).
      - With findings, it adds `theme-preview-findings`, in `.warningInk` on `.warningTint`: `"N colour pair(s) are hard to read"`.
    - With `pendingActivation`, `theme-activation-warning` sits on `.warningTint` and holds:
      - the Ruling 9 text in `.textPrimary`;
      - "Use anyway" (`theme-activation-use`);
      - "Cancel" (`theme-activation-cancel`).
    - The bar draws nothing otherwise.
  - **Settings:**
    - A button "Make a theme with Claude…" (`settings-make-theme`), between "Open themes folder" and "Back to Dracula". It closes Settings and starts `workspace.newThemeSession(description: nil)`.
    - `ThemeSection` gains `workspace: Workspace?` and `close: (@MainActor () -> Void)?`. The button shows only when both are set.
    - Row clicks call `themes.request(...)`.
  - **Audit pairs:**
    - `themebar.text` (`textPrimary` on `commandTint`), at 4.5;
    - `themebar.warning` (`warningInk` on `warningTint`), at 4.5;
    - `themebar.warningText` (`textPrimary` on `warningTint`), at 4.5.

- [ ] **Step 1: Write the failing tests.**
  - `barAppearsOnPreviewAndKeepActivates`: with a preview, `theme-preview-bar` shows `Previewing Paper`. Clicking `theme-preview-keep` removes the bar and sets settings to the new theme.
  - `discardButtonRestores`: clicking `theme-preview-discard` hides the bar and restores Dracula's `chatFill`.
  - `warningUseAnywayAndCancel`:
    - Clicking a user theme row with findings in Settings shows `theme-activation-warning` with the right count. The theme is unchanged.
    - `theme-activation-use` applies it.
    - On a second try, `theme-activation-cancel` hides the strip with nothing applied.
  - `makeThemeButtonStartsAThemeSession`: clicking `settings-make-theme` closes Settings. A session named `Theme: new` with purpose `.theme` is selected, using the rig's scripted transport.
  - `existingSettingsIdsStillWork` stays green.
  - `theAuditCoversTheViews` must include `themebar.text`.
- [ ] **Step 2: Run** `swift test --filter "ThemeBarTests|SettingsThemeTests|SettingsViewTests|ContrastAuditTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** the views using theme tokens only, then the docs:
  - **`docs/themes.md`:** a "Making a theme with Claude" section covering:
    - `/theme`, and the Settings button;
    - the five tools, with their inputs and outputs;
    - preview, Keep and Discard;
    - the contrast table from Task 2;
    - the save naming and ownership rules.
  - **`docs/skills/alloy-theme/SKILL.md`:**
    - frontmatter `name: alloy-theme` and a one-line `description`;
    - body: the `ThemeGuidance.text` workflow, the file format, and "install it yourself by copying this folder into your skills directory; Alloy never installs it".
  - **README:** the Themes section loses "coming in 7b" and gains `/theme`.
  - **Roadmap:** 7b is "implemented; hands-on check pending".
- [ ] **Step 4: Run** the full `swift test` and `swift build -c release`. Expected: PASS, 0 warnings.
- [ ] **Step 5: Commit** `feat(ui): theme preview bar, activation warning, Make a theme with Claude; docs and skill file`.

### Task 8: Segmented-picker thumb edge at 3:1 in every built-in (user decisions, Ruling 12)

**Files:**
- Modify:
  - `Sources/AlloyKit/Themes/ThemeSlots.swift`
  - all six built-ins in `Sources/AlloyCore/Themes/BuiltIn/`: `Dracula.swift`, `AlloyDark.swift`, `AlloyLight.swift`, `SolarizedDark.swift`, `SolarizedLight.swift`, `OneDark.swift`
  - `Tests/AlloyKitTests/ContrastAuditTests.swift`
  - `Tests/AlloyKitTests/ThemeSlotTests.swift`
  - `docs/themes.md`
  - `docs/metalui-gaps.md`
- Test: `Tests/AlloyKitTests/ContrastAuditTests.swift`, `Tests/AlloyKitTests/ThemeSlotTests.swift`

**Interfaces:**
- Consumes: MetalUI G31, a public `ThemeColorKey` named `SegmentedThumbEdge` (the name the request suggests; use whatever name lands).
  - Its `defaultValue` is today's edge: `textPrimary` at 0.10 in light and 0.12 in dark.
  - MetalUI draws the selected segment's 1 px border with it (`../MetalUI/Sources/MetalUI/Picker.swift`, `selectedSegmentEdge`).
- Produces:
  - **A slot `pickerThumbEdge`** in the token group of `ThemeSlots.all`, after `scrim`.
    - Its purpose: `The 1 px outline of the selected segment in segmented pickers; needs 3:1 against surfaceSecondary and against the selected segment.`
    - It is backed by `SegmentedThumbEdge`.
  - **Built-in values.** Each is a mix of the theme's `textPrimary` into its `surfaceSecondary`. The ratios were computed with the audit's WCAG maths:

    | theme | `pickerThumbEdge` | vs track (`surfaceSecondary`) | vs thumb |
    |---|---|---|---|
    | dracula | `#C0C1C3` | 5.08 | 3.12 |
    | alloy-dark | `#9FA5B4` | 5.30 | 3.15 |
    | alloy-light | `#7B808B` | 3.19 | 3.96 |
    | solarized-dark | `#869799` | 4.27 | 3.13 |
    | solarized-light | `#616A6B` | 3.13 | 5.15 |
    | one-dark | `#A9AFBA` | 4.43 | 3.11 |

  - **Audit pairs**, both `.alloy`-owned:
    - `picker.thumbEdgeVsTrack`: `Color.pickerThumbEdge` on `[.surfaceSecondary]`, minimum 3;
    - `picker.thumbEdgeVsThumb`: the edge on `[.surfaceSecondary, pill]`, minimum 3. `pill` is the audit's existing thumb colour.
    - Both are enforced for all six built-ins in `everyBuiltInMeetsWCAGAA`. They are not in `relaxedForBuiltIn`, and there is no exemption.
    - The bare-theme `everyPairMeetsWCAGAA` skips both, as it skips `tabs.unselected`, because MetalUI's default edge is translucent and isn't a theme value.

- [ ] **Step 0: Check the dependency.** Grep `../MetalUI/Sources/MetalUI` for the public key used for the selected-segment border, and check that Alloy's pinned MetalUI revision includes it.
  - If it is missing, STOP and report "blocked on G31". Don't substitute a darker `surfaceSecondary`, and don't edit `../MetalUI`.
- [ ] **Step 1: Write the failing tests.**
  - `thumbEdgeMeetsThreeToOne(themeID:)`, parameterised over the six ids:
    - `picker.thumbEdgeVsTrack` and `picker.thumbEdgeVsThumb` are both at least 3.0;
    - the resolved edge equals the table's hex.
  - `alloyDarkAndLightDefineEverySlot` and `docsListEverySlotAndCredit` cover the new slot automatically.
  - In `alloyDarkMatchesTodaysLook` (both schemes), add `pickerThumbEdge` to the slots exempt from the "same as today" check. Both Alloy themes deliberately change it. Every other slot must still match.
- [ ] **Step 2: Run** `swift test --filter "ContrastAuditTests|ThemeSlotTests|BuiltInThemeTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Add the slot, the six values and the two audit pairs.
  - In `docs/themes.md`, add the slot row, and a "Segmented picker outline (user decisions 2026-11-11)" paragraph with the table above.
  - In `docs/metalui-gaps.md`:
    - add G31 (requested and forwarded 2026-11-11, then adopted with the MetalUI revision);
    - set G23 to resolved: the selected segment is outlined at 3:1 or better in every built-in.
- [ ] **Step 4: Run** the full `swift test` and `swift build -c release`. Expected: PASS, 0 warnings.
- [ ] **Step 5: Commit** `fix(theme): segmented picker thumb edge at 3:1 in every built-in`.
