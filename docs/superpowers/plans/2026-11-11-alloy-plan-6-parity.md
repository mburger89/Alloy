# Alloy Plan 6 — Parity and Publishing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure Alloy against Zed (and Delta) at the post-Plan-4 checkpoint, judge every metric against a stated parity bar, triage each shortfall to Alloy or MetalUI, and publish the results as a static GitHub Pages page generated from `alloy-bench`'s JSON.

**Architecture:**
- **`alloy-bench` gains three pure pieces in `BenchCore`:** a parity judge (`Parity`), a publisher that scrubs a result and adds it to a tracked index (`Publish`), and a static page renderer (`SitePage`, HTML plus inline SVG, no JavaScript). The CLI becomes three subcommands, `run` (the default, so today's invocation still works), `publish` and `site`.
- **Attribution:** Alloy, when launched with `ALLOY_FRAME_TIMING=1`, records MetalUI G7 `FrameTiming` and writes it to its per-run data directory on SIGTERM. The harness reads it before deleting that directory and attaches a phase split (queue / build / encode / present) to Alloy's notes. These numbers are never compared across apps; they only decide whether a shortfall is Alloy's or MetalUI's.
- **Runs are the controller's.** Building and unit-testing the harness, the page and the Alloy hook are ordinary tasks. Launching Zed, Delta or Alloy happens only in Task 7, run by the controller after the user says "go".

**Tech Stack:** Swift 6, SwiftPM (`Bench/` package, no MetalUI dependency; Alloy app on `../MetalUI`, read-only), swift-argument-parser 1.5.0, Swift Testing, GitHub Actions Pages deploy (Task 4).

**Spec:** `docs/superpowers/specs/2026-11-07-alloy-design.md` §6.6 (target: "Alloy must be at least on par with Zed (GPUI) on every measured number"; "A shortfall is a defect: find whether it is Alloy's or MetalUI's, and send MetalUI causes to the MetalUI session"; results on a GitHub Pages site generated from the harness's machine-readable output). Harness: `docs/superpowers/plans/2026-11-07-alloy-plan-2-bench.md` and `Bench/README.md`. Roadmap row 6: `docs/superpowers/plans/2026-11-07-alloy-roadmap.md`.

## State at planning time (2026-11-11)

- Branch `bench-fixes` (worktree `../Alloy-bench`, tip `940d955`) is **fully merged** into master: `git log master..bench-fixes` is empty and its tree is clean. Its three fixes (no median from a near-empty run, refuse when another app's window covers the target area, scroll Alloy at its file panel centre) are on master. Nothing to land; the worktree can be removed.
- Branch `plan-4-code-panel` (worktree `../Alloy-plan4`, tip `1df0756`) is **fully merged** (listed by `git branch --merged master`, clean tree).
- The only result on disk is `Bench/results/2026-11-07-131133-Mac18,5.json` (harness `35f2a2e`, before Plan 4 and before the bench fixes). It was taken with the terminal covering the target area, so its Zed typing/memory/large-file and Alloy scroll rows are invalid. **It is not published** (Ruling 5). `Bench/results/` stays git-ignored.
- MetalUI G7 `FrameTiming` is in the `../MetalUI` checkout (`Window.frameTiming`, `docs/frame-timing.md`); `docs/metalui-gaps.md` G7 still says "wiring into Alloy deferred". `FrameTimingSample`'s initializer is `package`, so Alloy tests cannot build samples directly (Task 5 maps them to an Alloy-owned record).

## Global Constraints

- The benchmark never touches an app it did not launch: it refuses when Zed or Delta is already running and never quits, kills or reuses a running Zed, Delta or other user app. It kills only PIDs it started (`Launcher.terminate`). **No `pkill`/`killall`, and no broad kills of any kind**, in code, scripts or steps.
- **Implementer subagents never launch GUI apps**: no Zed, Delta or Alloy, no `swift run … alloy-bench run`, and never `BENCH_LIVE=1`. They run `swift build` / `swift test` (Bench and Alloy) only. Benchmark runs happen only in Task 7, by the controller, after the user says "go".
- MetalUI causes are written up in `docs/metalui-gaps.md` as requests the controller forwards to the MetalUI session. Never edit `../MetalUI`.
- Never write to `~/.claude` or any `.claude/` directory.
- Never brand Alloy, the page or anything else "Claude Code".
- The public repo is published from this one (`tools/publish-public.sh`, with its privacy gate). Tracked files, including published results JSON and the generated page, contain **no personal names, no home-directory paths, no machine-specific temp paths and no session links**. Tests use a fake home such as `/home/tester` and user name `tester`; source never spells the real user name or the gate's patterns as literals.
- Swift Testing only. Zero warnings in `swift build`, `swift test` and `swift build -c release`, for both the root package and `--package-path Bench`.
- Every metric in the comparison is lower-is-better (ms, MiB, %); the parity judge relies on that (`Metric.allCases`: startup, typingLatency, scrollFrames, memory, memoryIdle, largeFileOpen, idleCPU).
- The page is static: one `index.html` with inline CSS (light and dark via `prefers-color-scheme`), inline SVG charts, no scripts, no external fonts or CDNs. It works at phone width with no horizontal page scroll (tables scroll inside their own container).
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and the `Claude-Session:` trailer line the controller gives in its brief. The session URL is never written into any tracked file.

## Rulings (the controller's calls; cost if wrong in brackets)

1. **Parity is judged against Zed only; Delta is shown as context.** The spec's target names Zed. [Low: adding Delta verdicts is one call to `Parity.judge` with another baseline.]
2. **The parity bar lives in one value, `ParityBar.default`** (bar itself: user decision 2026-11-11, Decision 4): Alloy passes a metric when both its median and its p95 are ≤ Zed's value + tolerance, tolerance = max(5 % of Zed's value, a per-unit floor: 1.0 ms, 2.0 MiB, 0.1 %). [Low: constants.]
3. **A metric Zed measured but Alloy did not (`notMeasured` or `notApplicable`) is a shortfall** (verdict `.missing`), triaged like a slow number. A metric neither measured is `.unjudged` and is not counted. [Medium: hides nothing; at worst triage chases a harness problem first, which it should.]
4. **Published results are tracked under `Bench/published/`, scrubbed; scratch runs stay in git-ignored `Bench/results/`.** This meets the spec's "results saved as dated files in the repo" without committing invalid runs. [Low.]
5. **The 2026-11-07 run is not published** (covered target area, pre-fix harness). The first published run is Task 7's. [Low.]
6. **The page is generated into `Bench/site/` and committed; Pages deploys that folder with a workflow, no build on CI** (a macOS Swift build per push would be slow and the page must match reviewed output). A test fails when the committed page drifts from the generator. [Medium: a `gh-pages` branch instead would change Task 4 only.]
7. **The Pages workflow runs only on the public repo** (`if: github.repository == 'mburger89/Alloy'`), so the private repo skips it. [Low.]
8. **One checkpoint covers Plans 3 and 4** (both merged before this plan). A chat-transcript scroll metric (spec: "desirable, builder's call") is out of scope; it gets its own plan if wanted. [Medium: the Plan 3 checkpoint then measures the editor surface only.]
9. **Attribution data never appears on the page** and never feeds a verdict. [Low.]
10. **Triage classification rule:** a shortfall is MetalUI's when a headless `MetalUITesting` reproduction using only MetalUI views (no Alloy code) shows the same cost, or the frame-timing split puts the excess inside MetalUI phases with Alloy's `body` work negligible; otherwise it is Alloy's. [Medium: a misfiled cause wastes a round with the MetalUI session; the gap write-up carries the repro so it can be checked.]

## Decisions (user decision 2026-11-11)

1. **GitHub Pages site on the public Alloy repo** (user decision 2026-11-11). Task 4 is not gated. The first enable and deploy (Task 9 Step 3) happens only after the controller confirms the first real published results look right.
2. **Page content** (user decision 2026-11-11): a table of median and p95 per metric for Zed, Delta and Alloy with a verdict per row; environment and versions; method notes and caveats; one small inline-SVG history chart per metric (Zed vs Alloy medians across published runs, drawn once there are two runs); links to the raw JSON. Raw samples stay in the JSON only.
3. **Apps compared** (user decision 2026-11-11): Zed and Delta are shown; parity is judged against Zed only (Ruling 1).
4. **Pass bar** (user decision 2026-11-11): median and p95 both within max(5 %, 1.0 ms / 2.0 MiB / 0.1 %) of Zed. This is `ParityBar.default` (Ruling 2).
5. **Machine details** (user decision 2026-11-11): the page publishes the Mac model, macOS version and display refresh rate; nothing else about the machine.

## Review Focus

1. **A machine path or the user's name leaks into a published file** (a leftover-process note carries the Alloy binary's path under the home directory; failure reasons can carry temp paths). Expect the publisher to scrub them and refuse to write anything that still matches. Pinned in Task 2 (`scrubsHomeAndTempPaths`, `refusesWhenUserNameRemains`).
2. **A partial or refused run is published as if complete** (exit code 4 writes the metrics measured before the refusal). Expect `publish` to refuse a result in which Zed or Alloy is absent or lacks an outcome for any `Metric`, unless `--allow-partial` is passed, and the page to say "partial run". Pinned in Task 2 (`refusesPartialRunByDefault`).
3. **Noise flips a verdict** (Alloy 0.2 ms behind on a 12 ms typing median). Expect the tolerance floor to call it par. Pinned in Task 1 (`withinFloorIsPar`).
4. **Alloy cannot measure a metric Zed measured** and the page shows it as a gap rather than hiding the row. Pinned in Task 1 (`alloyMissingIsShortfall`) and Task 3 (`missingRowShowsReason`).
5. **The committed page drifts from the published JSON** (someone publishes a run and forgets to regenerate). Expect a test failure naming the command to run. Pinned in Task 3 (`committedSiteIsCurrent`).

---

## File Structure

```
Bench/Sources/BenchCore/Parity.swift            ParityBar, Verdict, Parity.judge
Bench/Sources/BenchCore/Publish.swift           Scrubber, PublishedIndex, Publisher
Bench/Sources/BenchCore/SitePage.swift          SitePage.render (HTML)
Bench/Sources/BenchCore/SiteChart.swift         SiteChart.svg (inline history chart)
Bench/Sources/BenchCore/FrameTimingSummary.swift  decode Alloy's frame-timing.json, summarize to notes
Bench/Sources/BenchCore/Results.swift           Report.markdown uses Parity (modify)
Bench/Sources/BenchDrivers/Launcher.swift       extra env, read frame-timing.json before cleanup (modify)
Bench/Sources/BenchScenarios/*.swift            pass `attribute` through, attach notes (modify)
Bench/Sources/alloy-bench/AlloyBench.swift      root command with subcommands (modify)
Bench/Sources/alloy-bench/RunCommand.swift      today's command body, plus --attribute
Bench/Sources/alloy-bench/PublishCommand.swift
Bench/Sources/alloy-bench/SiteCommand.swift
Bench/Tests/BenchCoreTests/{Parity,Publish,SitePage,FrameTimingSummary}Tests.swift
Bench/published/                                tracked: <stem>.json, index.json
Bench/site/                                     tracked: index.html, data/<stem>.json
Bench/README.md                                 publish/site/attribute sections (modify)
.github/workflows/pages.yml                     Task 4
Sources/AlloyCore/Bench/FrameRecord.swift       FrameRecord, FrameTimingDump (no MetalUI)
Sources/AlloyKit/FrameTimingRecorder.swift      FrameTimingSample -> FrameRecord, install on a window
Sources/Alloy/main.swift                        ALLOY_FRAME_TIMING hook (modify)
Tests/AlloyCoreTests/FrameTimingDumpTests.swift
Tests/AlloyKitTests/FrameTimingRecorderTests.swift
docs/parity.md                                  triage log (Task 8)
docs/metalui-gaps.md                            G7 status; new gap entries (Tasks 5, 8)
```

---

### Task 1: Parity verdicts

**Files:**
- Create: `Bench/Sources/BenchCore/Parity.swift`
- Modify: `Bench/Sources/BenchCore/Results.swift` (`Report.markdown`'s Note column)
- Test: `Bench/Tests/BenchCoreTests/ParityTests.swift`, `Bench/Tests/BenchCoreTests/ResultsTests.swift`

**Interfaces:**
- Consumes: `RunResult`, `Outcome`, `Summary` (`median`, `p95`, `unit`), `Metric` from `Results.swift` / `Targets.swift`.
- Produces:
```swift
public struct ParityBar: Sendable, Equatable {
    public var relative: Double                 // 0.05
    public var floors: [String: Double]         // unit -> absolute floor: "ms": 1.0, "MiB": 2.0, "%": 0.1
    public var judgeP95: Bool                   // true
    public static let `default`: ParityBar
    public func tolerance(baseline: Double, unit: String) -> Double   // max(relative * baseline, floors[unit] ?? 0)
}
public enum Verdict: Sendable, Equatable {
    case ahead            // median and (if judged) p95 strictly below baseline - tolerance
    case par              // within tolerance, not ahead
    case behind(String)   // which statistic, both values, e.g. "median 14.2 ms vs Zed 12.1 ms"
    case missing(String)  // baseline measured, candidate not: the candidate's reason
    case unjudged(String) // baseline not measured: its reason
}
public enum Parity {
    public static func judge(_ r: RunResult, metric: Metric, candidate: String = "alloy",
                             baseline: String = "zed", bar: ParityBar = .default) -> Verdict
    public static func judgeAll(_ r: RunResult, bar: ParityBar = .default) -> [Metric: Verdict]
    public static func isShortfall(_ v: Verdict) -> Bool     // behind or missing
}
```

- [ ] **Step 1: Write the failing tests** in `ParityTests.swift`, each building a `RunResult` with hand-set summaries:
  - `aheadWhenBothStatsClearlyLower`: Zed 248.5/268.2 ms, Alloy 193.5/232.6 ms on startup → `.ahead`.
  - `withinFloorIsPar`: Zed typing 12.1/12.4 ms, Alloy 12.3/12.6 ms → `.par` (floor 1.0 ms > 5 % of 12.1).
  - `p95BehindIsBehind`: medians equal, Alloy p95 30 ms vs Zed 18 ms → `.behind` whose text contains `"p95"`, `"30.0"` and `"18.0"`.
  - `medianOnlyBarIgnoresP95`: same input, `bar.judgeP95 = false` → `.par`.
  - `alloyMissingIsShortfall`: Zed measured, Alloy `.notMeasured("all runs failed: x")` → `.missing` containing `"all runs failed"`; `isShortfall` true.
  - `zedNotMeasuredIsUnjudged`: Zed `.notMeasured`, Alloy measured → `.unjudged`; `isShortfall` false.
  - `unitFloorsApply`: memory Zed 39.0 MiB, Alloy 40.9 MiB → `.par`; Alloy 41.5 MiB → `.behind`.
  - In `ResultsTests.swift`, `noteColumnShowsVerdict`: the markdown row for a `.behind` metric contains `"⚠ behind Zed"` and its reason; a `.missing` row contains `"⚠ missing"`; `.ahead`/`.par` rows contain `"ahead"`/`"par"`.
- [ ] **Step 2: Run** `swift test --package-path Bench --filter "ParityTests|ResultsTests"`. Expected: compile failure (no `Parity`).
- [ ] **Step 3: Implement** `Parity.swift` as specified, then make `Report.markdown` fill the Note column from `Parity.judgeAll` (replacing the strict `a.median > z.median` check). Rows without both Zed and Alloy present keep an empty note.
- [ ] **Step 4: Run** `swift test --package-path Bench` (no `BENCH_LIVE`). Expected: all pass, live tests skipped; `swift build --package-path Bench` has zero warnings.
- [ ] **Step 5: Commit** `feat(bench): parity verdicts against Zed with a tolerance bar`.

### Task 2: Publish a scrubbed result

**Files:**
- Create: `Bench/Sources/BenchCore/Publish.swift`, `Bench/Sources/alloy-bench/RunCommand.swift`, `Bench/Sources/alloy-bench/PublishCommand.swift`, `Bench/published/.gitkeep`
- Modify: `Bench/Sources/alloy-bench/AlloyBench.swift`
- Test: `Bench/Tests/BenchCoreTests/PublishTests.swift`

**Interfaces:**
- Consumes: `RunResult`, `Report.fileStem`, `Parity.judgeAll` (Task 1).
- Produces:
```swift
public struct Scrubber: Sendable {
    public init(home: String, userName: String)                 // the CLI passes NSHomeDirectory(), NSUserName()
    public func scrub(_ s: String) -> String                    // home prefix -> "~"; /private/var/folders/…, /var/folders/…, /private/tmp/…, /tmp/… path tokens -> "<tmp>"
    public func scrub(_ r: RunResult) -> RunResult              // every note, failure and reason string
    public func leaks(in text: String) -> [String]              // remaining hits: the user name (case-insensitive), "/Users/" followed by a letter, a home prefix, a session link
}
public struct PublishedEntry: Codable, Sendable, Equatable {
    public var stem: String; public var date: String; public var harnessSHA: String
    public var apps: [String: String]; public var partial: Bool
    public var verdicts: [String: String]   // metric rawValue -> "ahead" | "par" | "behind" | "missing" | "unjudged"
}
public struct PublishedIndex: Codable, Sendable, Equatable {
    public var schemaVersion: Int            // 1
    public var runs: [PublishedEntry]        // sorted by stem ascending, unique by stem
    public mutating func upsert(_ e: PublishedEntry)
}
public enum Publisher {
    public enum Refusal: Error, Equatable { case partial(String), leak([String]), schema(Int) }
    /// Scrubs `result`, checks it, and returns the JSON to write plus the index entry.
    public static func prepare(_ result: RunResult, scrubber: Scrubber, allowPartial: Bool) throws(Refusal) -> (json: Data, entry: PublishedEntry)
}
```
CLI: `alloy-bench run …` (today's options unchanged; `run` is the `defaultSubcommand`, so `alloy-bench --apps zed,delta` still works) and `alloy-bench publish <result.json> [--to Bench/published] [--allow-partial]`, which writes `<to>/<stem>.json` (pretty, sorted keys) and rewrites `<to>/index.json`.

- [ ] **Step 1: Write the failing tests** in `PublishTests.swift` (fake home `/home/tester`, user `tester`):
  - `scrubsHomeAndTempPaths`: a leftover note `"leftover process: Alloy pid 9 (/home/tester/dev/Alloy/.build/release/Alloy) …"` becomes `"… (~/dev/Alloy/.build/release/Alloy) …"`; a failure `"run 2: cannot read /private/var/folders/ab/xyz/T/bench-1/small.swift"` becomes `"run 2: cannot read <tmp>"`.
  - `refusesWhenUserNameRemains`: a note `"covered by Tester's window"` → `prepare` throws `.leak` naming the matching text.
  - `refusesPartialRunByDefault`: a result with no `"alloy"` outcomes → `.partial`; so does one where Zed lacks `idleCPU`; with `allowPartial: true` it succeeds and `entry.partial == true`.
  - `refusesUnknownSchema`: `schemaVersion: 2` → `.schema(2)`.
  - `entryCarriesVerdicts`: `entry.verdicts["startup"] == "ahead"` for the Task 1 startup fixture.
  - `upsertSortsAndReplaces`: upserting stems `b`, `a`, then `b` again leaves `[a, b]` with the second `b`.
  - `publishedFolderHasNoLeaks`: every file under `Bench/published/` (resolved from `#filePath`) has no `leaks` for the current `NSHomeDirectory()`/`NSUserName()` (passes trivially while the folder only holds `.gitkeep`).
- [ ] **Step 2: Run** `swift test --package-path Bench --filter PublishTests`. Expected: compile failure.
- [ ] **Step 3: Implement** `Publish.swift`. Split the CLI: move today's `AlloyBench.run()` body unchanged into `RunCommand`; `AlloyBench` becomes the root with `subcommands: [RunCommand.self, PublishCommand.self, SiteCommand.self]` (`SiteCommand` arrives in Task 3; add it then) and `defaultSubcommand: RunCommand.self`. A refusal prints its reason and exits 6.
- [ ] **Step 4: Run** `swift test --package-path Bench` and `swift run --package-path Bench alloy-bench publish --help` (help only; launches nothing). Expected: tests pass; help lists `--to` and `--allow-partial`.
- [ ] **Step 5: Commit** `feat(bench): publish subcommand with path scrubbing and a tracked results index`.

### Task 3: Static results page

**Files:**
- Create: `Bench/Sources/BenchCore/SitePage.swift`, `Bench/Sources/BenchCore/SiteChart.swift`, `Bench/Sources/alloy-bench/SiteCommand.swift`, `Bench/site/index.html` (generated from the empty index)
- Modify: `Bench/Sources/alloy-bench/AlloyBench.swift`, `Bench/README.md`
- Test: `Bench/Tests/BenchCoreTests/SitePageTests.swift`

**Interfaces:**
- Consumes: `PublishedIndex`, `PublishedEntry`, `RunResult`, `Parity.judgeAll`.
- Produces:
```swift
public enum SitePage {
    /// `runs` are the published results in index order (oldest first); the newest is the headline.
    public static func render(index: PublishedIndex, runs: [RunResult]) -> String
}
public enum SiteChart {
    /// Zed vs Alloy medians across runs for one metric; nil when fewer than 2 runs have both measured.
    public static func svg(metric: Metric, runs: [RunResult]) -> String?
}
```
CLI: `alloy-bench site [--published Bench/published] [--out Bench/site]` writes `index.html` and copies each published JSON to `<out>/data/<stem>.json`. Output is deterministic (no timestamps, sorted iteration).

Page content (copy fixed here): title "Alloy benchmarks"; a lead line "Alloy (built on MetalUI) measured against Zed and Delta on the same Mac, from outside the apps."; a headline "Alloy is at par or ahead of Zed on N of M measured metrics" from the newest run; a table with columns Metric, Zed, Delta, Alloy, Verdict (cells `median unit (p95 x)`, `n/a — reason`, `not measured — reason`); a "partial run" badge when the entry is partial; environment (date, machine model, macOS, refresh rate, scale, AC/battery, warm/cold, thermal state, harness SHA, app versions); a "How this is measured" section summarising `Bench/README.md` (screen-change detection, median and p95 over N runs, survivor policy, Delta has no isolated profile, scroll frame times floor at one refresh period); history charts; links to each `data/<stem>.json`. With an empty index the page says "No published results yet."

- [ ] **Step 1: Write the failing tests** in `SitePageTests.swift`:
  - `emptyIndexSaysNoResults`: contains `"No published results yet."`, no `<table`.
  - `headlineCountsVerdicts`: fixture with 4 judged metrics, 3 ahead/par → contains `"3 of 4"`.
  - `missingRowShowsReason`: Alloy `.notMeasured("all runs failed: x")` row contains `"not measured — all runs failed: x"` and verdict `"missing"`.
  - `escapesHTML`: a note `"<b>&"` appears as `"&lt;b&gt;&amp;"`.
  - `noScriptsOrExternalResources`: output contains none of `<script`, `http://`, `https://`.
  - `chartNeedsTwoRuns`: `SiteChart.svg` is nil for one run and starts with `"<svg"` for two.
  - `deterministic`: two renders of the same input are byte-identical.
  - `committedSiteIsCurrent`: rendering `Bench/published/` (via `#filePath`) equals the committed `Bench/site/index.html`; failure message: `"Bench/site is stale: run swift run --package-path Bench alloy-bench site"`.
- [ ] **Step 2: Run** `swift test --package-path Bench --filter SitePageTests`. Expected: compile failure.
- [ ] **Step 3: Implement** `SitePage` and `SiteChart` (colours as CSS custom properties on `:root`, redefined under `@media (prefers-color-scheme: dark)`; Zed and Alloy series in two colours distinguishable in both themes, with a text legend; table inside an `overflow-x: auto` wrapper; 16 px side gutter). Add `SiteCommand`, generate `Bench/site/index.html` from the empty index, and add "Publishing" to `Bench/README.md` (`run` → check the md → `publish` → `site` → commit `Bench/published` and `Bench/site`).
- [ ] **Step 4: Run** `swift test --package-path Bench`. Expected: all pass, including `committedSiteIsCurrent`.
- [ ] **Step 5: Commit** `feat(bench): static results page generated from published JSON`.

### Task 4: Pages deploy workflow (Decision 1)

**Files:**
- Create: `.github/workflows/pages.yml`
- Modify: `Bench/README.md` (one paragraph: where the page lives, that the repo's Pages source must be "GitHub Actions")

- [ ] **Step 1: Write `pages.yml`:** trigger `push` to `main` with `paths: ['Bench/site/**']` plus `workflow_dispatch`; one job `deploy` with `if: github.repository == 'mburger89/Alloy'`, `permissions: { contents: read, pages: write, id-token: write }`, `environment: github-pages`, `runs-on: ubuntu-latest`, steps `actions/checkout@v4`, `actions/configure-pages@v5`, `actions/upload-pages-artifact@v3` with `path: Bench/site`, `actions/deploy-pages@v4`. No build step.
- [ ] **Step 2: Verify** the YAML parses: `ruby -ryaml -e 'YAML.load_file(".github/workflows/pages.yml")'` exits 0, and `grep -c "swift" .github/workflows/pages.yml` prints 0.
- [ ] **Step 3: Commit** `ci: deploy Bench/site to GitHub Pages on the public repo`.

Enabling Pages in the public repo's settings is an outward-facing step the controller does in Task 9, only after confirming the first real published results look right.

### Task 5: Alloy writes its frame timing when asked

**Files:**
- Create: `Sources/AlloyCore/Bench/FrameRecord.swift`, `Sources/AlloyKit/FrameTimingRecorder.swift`
- Modify: `Sources/Alloy/main.swift`, `docs/metalui-gaps.md` (G7 status → "adopted (Plan 6 Task 5): benchmark attribution only")
- Test: `Tests/AlloyCoreTests/FrameTimingDumpTests.swift`, `Tests/AlloyKitTests/FrameTimingRecorderTests.swift`

**Interfaces:**
- Produces (the JSON contract Task 6 decodes; nanoseconds as integers):
```swift
public struct FrameRecord: Codable, Sendable, Equatable {
    public var kind: String?          // "key" | "text" | "pointer" | "wheel" | "other" | nil
    public var queueNs: UInt64?       // inputReceived - inputTimestamp
    public var buildNs: UInt64        // paintEnd - buildStart (MetalUI layout/prepaint/paint plus Alloy body evaluation)
    public var encodeNs: UInt64       // commit - paintEnd
    public var inputToCommitNs: UInt64?
    public var inputToPresentedNs: UInt64?
}
public enum FrameTimingDump {
    public static let fileName = "frame-timing.json"
    public static func encode(_ frames: [FrameRecord]) throws -> Data   // {"schemaVersion":1,"frames":[…]}
    public static func decode(_ data: Data) throws -> [FrameRecord]
}
// AlloyKit
@MainActor public enum FrameTimingRecorder {
    public static func record(_ s: FrameTimingSample) -> FrameRecord
    /// When env["ALLOY_FRAME_TIMING"] == "1" and env["ALLOY_DATA_DIR"] is set: sets window.frameTiming = FrameTiming(capacity: 8192)
    /// and returns the dump URL; else returns nil and leaves frameTiming nil.
    public static func install(on window: Window, environment: [String: String]) -> URL?
    public static func write(_ timing: FrameTiming, to url: URL) throws
}
```

- [ ] **Step 1: Write the failing tests:**
  - `FrameTimingDumpTests.roundTrips`: two records (one with nil input fields) encode and decode equal; the JSON contains `"schemaVersion":1`.
  - `FrameTimingRecorderTests.offWithoutFlag`: `install(on:environment: [:])` returns nil and `window.frameTiming == nil` (a `TestWindow`).
  - `FrameTimingRecorderTests.onWithFlagAndDataDir`: with both variables (data dir = a temp dir), returns `<dir>/frame-timing.json` and `frameTiming != nil`; after driving two frames headlessly, `write` produces a file whose decoded `frames.count >= 2` and every `buildNs`/`encodeNs` is finite.
- [ ] **Step 2: Run** `swift test --filter "FrameTimingDumpTests|FrameTimingRecorderTests"`. Expected: compile failure.
- [ ] **Step 3: Implement** both types; in `main.swift`, after `openWindow`, call `install`; when it returns a URL, ignore the default SIGTERM disposition and add a `DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)` handler that writes the dump (errors ignored) and then exits 0. Without the flag, SIGTERM behaviour is unchanged.
- [ ] **Step 4: Run** `swift build`, `swift build -c release` and `swift test`. Expected: zero warnings, all pass. Do not launch the app.
- [ ] **Step 5: Commit** `feat(bench): Alloy dumps MetalUI frame timing on SIGTERM when ALLOY_FRAME_TIMING=1`.

### Task 6: Harness collects Alloy's frame timing as notes

**Files:**
- Create: `Bench/Sources/BenchCore/FrameTimingSummary.swift`
- Modify: `Bench/Sources/BenchDrivers/Launcher.swift`, `Bench/Sources/BenchScenarios/Runner.swift`, `Bench/Sources/BenchScenarios/Scenarios.swift`, `Bench/Sources/alloy-bench/RunCommand.swift`, `Bench/README.md`
- Test: `Bench/Tests/BenchCoreTests/FrameTimingSummaryTests.swift`, `Bench/Tests/BenchCoreTests/LaunchIsolationTests.swift`

**Interfaces:**
- Consumes: Task 5's JSON (`{"schemaVersion":1,"frames":[{kind,queueNs,buildNs,encodeNs,inputToCommitNs,inputToPresentedNs}]}`), decoded with a Bench-local Codable mirror (Bench has no Alloy or MetalUI dependency).
- Produces:
```swift
public enum FrameTimingSummary {
    /// One note per input kind present, e.g. "Alloy internal (key, 200 frames): queue 0.4 / build 3.1 / encode 0.6 / input→present 9.8 ms median";
    /// frames with no input kind summarised as "Alloy internal (no input, N frames): build … / encode … ms median". Empty for undecodable data.
    public static func notes(from data: Data) -> [String]
}
// Launcher
public static func environment(for app: TargetApp, userDataDir: String?, extra: [String: String] = [:],
                               base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String]?
public static func terminate(_ launched: LaunchedApp, collecting fileName: String? = nil) async -> Data?
    // reads <userDataDir>/<fileName> after the process tree exits and before the directory is removed
```
CLI: `alloy-bench run --attribute` adds `ALLOY_FRAME_TIMING=1` to Alloy launches only and appends `FrameTimingSummary.notes` to each Alloy metric's notes. Without the flag nothing changes.

- [ ] **Step 1: Write the failing tests:**
  - `FrameTimingSummaryTests.splitsByKind`: three key frames with buildNs 2_000_000, 3_000_000, 4_000_000 → a note containing `"key, 3 frames"` and `"build 3.0"`.
  - `FrameTimingSummaryTests.garbageGivesNoNotes`: `Data("x".utf8)` → `[]`.
  - `LaunchIsolationTests.extraEnvOnlyForAlloy`: `environment(for: .alloy(…), userDataDir: "/tmp/d", extra: ["ALLOY_FRAME_TIMING": "1"], base: [:])` contains both keys; for `.zed` the result has no `ALLOY_FRAME_TIMING`.
- [ ] **Step 2: Run** `swift test --package-path Bench --filter "FrameTimingSummaryTests|LaunchIsolationTests"`. Expected: compile failure.
- [ ] **Step 3: Implement**; thread an `attribute: Bool` from `RunCommand` through `Runner.run` to the scenarios' Alloy launches and `terminate(_:collecting: "frame-timing.json")`.
- [ ] **Step 4: Run** `swift test --package-path Bench` (no `BENCH_LIVE`). Expected: all pass, zero warnings.
- [ ] **Step 5: Commit** `feat(bench): --attribute collects Alloy's internal frame phases as notes`.

### Task 7: Checkpoint run (controller only, after the user says "go")

No subagent runs this task. No code changes.

- [ ] **Step 1: Prepare without launching anything:** on master with Tasks 1–6 merged, `swift build -c release` (Alloy) and `swift build --package-path Bench -c release`. Check (read-only) that Zed and Delta are not running and list on-screen windows of other apps; tell the user what to move, minimise or quit themselves (the harness and the controller never touch them), and to turn on Do Not Disturb, keep AC power and a single display.
- [ ] **Step 2: Wait for the user's "go".**
- [ ] **Step 3: Run** `swift run --package-path Bench -c release alloy-bench run --apps zed,delta,alloy --alloy-build <Alloy repo root> --attribute` in the background (about 40 minutes). Exit codes 2–5 mean nothing unsafe happened; report the message to the user and stop.
- [ ] **Step 4: Read the `.md`.** The run is publishable when it exited 0, the thermal state is nominal, power is AC, and no metric failed for a setup reason ("covered by", "screen region changed before window existed"). Otherwise fix the setup with the user and rerun the affected metrics with `--metrics`.
- [ ] **Step 5: Publish** with `alloy-bench publish Bench/results/<stem>.json`, then `alloy-bench site`; run `swift test --package-path Bench`; commit `Bench/published` and `Bench/site` as `bench: publish <stem> checkpoint (after Plans 3 and 4)`.

### Task 8: Triage every shortfall

**Files:**
- Create: `docs/parity.md`
- Modify: `docs/metalui-gaps.md` (one entry per MetalUI cause), this plan (append one fix task per Alloy cause)

- [ ] **Step 1: List shortfalls** (`Parity.isShortfall`) from the published run into `docs/parity.md`: one section per metric with Zed and Alloy median/p95, the verdict text, and the attribution notes.
- [ ] **Step 2: Investigate each** (implementer subagents may read code and write headless `MetalUITesting` reproductions; no GUI launches). Apply Ruling 10. Record cause, owner (Alloy / MetalUI / harness), evidence (test name, numbers) and next action.
- [ ] **Step 3: MetalUI causes:** add a `docs/metalui-gaps.md` entry (next free G number) with use case, measured numbers, the headless repro and the expected result; the controller forwards it to the MetalUI session. Never edit `../MetalUI`.
- [ ] **Step 4: Alloy or harness causes:** append a task to this plan per cause, in this plan's step style (failing test, fix, verify), then execute it like Tasks 1–6.
- [ ] **Step 5: Re-measure** only the affected metrics (`--metrics`), via Task 7's Steps 1–5 (user "go" each time), and update `docs/parity.md` with the new verdicts.
- [ ] **Step 6: Commit** `docs: parity triage for <stem>`.

### Task 9: Publish and keep it current

- [ ] **Step 1:** Update roadmap row 6 status ("checkpoint <date> published; N of M at par or ahead; open shortfalls in `docs/parity.md`") and commit.
- [ ] **Step 2:** Push master to the private origin and run `tools/publish-public.sh` per the standing public-sync rule (privacy gate must pass; never force-push).
- [ ] **Step 3 (Decision 1; first time only after the controller confirms the first real published results look right):** set the public repo's Pages source to "GitHub Actions"; confirm the `deploy` run succeeded and the page loads.
- [ ] **Step 4:** After every later plan that touches the editor or chat merges, repeat Task 7 (new checkpoint), Task 8 for new shortfalls, and Steps 1–2 here.
