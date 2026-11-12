# Plan 6b: Profiling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Find hot spots fast. (A) `alloy-bench run --trace <kind>` records an Instruments trace of any benchmark measurement, for Alloy and for Zed, and `alloy-bench hotspots` turns a trace into a short text list of the top functions or allocators. (B) A package-benchmark suite times Alloy's hot paths headlessly and fails when one gets slower than a local baseline.

**Architecture:** (A) lives in the existing `Bench/` package: a `TraceRecorder` attaches `xcrun xctrace record --attach <pid>` to the app the harness just launched and stops it when the scenario body ends; traced runs are marked and can never be published. `hotspots` runs `xctrace export` and aggregates the exported XML. (B) is a new sibling package `Benchmarks/` that depends on the root package by path and uses ordo-one/package-benchmark.

**Tech Stack:** Swift 6, swift-argument-parser (already in Bench), `xctrace` from Xcode, ordo-one/package-benchmark.

**Spec:** none written; the design is the user's approval on 2026-11-11 of: "an option to the benchmark that records an Instruments profile alongside any measure, e.g. `alloy-bench run --apps alloy --metrics memory --trace allocations` … Zed could be profiled the same way … separately, a small package-benchmark suite for the hot paths would catch slowdowns automatically." This plan's Global Constraints and decisions are binding in its place.

## Global Constraints

- Traced runs are never published: `Publisher.prepare` refuses a result whose `traced` is true, exactly as it refuses `attributed`.
- The harness never prompts for a password and never hangs: if Developer Tools access is not enabled (`DevToolsSecurity -status` does not say "enabled"), `--trace` exits before launching anything, with the message `Instruments needs Developer Tools access to attach. Run once: sudo DevToolsSecurity -enable` and exit code 2. Every `xctrace` child has a start timeout (15 s) and a stop timeout (30 s after SIGINT, then SIGKILL of that child only).
- Kill only processes the harness started. No broad pkill.
- Subagents never launch GUI apps or `xctrace` against GUI apps; their tests use fake executables or headless CLI processes. Live traces are the controller's step.
- Traces go to `Bench/traces/` (git-ignored). Nothing derived from a trace (paths, user names, hostnames) is committed. Test fixtures are hand-written and must pass the privacy gate (the forbidden-content pattern in `tools/publish-public.sh`; use `/home/tester` for paths).
- Never write to `~/.claude` or a project's `.claude`. Never edit `../MetalUI`.
- package-benchmark runs without jemalloc (`BENCHMARK_DISABLE_JEMALLOC=true`, no Homebrew dependency); its metrics are wall clock, CPU total, peak resident memory and throughput.
- Micro-benchmark baselines are machine-specific and stay local (`Benchmarks/.benchmarkBaselines/` git-ignored).
- Dependencies are pinned exactly (repo convention): package-benchmark at the newest 1.x release tag on the day of implementation; record the tag in the commit message.
- Commit trailers on every commit:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and the `Claude-Session:` trailer line given by the controller; never put the session URL in a tracked file.

## Decisions

1. Trace kinds and their xctrace templates: `time` → "Time Profiler", `allocations` → "Allocations", `hitches` → "Animation Hitches", `gpu` → "Metal System Trace", `concurrency` → "Swift Concurrency".
2. Attach, not launch: the harness keeps launching apps itself (startup timing stays its own); the recorder attaches to the pid right after `Launcher.launch` returns. Startup work before the attach completes is not in the trace; the notes say so.
3. Only the first run of each (app, metric) is traced; later runs are measured normally. `--trace` without `--runs` is allowed.
4. Attach failures (Zed's hardened runtime refuses Allocations; a template the app cannot be attached with) never fail the measurement: the run note reads `trace unavailable for <App> <metric>: <first line of xctrace's error>`.
5. `hotspots` summarises `time` (top 25 functions by self samples, plus by total samples) and `allocations` (top 25 responsible callers by bytes still live and by total bytes). Other kinds get the exported table-of-contents list and a line saying to open the trace in Instruments.
6. Micro-benchmark package lives at `Benchmarks/` with one target `AlloyHotPaths`; the root `Package.swift` gains library products `AlloyCore` and `AlloyHighlight` so it can depend on them.

## Review Focus

1. Developer Tools access is off → `--trace` refuses before launching any app, with the exact message and exit code 2 (Task A2 test).
2. `xctrace` hangs (password prompt, wedged attach) → the run continues within 15 s / 30 s and no `xctrace` child is left behind (Task A1 tests with a fake executable that ignores SIGINT).
3. The app exits before the stop → recorder stop returns promptly and the trace note says the trace may be partial (Task A1 test).
4. A traced result fed to `alloy-bench publish` → refused with a message naming `--trace` (Task A2 test).
5. A trace export with no samples or unknown schema → `hotspots` prints "no rows in <table>" and exits 0, not a crash (Task A3 test).

---

### Task A1: TraceRecorder

**Files:**
- Create: `Bench/Sources/BenchDrivers/TraceRecorder.swift`
- Modify: `Bench/Sources/BenchCore/` (add `TraceKind` next to `Metric`)
- Test: `Bench/Tests/BenchCoreTests/TraceRecorderTests.swift`

**Interfaces:**
- Produces: `public enum TraceKind: String, CaseIterable, Sendable { case time, allocations, hitches, gpu, concurrency; public var template: String }`;
  `public final class TraceRecorder: @unchecked Sendable` with
  `public static func arguments(kind: TraceKind, pid: pid_t, output: String) -> [String]` (→ `["xctrace", "record", "--template", kind.template, "--attach", "\(pid)", "--output", output, "--no-prompt"]`, run via `/usr/bin/xcrun`),
  `public init(kind: TraceKind, pid: pid_t, output: String, executable: String = "/usr/bin/xcrun", startTimeout: Duration = .seconds(15), stopTimeout: Duration = .seconds(30))`,
  `public func start() async -> TraceStartResult` (`.recording` once the child prints a line containing `Starting recording` and is still alive; `.failed(String)` if it exits or times out — on timeout it SIGKILLs its child),
  `public func stop() async -> TraceStopResult` (`.saved(path)`, `.partial(path, reason)`, `.failed(reason)`).

- [ ] **Step 1: Write the failing tests.** Use a fake executable script written to a temp dir (bash) instead of xcrun:
  - `argumentsMatchXctrace`: `arguments(kind: .allocations, pid: 42, output: "/home/tester/t.trace")` equals the array above with template "Allocations".
  - `templatesMatchDecision1`: every `TraceKind`'s template equals the Decision 1 table.
  - `startSucceedsWhenRecordingBegins`: fake prints `Starting recording with the Time Profiler template.` then sleeps until SIGINT, writes the output dir, exits 0 → `start()` == `.recording`, `stop()` == `.saved(output)`.
  - `startTimesOutAndKillsChild`: fake prints nothing and sleeps 600 s; `startTimeout: .milliseconds(300)` → `.failed` containing "timed out", and the child pid is gone afterwards (`kill(pid, 0) == -1`).
  - `startFailureCarriesFirstErrorLine`: fake prints `Cannot find process for provided pid: 42` to stderr and exits 1 → `.failed("Cannot find process for provided pid: 42")`.
  - `stopEscalatesWhenSigintIgnored`: fake traps SIGINT and keeps sleeping; `stopTimeout: .milliseconds(300)` → `.failed` containing "did not stop", child gone.
  - `stopAfterChildExitedIsPartial`: fake prints the start line then exits 0 after 100 ms without writing output → `stop()` == `.failed` or `.partial`, returning within 1 s.
- [ ] **Step 2:** `swift test --package-path Bench --filter TraceRecorderTests` → fails (types missing).
- [ ] **Step 3:** Implement with `Process`, pipes read on a background task, `Task.sleep`-based timeouts; SIGINT via `process.interrupt()`, then `kill(pid, SIGKILL)` of that child only.
- [ ] **Step 4:** Tests pass; whole Bench suite passes.
- [ ] **Step 5:** Commit `Bench: TraceRecorder wraps xctrace attach with start/stop timeouts`.

### Task A2: `run --trace`

**Files:**
- Modify: `Bench/Sources/alloy-bench/RunCommand.swift`, `Bench/Sources/BenchScenarios/Harness.swift`, `Bench/Sources/BenchScenarios/Runner.swift`, `Bench/Sources/BenchCore/` (RunResult, Preflight, Publish), `Bench/.gitignore` (add `traces/`), `Bench/README.md`
- Test: `Bench/Tests/BenchCoreTests/TraceRunTests.swift`

**Interfaces:**
- Consumes: `TraceKind`, `TraceRecorder` (Task A1).
- Produces: `RunResult.traced: Bool` (Codable, default false when absent so old results decode); `Preflight.checkDevTools(status: String) -> PreflightFailure?` (pure: input is `DevToolsSecurity -status` output); `TraceSession` (actor or class, like `AttributionCollector`) holding kind, output directory `Bench/traces/<stem>/`, and the set of (app, metric) already traced; trace file name `<appId>-<metric>.trace`.

- [ ] **Step 1: Failing tests:**
  - `devToolsDisabledRefuses`: `checkDevTools(status: "Developer mode is currently disabled.")` → failure with the exact Global Constraints message and code 2; `"Developer mode is currently enabled."` → nil.
  - `tracedResultIsRefusedByPublisher`: a `RunResult` with `traced: true` → `Publisher.prepare` throws/refuses with a message containing `--trace`; mirror the existing `attributed` refusal test.
  - `oldResultsDecodeUntraced`: JSON without `traced` decodes with `traced == false`.
  - `onlyFirstRunIsTraced`: `TraceSession.shouldTrace(app: "alloy", metric: .memory)` true once, then false; true again for `("zed", .memory)`.
  - `unavailableNoteText`: the note for a failed attach is `trace unavailable for Zed memory: <reason>`; a saved trace adds `trace: <appId>-<metric>.trace (<kind>; attached after launch, so launch work before the attach is missing)`.
  - `markdownFlagsTracedRuns`: `Report.markdown` of a traced result has a line `- Traced (<kind>): timings include profiler overhead; not publishable`.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** `RunCommand`: `@Option(help: "Record an Instruments trace of the first run of each measurement: time, allocations, hitches, gpu, concurrency (never publishable)") var trace: TraceKind?`; when set, run `/usr/sbin/DevToolsSecurity -status` and apply `checkDevTools` before `Preflight.check`. `Harness.withApp`: after launch, if the session says to trace this (app, metric), start a `TraceRecorder` for `l.pid`; stop it in `cleanup()` before `Launcher.terminate`. Notes per Decision 4.
- [ ] **Step 4:** Tests pass; whole Bench suite passes; `swift build --package-path Bench -c release`.
- [ ] **Step 5:** Commit `Bench: run --trace records an Instruments trace per measurement`.

### Task A3: `hotspots`

**Files:**
- Create: `Bench/Sources/alloy-bench/HotspotsCommand.swift`, `Bench/Sources/BenchCore/Hotspots.swift`, fixtures `Bench/Tests/BenchCoreTests/Fixtures/time-profile.xml`, `allocations.xml`
- Test: `Bench/Tests/BenchCoreTests/HotspotsTests.swift`

**Interfaces:**
- Produces: `alloy-bench hotspots <trace> [--top 25]` writing `<trace>.md` and printing it; `Hotspots.timeProfile(xml: Data, top: Int) -> [HotspotRow]` and `Hotspots.allocations(xml: Data, top: Int) -> [HotspotRow]`; `struct HotspotRow { var name: String; var selfValue: Double; var totalValue: Double; var unit: String }`.

- [ ] **Step 1: Learn the schema headlessly.** Record a CLI process (not a GUI app): `xcrun xctrace record --template "Time Profiler" --time-limit 2s --output /tmp/<scratch>/yes.trace --launch -- /usr/bin/yes > /dev/null` (only if Developer Tools access is already enabled; if `DevToolsSecurity -status` says disabled, report NEEDS_CONTEXT instead of prompting), then `xcrun xctrace export --input … --toc` and `--xpath '/trace-toc/run/data/table[@schema="time-profile"]'`; same for Allocations. Note: xctrace export de-duplicates repeated elements with `id`/`ref` attributes; the parser must resolve `ref`.
- [ ] **Step 2: Write fixtures by hand** in that schema (≤60 rows each, invented function names like `HighlightCore.parse`, no real paths), then failing tests: `timeProfileRanksBySelfSamples` (exact top-3 names and counts from the fixture), `refsAreResolved` (a frame given once by `id` and later by `ref` is counted under its name), `allocationsRanksByLiveBytes`, `emptyTableIsReported` (no rows → message "no rows in time-profile", exit 0), `unknownKindListsTOC`.
- [ ] **Step 3:** Run → fail. **Step 4:** Implement with `XMLParser` (Foundation). **Step 5:** Tests pass; commit `Bench: hotspots summarises time and allocation traces`.

### Task A4 (controller, live): first traces

- [ ] Confirm `DevToolsSecurity -status` is enabled (the user runs `sudo DevToolsSecurity -enable` once, by hand, if not).
- [ ] With the user's "go": `alloy-bench run --apps zed,alloy --metrics memory,typingLatency --trace time --alloy-build <repo>` and once with `--trace allocations`; run `hotspots` on each trace; check the notes for Zed's expected Allocations refusal; add findings to `docs/parity.md`. Traces stay local.

### Task B1: Benchmarks package and first benchmarks

**Files:**
- Modify: root `Package.swift` (products `.library(name: "AlloyCore", targets: ["AlloyCore"])`, `.library(name: "AlloyHighlight", targets: ["AlloyHighlight"])`), `.gitignore` or `Benchmarks/.gitignore` (`.build/`, `.benchmarkBaselines/`)
- Create: `Benchmarks/Package.swift`, `Benchmarks/Benchmarks/AlloyHotPaths/AlloyHotPaths.swift`, `tools/microbench.sh`

**Interfaces:**
- Produces: `cd Benchmarks && BENCHMARK_DISABLE_JEMALLOC=true swift package benchmark` runs the suite; `tools/microbench.sh update` stores the local baseline `local`; `tools/microbench.sh check` compares against it and exits non-zero on a regression beyond thresholds (wall clock p50 +10%, peak resident memory +10%).

- [ ] **Step 1:** `Benchmarks/Package.swift` (tools 6.0, macOS 14), dependency on package-benchmark (exact, newest 1.x) and `.package(name: "Alloy", path: "..")`, executable target `AlloyHotPaths` at path `Benchmarks/AlloyHotPaths` with the Benchmark plugin, as package-benchmark's README requires.
- [ ] **Step 2:** Benchmarks, each loading the Bench corpus (`../Bench/Corpus/{small,medium,large}.rs`) once in setup:
  - `HighlightEngine open+viewport` for small, medium and large (large exercises the windowed path), metrics wall clock + peak resident memory.
  - `HighlightEngine keystroke` on medium: one `edit` + viewport `captures`, scaling factor ×100.
  - `CodeBuffer typing` (MetalUI's buffer, via AlloyCore's re-export or a direct MetalUI product dependency — whichever the root package already exposes): 1,000 single-character inserts in the middle of large.rs plus a snapshot per insert.
- [ ] **Step 3:** Run the suite twice; it must complete without jemalloc and print results. `tools/microbench.sh update` then `check` passes against itself.
- [ ] **Step 4:** Root `swift build` and `swift test` still pass (the new products must not change targets).
- [ ] **Step 5:** Commit `Benchmarks: package-benchmark suite for highlight and buffer hot paths (package-benchmark <tag>)`.

### Task B2: Ledger, overlap and wire benchmarks; docs

**Files:**
- Modify: `Benchmarks/Benchmarks/AlloyHotPaths/AlloyHotPaths.swift`, `README.md` (a short "Profiling" section), `Bench/README.md` (`--trace`, `hotspots`)

- [ ] **Step 1:** Add benchmarks, reusing the setups their unit tests already build (find them in `Tests/AlloyCoreTests`):
  - `EditHistory apply` — 500 Claude edits applied to a medium-sized file's ledger, then a line-attribution query for every line.
  - `OverlapIndex query` — the large-file-many-edits setup from `OverlapIndexTests.queryIsFastOnALargeFileWithManyEdits`, 1,000 `overlaps(for:range:)` queries.
  - `Wire decode` — 10,000 stream-json lines (built from the fixtures the wire tests use) decoded into `InboundMessage`.
  - `Transcript replay` — a generated 5,000-message `.jsonl` replayed through the transcript loader.
- [ ] **Step 2:** Run the suite; each benchmark completes in under 10 s total; `tools/microbench.sh update` / `check`.
- [ ] **Step 3:** Docs: README "Profiling" section (three commands: `run --trace`, `hotspots`, `tools/microbench.sh`) and the one-time `sudo DevToolsSecurity -enable` note.
- [ ] **Step 4:** Commit `Benchmarks: ledger, overlap, wire and transcript hot paths; profiling docs`.

### Task C: finish

- [ ] Whole-branch review; merge; private push; public sync via `tools/publish-public.sh` (privacy gate must pass); update the roadmap's row 6 to mention 6b.
