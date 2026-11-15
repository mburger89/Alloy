# Linters Through Language Servers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each file keeps its one main language server and also gets every enabled, configured linter server (Ruff,
ESLint, Biome, golangci-lint, efm-langserver), with their diagnostics merged and labelled in the code and diff views.

**Architecture:** `ServerConfig` gains a `role` (`main` / `linter`), built-in `configurationAnswers` and
`requiresConfigFiles`. `ServerRegistry` adds a list-valued linter lookup. `LSPManager` tracks one main server plus a
set of linter servers per path, fans document sync out to all of them, stores diagnostics per (path, server) and
yields their union. The UI stacks several messages per line and shows linter status in the file header.

**Tech Stack:** Swift 6, Swift Testing, AlloyLSP (UI-free), AlloyKit on MetalUI.

**Spec:** `docs/superpowers/specs/2026-11-15-alloy-linters-design.md` (extends `2026-11-12-alloy-lsp-design.md`).

## Global Constraints

- Work in worktree `../Alloy-lint` on branch `feat/linters` (from `feat/pills`). No Agent worktree isolation.
- MetalUI (`../MetalUI`) is read-only; a missing API is reported as a gap with file:line, never worked around.
- Alloy never installs or downloads servers; a server is found on the login-shell PATH (`ServerLocator`).
- Nothing runs or is allocated for a linter that is not installed, disabled, or (ESLint/Biome) not configured.
- Linters get document sync and diagnostics only; definition and semantic tokens use the main server only.
- Accessibility ids: `settings-linter-<id>`, `settings-linter-status-<id>`, `settings-lsp-rust-analyzer-clippy`.
- Message row text: `<source> <code>: <message>` (code omitted when absent), most severe first, max 3 per line, then
  `+N more`; the file-wide cap `DiagnosticDecorations.maxVirtualRows = 200` still holds.
- Tests: `swift test --no-parallel` only. Known unrelated failure: `OverlapIndexTests.unsavedTypingCostIsBounded`.
- Zero new warnings. `ViewRerunTests` steady-frame guard (90) must not go up.
- Never write `~/.claude` or any `.claude/`. No bare `git stash`. Kill only PIDs you started. Never launch the GUI app.
- Commit trailers on every commit:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  `Claude-Session: <this session's link, from the orchestrator>`

## Review Focus

1. A linter that crashes at start while the main server is healthy: main diagnostics, definition and tokens keep
   working; header shows `Ruff failed`. (Test in Task 3.)
2. A linter switched off in Settings while its file is open: its diagnostics disappear, the main server's stay, nothing
   restarts but that linter. (Test in Task 3.)
3. A linter's `publishDiagnostics` for an older document version arriving after a newer edit: mapped or dropped per v1,
   never painted over newer text, and never clearing the main server's set. (Test in Task 3.)
4. A monorepo where only `web/` has `eslint.config.js`: ESLint runs for `web/app.ts`, not for `scripts/tool.ts`.
   (Test in Task 3.)
5. A file reopened under another extension (rename `a.py` → `a.ts`): Ruff gets `didClose`, ESLint/TS get `didOpen`.
   (Test in Task 3.)

---

### Task 1: Config model, overrides and registry lookup

**Files:**
- Modify: `Sources/AlloyLSP/ServerConfig.swift`, `Sources/AlloyCore/Model/ServerConfigOverride.swift`,
  `Sources/AlloyLSP/ServerRegistry.swift`
- Test: `Tests/AlloyLSPTests/ServerRegistryTests.swift`

**Interfaces:**
- Produces:
  - `public enum ServerRole: String, Codable, Sendable { case main, linter }`
  - `ServerConfig.role: ServerRole` (default `.main`), `ServerConfig.configurationAnswers: [String: JSONValue]`
    (default `[:]`), `ServerConfig.requiresConfigFiles: [String]` (default `[]`; glob-free names, `*` allowed only as
    `eslint.config.*`-style suffix wildcard), `ServerConfig.clippy: Bool` (default false, only meaningful for
    `rust-analyzer`).
  - `ServerConfigOverride.role: ServerRole?` (decoded leniently: an unknown string is ignored), `.clippy: Bool?`.
  - `ServerRegistry.linters(forPath: String) -> [ServerConfig]` (enabled linters matching file name or extension, in
    table order then user-added ids sorted). `server(forPath:)` and `languageID(forPath:)` consider `.main` only.
  - `ServerRegistry.effectiveInitializationOptions(_ config: ServerConfig) -> JSONValue?`: for `clippy == true`, the
    config's options with `check.command = "clippy"` added only where the user's own options don't set
    `check.command`.
  - Built-in linter rows (exact):
    - `ruff`, "Ruff", languageID `python`, `ruff` `["server"]`, `py`, `pyi`
    - `eslint`, "ESLint", `javascript` (ids as typescript-language-server's), `vscode-eslint-language-server`
      `["--stdio"]`, `js jsx mjs cjs ts tsx`, requiresConfigFiles `["eslint.config.*", ".eslintrc", ".eslintrc.*",
      "package.json#eslintConfig"]`, configurationAnswers `"": {"validate":"on","run":"onType","workingDirectory":
      {"mode":"auto"},"nodePath":null,"experimental":{},"problems":{},"rulesCustomizations":[],"codeAction":
      {"disableRuleComment":{"enable":false},"showDocumentation":{"enable":false}}}` (ESLint asks with no section)
    - `biome`, "Biome", `javascript`, `biome` `["lsp-proxy"]`, `js jsx mjs cjs ts tsx json jsonc css`,
      requiresConfigFiles `["biome.json", "biome.jsonc"]`
    - `golangci-lint`, "golangci-lint", `go`, `golangci-lint-langserver` `[]`, `go`, initializationOptions
      `{"command":["golangci-lint","run","--output.json.path=stdout","--show-stats=false"]}`
    - `efm`, "efm-langserver", `plaintext`, `efm-langserver` `[]`, no extensions (user lists them)

- [ ] **Step 1: Write failing tests** in `ServerRegistryTests`:
  `lintersAreFoundBesideTheMainServer` (`a.py` → main `pyright`, linters `["ruff"]`);
  `lintersNeverWinMainLookup` (`a.ts` main is `typescript-language-server`, linters `["eslint","biome"]`);
  `disabledLinterIsNotListed` (override `ruff.enabled=false` → `[]`);
  `userAddedLinterWithRole` (override `"mylint": {command:"mylint", extensions:["py"], role:"linter"}` → linters
  `["ruff","mylint"]`, main still `pyright`);
  `roleOverrideMovesBuiltIn` (`ruff.role="main"` → main for `a.py` is `ruff` because user claims win; pyright not a
  linter);
  `unknownRoleIsIgnored` (`role:"banana"` decodes, role stays default);
  `clippyMergesIntoInitOptions` (rust-analyzer with `clippy:true` → `check.command == "clippy"`; with user options
  `{"check":{"command":"check"}}` → stays `"check"`);
  `efmHasNoBuiltInFiles` (`linters(forPath:"a.swift")` excludes `efm`).
- [ ] **Step 2: Run** `swift test --no-parallel --filter ServerRegistryTests` — expect failures (missing members).
- [ ] **Step 3: Implement** the members above; the linter table is a `[String: [ServerConfig]]` per file name and per
  extension, built once in `init`.
- [ ] **Step 4: Run** the same filter — PASS; then `--filter AlloyLSPTests` — PASS.
- [ ] **Step 5: Commit** `LSP: linter role, per-server configuration answers and the built-in linters`.

### Task 2: Server-side answers and diagnostic codes

**Files:**
- Modify: `Sources/AlloyLSP/LanguageServer.swift:349-362`, `Sources/AlloyLSP/Diagnostics.swift`
- Test: `Tests/AlloyLSPTests/LanguageServerTests.swift`, `Tests/AlloyLSPTests/DiagnosticsTests.swift`

**Interfaces:**
- Consumes: `ServerConfig.configurationAnswers` (Task 1).
- Produces: `LanguageServer.answer(method:params:root:configuration:)` where `configuration: [String: JSONValue]`;
  each `workspace/configuration` item gets `configuration[item.section ?? ""] ?? .null`.
  `LSPDiagnostic.code: String?` (a number is stringified), parsed from the LSP `code` field.
- [ ] **Step 1: Failing tests:** `configurationAnswersBySection` (items `[{section:"eslint"}, {}]` with answers
  `["": X]` → `[null, X]`); `configurationDefaultsToNull` (no answers → nulls, today's behaviour);
  `diagnosticCodeStringAndNumber` (`"code":"F401"` → `"F401"`, `"code":6133` → `"6133"`, absent → nil).
- [ ] **Step 2: Run** `--filter "LanguageServerTests|DiagnosticsTests"` — FAIL.
- [ ] **Step 3: Implement**; the server's init passes its config's answers. Also send
  `ServerRegistry.effectiveInitializationOptions` instead of the raw options where `initialize` is built.
- [ ] **Step 4: Run** the filter — PASS.
- [ ] **Step 5: Commit** `LSP: answer workspace/configuration per server; read diagnostic codes`.

### Task 3: The manager runs linters beside the main server

**Files:**
- Modify: `Sources/AlloyLSP/LSPManager.swift`
- Create: `Sources/AlloyLSP/ConfigProbe.swift`
- Test: `Tests/AlloyLSPTests/LSPManagerTests.swift` (new tests in a `@Suite("Linters")` extension or new file
  `Tests/AlloyLSPTests/LSPManagerLinterTests.swift` reusing `Rig`; make `Rig` internal if needed)

**Interfaces:**
- Consumes: Task 1 registry lookups; Task 2 answers.
- Produces:
  - `public struct ConfigProbe: Sendable { var exists: @Sendable (URL) -> Bool; static let live; func hasConfig(for path: String, names: [String], root: URL) -> Bool }`
    — walks from the file's folder up to `root` inclusive; `eslint.config.*` matches any extension;
    `package.json#eslintConfig` means `package.json` whose top-level object has key `eslintConfig` (read lazily, only
    when the plain names miss). `LSPManager.init` gains `probe: ConfigProbe = .live`.
  - `Tracked` becomes `{ serverID: String; linterIDs: [String]; languageID: String; snapshot: CodeSnapshot }`.
    Linter language id: the linter's own `languageIDs[ext] ?? languageID`.
  - Diagnostics stored as `[String: [String: [LSPDiagnostic]]]` (path → server id → items, already mapped to the
    current snapshot by v1 rules); every store or clear yields `.diagnostics(path:version:items:)` with the union in
    the order main first, then linters in `linterIDs` order. Items with no `source` get the server's `name`.
  - `LSPResult.status` unchanged in shape; linters report through it with their own `serverID`.
  - Open/change/save/close and `reload(registry:)` fan out to `[serverID] + linterIDs`. Definition and semantic
    token requests use `serverID` only. A linter whose start fails or that is marked failed is skipped for sync; v1's
    restart rule applies per server id.
- [ ] **Step 1: Failing tests** (fake servers from `Rig`, each a different id):
  `linterGetsSyncButNotDefinitionOrTokens` (methods seen by linter include didOpen/didChange/didSave/didClose, never
  `textDocument/definition` or `semanticTokens`);
  `diagnosticsFromMainAndLinterAreMerged` (main publishes 1, linter publishes 2 → one result with 3, main first);
  `oneServersClearDoesNotWipeAnother` (linter publishes `[]` → result keeps main's item);
  `missingSourceGetsServerName`;
  `staleLinterVersionDoesNotPaintOverNewText` (Review Focus 3);
  `crashingLinterLeavesMainWorking` (linter script exits at start → status failed for linter id, main diagnostics
  still delivered) (Review Focus 1);
  `disablingLinterRemovesOnlyItsDiagnostics` (reload with `ruff.enabled=false`) (Review Focus 2);
  `eslintStartsOnlyUnderItsConfig` (`web/eslint.config.js` exists via probe: `web/app.ts` opens on eslint,
  `scripts/tool.ts` doesn't) (Review Focus 4);
  `packageJsonEslintConfigCounts`;
  `reopenUnderNewExtensionMovesLinters` (Review Focus 5);
  `absentLinterStartsNothing` (locator miss → no process launched, no status spam beyond one `.missing`).
- [ ] **Step 2: Run** `--filter "LSPManager"` — FAIL.
- [ ] **Step 3: Implement.** Keep all work on the actor; the probe's filesystem reads happen off the main actor and
  are cached per (folder, server id) until `reload`.
- [ ] **Step 4: Run** `--filter AlloyLSPTests` — PASS (old tests unchanged).
- [ ] **Step 5: Commit** `LSP: run linters beside the main server and merge their diagnostics`.

### Task 4: Stacked messages and linter status in the file panel

**Files:**
- Modify: `Sources/AlloyKit/Code/DiagnosticDecorations.swift:59-97`, `Sources/AlloyLSP/LSPStatusModel.swift`,
  `Sources/AlloyKit/LSP/LSPCoordinator.swift:210-235`, `Sources/AlloyKit/FilePanelView.swift` (`ServerStatusLabel`)
- Test: `Tests/AlloyKitTests/DiagnosticDecorationsTests.swift` (or the existing file covering `layout`),
  `Tests/AlloyKitTests/LSPStatusTests.swift`

**Interfaces:**
- Consumes: Task 3 merged results; Task 1 `registry.linters(forPath:)`.
- Produces:
  - `DiagnosticDecorations.layout` keeps one `CodeVirtualRow` per buffer line whose `lines` are the line's distinct
    error/warning items (dedupe identical `(source, code, message)`), most severe first then arrival order, up to 3,
    plus `"+N more"` when more; the 200-row cap counts virtual rows.
  - `rowText(_:)` returns `"\u{26A0} <source> <code>: <message first line>"`, dropping `<code>` (and its space) when
    nil and `<source> ` when nil.
  - `LSPStatusModel.linters: [String: [(id: String, name: String, state: ServerState)]]` keyed by path, with
    `setLinter(path:id:name:state:)` and `removeLinter(path:id:)`; no-op writes don't notify (same rule as `set`).
  - Header text: main status as today, then ` · ` and the ready linters' names (`Pyright · Ruff`); a failed linter
    shows `Ruff failed` (error ink); starting, missing or stopped linters show nothing.
- [ ] **Step 1: Failing tests:** `stacksUpToThreeMessagesPerLine` (5 items on one line → 4 text lines, last
  `"+2 more"`); `mostSevereFirst`; `duplicatesFromOneSourceCollapse`; `samePlaceDifferentSourcesBothShow`;
  `rowTextIncludesSourceAndCode` (`"⚠ ruff F401: 'os' imported but unused"`); `rowTextWithoutCode`;
  `headerListsReadyLinters`; `headerShowsFailedLinter`; `missingLinterNotInHeader`.
- [ ] **Step 2: Run** `--filter "DiagnosticDecorations|LSPStatus|FilePanelHeader"` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter, then `--filter "ViewRerun|DiffDecorations|FilePanel"` — PASS, guard still 90.
- [ ] **Step 5: Commit** `Diagnostics: stack messages per line, label source and code; linters in the file header`.

### Task 5: Settings › Linters and Clippy

**Files:**
- Modify: `Sources/AlloyKit/SettingsView.swift:155-180` (Language servers section), settings write path for
  `languageServers` overrides
- Test: `Tests/AlloyKitTests/SettingsViewTests.swift` (or the existing Language servers settings test file)

**Interfaces:**
- Consumes: Task 1 `ServerRole`, `ServerConfigOverride.clippy`; existing per-server on/off and found/not-found rows.
- Produces: the section splits into the existing server rows (main role) and a "Linters" sub-heading with the linter
  rows (`settings-linter-<id>`, status `settings-linter-status-<id>`, same Found / Not found text); the rust-analyzer
  row gains a "Use Clippy" checkbox `settings-lsp-rust-analyzer-clippy` writing `languageServers["rust-analyzer"].clippy`.
  Changing either reloads the registry (existing path), which restarts only the affected server.
- [ ] **Step 1: Failing tests:** `lintersHaveTheirOwnGroup` (ids present under the Linters heading, not among
  servers); `togglingALinterPersists` (off → settings file has `ruff.enabled=false`); `clippyTogglePersists`;
  `userAddedLinterIsListed` (override with `role:"linter"` shows under Linters).
- [ ] **Step 2: Run** `--filter Settings` — FAIL.
- [ ] **Step 3: Implement.** Reuse the server row component; no new look values (ThemeGuardTests).
- [ ] **Step 4: Run** `--filter Settings`, then the full `swift test --no-parallel` — only the known failure.
- [ ] **Step 5: Commit** `Settings: Linters group and the Clippy switch`.
- [ ] **Step 6:** `./scripts/bundle-macos.sh` builds `build/Alloy.app` in the worktree.
