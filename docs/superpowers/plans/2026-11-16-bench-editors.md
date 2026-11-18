# Bench Editors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add VS Code, Cursor, Sublime Text and IntelliJ IDEA as measurable `alloy-bench` targets (ids `vscode`, `cursor`, `sublime`, `idea`), listed wherever the harness and the /benchmarks page enumerate editors.

**Architecture:** One `TargetApp` adapter per editor in `Bench/Sources/BenchCore/Targets.swift`, following `zed` and `delta`. Two small generalisations of the per-run profile plumbing (extra profile arguments, an environment value that is not the bare directory, a profile-directory placeholder in seeded files) let VS Code's two flags and IntelliJ's properties file fit the existing launcher. Result/report/site code gets one ordered editor catalogue instead of hard-coded `zed, delta, alloy` lists. Measurement, fairness and publish rules do not change.

**Tech Stack:** Swift 6, SwiftPM package `Bench/` (modules BenchCore, BenchDrivers, BenchScenarios, alloy-bench), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-18-bench-editors-design.md` (read its "Approved decisions" section first; it is binding).

## Global Constraints

- Only `Bench/` (sources, tests, README) and docs change. Nothing in `Sources/` or `Tests/` of the main Alloy package.
- Bench tests run only as: `swift test --package-path Bench [--filter X]`, wrapped in the swift test lock (`lockf -k <lock file> swift test --package-path Bench`). Plain `swift build --package-path Bench` needs no lock. Do not run the main Alloy suite. `ProcessTreeTests.cpuPercentOfBusyChild` is flaky under load; ignore it when it fails alone.
- Never launch an editor. Only read Info.plist, files, and `--help`/`--version` style output (not IntelliJ's `idea --help`, which may start the GUI; read `Contents/Resources/product-info.json` and `Contents/bin/idea.properties` instead). Never touch a real editor profile.
- If MetalUI or a platform API is missing for something, stop and report a gap; no substitutes.
- Fairness/publish rules unchanged: a metric that cannot be fair is `n/a: <reason>`, a disturbed run makes the metric `not measured`, nothing measured under a trace is published, `Publisher.partialReason` still requires only `zed` and `alloy`, `Parity.judge` still compares `alloy` to `zed`.
- Only add an adapter-level `unsupported` entry when a metric is known impossible without a live probe. Otherwise leave it supported and record the open question in `caveats` and the README for the orchestrator's live probe.
- Committed text (code, tests, docs, caveats) must contain no local paths or personal data: no home-directory paths, no user or machine names, no scratch-directory paths, no session links, no personal email or bundle ids (the orchestrator's forbidden-pattern list applies; commit trailers excepted).
- Commit messages end with the two trailer lines the orchestrator specified (Co-Authored-By and Claude-Session).
- Frame guards (ViewRerunTests.steadyFrameRequests 88, CodeModePerformanceTests.steadyCode1/2/3 91/107/117) are untouched: no app code changes.

Facts read from the installed apps (re-verify, do not trust blindly):

| Id | App path | `CFBundleExecutable` | `CFBundleIdentifier` | Version |
|---|---|---|---|---|
| vscode | `/Applications/Visual Studio Code.app` | `Code` | `com.microsoft.VSCode` | 1.147.0 |
| cursor | `/Applications/Cursor.app` | `Cursor` | `com.todesktop.230313mzl4w4u92` | 3.30.14 |
| sublime | `/Applications/Sublime Text.app` | `sublime_text` | `com.sublimetext.4` | Build 4215 |
| idea | `/Applications/IntelliJ IDEA.app` | `idea` | `com.jetbrains.intellij` | 2026.3 |

Executable path is `<app>/Contents/MacOS/<CFBundleExecutable>`. Sublime's `--help` lists `--safe-mode`, `-n`, `-w`. For VS Code and Cursor the main binary printed nothing for `--help`; verify flag spellings with the bundled shim script `<app>/Contents/Resources/app/bin/code --help` (or `cursor`) which is a shell script, no GUI.

## Review Focus

- A run that selects only new editors (no `zed`, no `alloy`) must still render in `Report.markdown`, the site page and `SiteChart` without crashing or empty-looking tables (chart returns nil).
- Older published/result JSON that only knows `zed`, `delta`, `alloy` must render byte-identically to today (no new empty columns, no new CSS-dependent markup).
- A file path containing spaces (the VS Code and IntelliJ app paths do, and so can the staged file) must stay a single argument.
- Seeding failure or launch failure for an app with a profile directory must remove that directory (IntelliJ's directory is created because of its environment variable, not a flag).
- Caveats and unsupported reasons of every new adapter must pass the publish privacy scan (no local paths), since they land in published JSON.

---

### Task 1: Profile plumbing for multi-flag and properties-file profiles

**Files:**
- Modify: `Bench/Sources/BenchCore/Targets.swift` (TargetApp fields and init)
- Modify: `Bench/Sources/BenchDrivers/Launcher.swift` (`launch`, `seed`, `environment(for:...)`, `arguments(for:...)`)
- Test: `Bench/Tests/BenchCoreTests/LaunchIsolationTests.swift`

**Interfaces:**
- Produces on `TargetApp` (all defaulted so existing adapters compile unchanged):
  - `public var profileArguments: @Sendable (_ profileDir: String) -> [String]`, default `{ _ in [] }`; appended after `userDataDirFlag dir` and before `launchArguments(file)`. VS Code uses it for `--extensions-dir <dir>/extensions`.
  - `public var dataDirEnvironmentValue: @Sendable (_ profileDir: String) -> String`, default `{ $0 }`; value for `dataDirEnvironmentKey`. IntelliJ uses `{ $0 + "/idea.properties" }`.
  - `public static let profileDirPlaceholder = "@PROFILE_DIR@"`; `Launcher.seed(_:into:)` replaces it with the directory in every seeded file's contents.
- Changes `Launcher.arguments(for:file:userDataDir:)` and `Launcher.environment(for:userDataDir:extra:base:)` to honour the two new fields; signatures unchanged.

- [ ] **Step 1: Write failing tests** in `LaunchIsolationTests`:
  `profileArgumentsFollowTheDataDirFlag` (a stub target with `userDataDirFlag: "--user-data-dir"`, `profileArguments: { ["--extensions-dir", $0 + "/extensions"] }`, `launchArguments: { [$0 ?? ""] }` yields `["--user-data-dir", "/p", "--extensions-dir", "/p/extensions", "/a b/c.swift"]` for dir `/p` and file `/a b/c.swift`);
  `environmentValueUsesTheMapper` (key `IDEA_PROPERTIES`, mapper appends `/idea.properties`, base env `["X":"1"]` gives `["X":"1","IDEA_PROPERTIES":"/p/idea.properties"]`);
  `seedReplacesProfileDirPlaceholder` (seed `["idea.properties": "idea.config.path=@PROFILE_DIR@/config\n"]` into a temp dir, read back, contents contain that temp dir and not the placeholder);
  `zedAndAlloyOutputUnchanged` (existing zed/alloy argument and environment assertions still pass; no placeholder substitution changes Zed's seeded JSON).
- [ ] **Step 2: Run** `swift test --package-path Bench --filter LaunchIsolationTests` under the lock. Expected: compile failure on the new members.
- [ ] **Step 3: Implement** the three members in `Targets.swift` (extra init parameters with defaults, placed after `typingClickPoint`) and make `Launcher.launch` create the profile directory when `userDataDirFlag != nil || dataDirEnvironmentKey != nil` exactly as now (already true for env-only apps; keep the cleanup-on-seed-failure and cleanup-on-run-failure paths). Substitution is a plain `replacingOccurrences` in `seed`.
- [ ] **Step 4: Run** the filtered suite, then the whole Bench suite under the lock. Expected: all pass (flaky exception above).
- [ ] **Step 5: Commit** `feat(bench): profile arguments, env value mapper and placeholder seeding`.

### Task 2: The four editor adapters

**Files:**
- Modify: `Bench/Sources/BenchCore/Targets.swift` (add `static let vscode`, `cursor`, `sublime`, `idea`)
- Create: `Bench/Tests/BenchCoreTests/EditorTargetsTests.swift`

**Interfaces:**
- Consumes: Task 1 members.
- Produces: `TargetApp.vscode`, `.cursor`, `.sublime`, `.idea` (ids `vscode`, `cursor`, `sublime`, `idea`; display names "VS Code", "Cursor", "Sublime Text", "IntelliJ IDEA"); `public static let editors: [TargetApp]` in that order, used by Task 3.

Per-adapter contract (spec table; confirm flag spellings and seeded-file keys against the installed apps and fix the values, not the shape):
- **vscode / cursor** (same builder, different paths and ids): `userDataDirFlag: "--user-data-dir"`, `profileArguments: ["--extensions-dir", dir + "/extensions"]`; `launchArguments(file)` = `["--disable-extensions", "--skip-welcome", "--skip-release-notes", "--disable-workspace-trust"] + [file]` (file as one argument, omitted when nil); `seededFiles["User/settings.json"]` = JSON with `telemetry.telemetryLevel: "off"`, `update.mode: "none"`, `workbench.startupEditor: "none"`, `editor.cursorBlinking: "solid"`; no `typingClickPoint` (opens focused; the live probe may add one). Cursor caveat: a fresh profile may show login/onboarding; if the live probe shows no flag or seed skips it, set affected metrics `unsupported` with that reason (do not add it now). VS Code caveat: none beyond the profile line.
- **sublime**: no profile directory, no data-dir flag or environment key; `launchArguments(file)` = `["--safe-mode"] + [file]`; no seeded files. Caveats: safe mode ignores user settings so the caret may blink (the harness already ignores diffs of at most 4 px width); packages disabled; safe mode keeps Sublime's own separate data folder, and the harness does not clean it (open question for the live probe: whether it persists state outside the temp area).
- **idea**: `dataDirEnvironmentKey: "IDEA_PROPERTIES"`, `dataDirEnvironmentValue: { $0 + "/idea.properties" }`; `seededFiles["idea.properties"]` sets `idea.config.path`, `idea.system.path`, `idea.plugins.path`, `idea.log.path` to `@PROFILE_DIR@/config|system|plugins|log` plus whichever documented keys in `Contents/bin/idea.properties` skip the first-run screens; `seededFiles` under `config/options/` for licence/terms, data sharing, import settings, project trust and tip of the day (XML option files). `launchArguments(file)` = `[file]`. Caveats: post-open indexing inflates startup and memory; the JetBrains consent/EULA state is stored outside the profile, so if the live probe shows a dialog the affected metrics become `unsupported` with the reason (open question, not guessed now); whether `idea` execs the JVM in the same pid is an open question for the probe.
- All four: `bundleID`, `bundlePath` and `executablePath` from the table above; `version()` works through `CFBundleShortVersionString`.

- [ ] **Step 1: Write failing tests** in `EditorTargetsTests` (Swift Testing, nothing launched), for each of the four: id and display name; `bundleID`/`bundlePath`/`executablePath` equal the table; `Launcher.arguments(for:file:userDataDir:)` with dir `/p` and file `/a b/c.swift` equals the exact expected vector (VS Code: `["--user-data-dir","/p","--extensions-dir","/p/extensions","--disable-extensions","--skip-welcome","--skip-release-notes","--disable-workspace-trust","/a b/c.swift"]`; sublime: `["--safe-mode","/a b/c.swift"]`; idea: `["/a b/c.swift"]`) and `nil` file drops only the file; seeded files decode as JSON (VS Code, Cursor `User/settings.json` with the four keys above) or contain every property key (idea, after `Launcher.seed` into a temp dir, no placeholder left); `Launcher.environment` for idea sets `IDEA_PROPERTIES` to `<dir>/idea.properties` and returns nil for the other three; `TargetApp.editors.map(\.id) == ["vscode","cursor","sublime","idea"]` with unique bundle ids and executable paths; refusal matching: `Launcher.rootMost` keeps its existing contract, and each target's `bundleID` is non-empty and its `executablePath` is the string `Launcher.pidsRunning(path:)` is asked about (assert `Launcher.pidsRunning(path: t.executablePath)` returns `[]` only when not running, guarded so the test passes when the editor happens to run); `unsupported` reasons and `caveats` are non-empty strings and pass `Publisher`'s leak scan (call the existing scan helper in `Publish.swift`; if it is private, assert a regex for home-directory paths and the orchestrator's other forbidden patterns instead (build the regex from pieces so the test source itself does not contain the literal patterns)); an installed-app check, enabled only when the `.app` exists (`.enabled(if:)`), reads `Contents/Info.plist` and asserts `CFBundleExecutable` and `CFBundleIdentifier` match the adapter.
- [ ] **Step 2: Run** `--filter EditorTargetsTests` under the lock. Expected: compile failure (no `vscode` etc.).
- [ ] **Step 3: Implement** the adapters and `TargetApp.editors`. Share one private builder for vscode/cursor; put seeded-file strings in small private constants.
- [ ] **Step 4: Run** `--filter EditorTargetsTests`, then `--filter TargetsTests`, `--filter LaunchIsolationTests`. Expected: pass.
- [ ] **Step 5: Commit** `feat(bench): VS Code, Cursor, Sublime Text and IntelliJ IDEA target adapters`.

### Task 3: CLI parsing and an editor catalogue for results, reports and the site

**Files:**
- Modify: `Bench/Sources/BenchScenarios/Runner.swift` (`CLIArguments.resolveApps`)
- Modify: `Bench/Sources/alloy-bench/RunCommand.swift` (`--apps` help text)
- Modify: `Bench/Sources/BenchCore/Results.swift` (`Report.columns`, markdown table, versions line)
- Modify: `Bench/Sources/BenchCore/SitePage.swift` (table header and cells, environment versions, notes loop, lead paragraph, CSS variables and classes)
- Modify: `Bench/Sources/BenchCore/SiteChart.swift` (extra series)
- Test: `Bench/Tests/BenchCoreTests/PreflightTests.swift` (CLI parsing lives with it; confirm by grep for `resolveApps`), `ResultsTests.swift`, `SitePageTests.swift`

**Interfaces:**
- Consumes: `TargetApp.editors`.
- Produces in BenchCore: `public enum EditorCatalog` with `static let all: [(id: String, name: String)]` ordered `zed, delta, vscode, cursor, sublime, idea, alloy` and `static func present(in r: RunResult) -> [(id: String, name: String)]` returning `zed`, `delta` and `alloy` always (as today) plus any of the four new ids that appear in `r.apps` or `r.outcomes`, in catalogue order.
- `CLIArguments.resolveApps` accepts `vscode`, `cursor`, `sublime`, `idea`; defaults stay `zed,delta` (+ `alloy` with `--alloy-build`); the unknown-id error lists all seven ids.
- CSS: add `--vscode`, `--cursor`, `--sublime`, `--idea` colours in the light and dark palettes of `SitePage.css` (distinct from `--zed`/`--alloy`, validated for contrast against the existing background) and matching `.series.<id>`, `.dot.<id>`, `.key.<id>` rules. The landing page `site/index.html` is not touched (race stays Alloy vs Zed).

- [ ] **Step 1: Write failing tests:**
  `resolveApps("vscode,cursor,sublime,idea", alloyBuild: nil)` returns those ids in order; default selection unchanged; unknown id error names `vscode`;
  `Report.markdown` for a result containing `vscode` outcomes has header `| Metric | Zed | Delta | VS Code | Alloy | Note |`, while the existing three-app result still has exactly `| Metric | Zed | Delta | Alloy | Note |` (existing assertion at ResultsTests line 64 must keep passing untouched);
  site table for a result with `sublime` and `idea` has their `<th>` headers, cells and `Sublime Text version` environment rows, and a result without them renders identical to a stored expected string from the current code (capture it before changing anything);
  notes loop emits `IntelliJ IDEA Startup: <note>` lines for new editors;
  a result with only `["idea"]` outcomes (no zed/alloy) renders markdown and page without trapping and `SiteChart.svg` returns nil;
  `SiteChart.svg` for runs where `vscode` is measured in every plotted run contains `class="series vscode"`, and without that data contains no such class; zed/alloy output unchanged otherwise.
- [ ] **Step 2: Run** the three filtered suites under the lock. Expected: FAIL.
- [ ] **Step 3: Implement** `EditorCatalog` (in a new `Bench/Sources/BenchCore/EditorCatalog.swift`) and replace the hard-coded `[("zed","Zed"),("delta","Delta"),("alloy","Alloy")]` lists at `Results.swift` (`Report.columns` becomes per-result via `present(in:)`), `SitePage.swift` table/environment/notes, and the lead sentence (list the editors present, e.g. "measured against Zed, Delta and VS Code"; unchanged text when only the old three are present). Leave `Publisher.partialReason` and `Parity` as they are. `SiteChart` keeps its zed+alloy requirement for plotted points and adds a polyline per extra editor measured at every plotted point.
- [ ] **Step 4: Run** the filtered suites, then the full Bench suite under the lock. Expected: pass.
- [ ] **Step 5: Commit** `feat(bench): accept editor ids and list every measured editor in reports and the site`.

### Task 4: README capability survey and run docs, final verification

**Files:**
- Modify: `Bench/README.md` (capability survey table, unsupported/open-question list, "Quit ... first" step with the four bundle ids and executable names, command examples, per-run profile section like "Delta isolation caveat")
- Modify: `Bench/Sources/BenchCore/Targets.swift` only if a caveat string needs aligning with the README

**Interfaces:** Consumes everything above; produces no code.

- [ ] **Step 1: Add survey rows** for VS Code 1.147.0, Cursor 3.30.14, Sublime Text Build 4215 and IntelliJ IDEA 2026.3 under the existing four rows (app binary, open with a file, isolated profile, cursor-blink handling), each cell stating what was verified by reading and what is an open question for the live probe (Cursor first-run login, Sublime safe-mode data folder, IntelliJ consent state outside the profile and pid after launch, VS Code and Cursor typing focus).
- [ ] **Step 2: Update prose**: intro line, "Unsupported metrics" list (none added; open questions listed), step 2 of "Running a benchmark" naming the new editors, bundle ids and executable names for the refusal (exit 2), command example `--apps vscode,cursor,sublime,idea`, runtime estimate note, a "Per-run profiles" subsection (VS Code/Cursor flags and seeded `User/settings.json`; Sublime `--safe-mode`; IDEA `IDEA_PROPERTIES` properties file and seeded options), and the sentence that the landing page race stays Alloy vs Zed while /benchmarks lists every measured editor.
- [ ] **Step 3: Verify**: `swift build --package-path Bench` (no lock) and the full Bench suite under the lock pass; `swift run --package-path Bench alloy-bench run --help` shows the new ids (help only, launches nothing); run the orchestrator's forbidden-pattern grep over `git diff master --name-only` and confirm no hits; confirm `git diff master --stat` touches only `Bench/` and `docs/`.
- [ ] **Step 4: Commit** `docs(bench): editor capability survey and per-run profile notes`.
