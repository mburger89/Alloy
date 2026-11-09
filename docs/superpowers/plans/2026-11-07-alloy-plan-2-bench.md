# Alloy Plan 2 — Benchmark Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `alloy-bench` is a command-line harness that measures Zed, Delta and Alloy the same way from outside on this Mac. It covers startup, typing latency, scroll frame times, memory, large-file open, and idle CPU. Results are written as dated JSON plus a Markdown summary, with medians and p95s.

**Architecture:** A separate SwiftPM package at `Alloy/Bench/` with no MetalUI dependency.
- `BenchCore` holds the logic that can be tested: stats, results schema, frame-change detection, process-tree metrics, and target definitions.
- `BenchDrivers` holds the OS-facing pieces: window lookup, ScreenCaptureKit capture, and CGEvent input.
- `alloy-bench` is the command-line tool.

All six metrics come from what is on screen and from the OS, so all three apps are treated identically. When MetalUI's G7 `FrameTiming` is available, Alloy additionally records its internal frame timings for attribution. Those are never used for cross-app comparison.

**Tech Stack:** Swift 6, macOS 14+, ScreenCaptureKit, CoreGraphics (`CGEvent`, `CGWindowListCopyWindowInfo`), `libproc` (`proc_pid_rusage` with `RUSAGE_INFO_V4`, `proc_listchildpids`), Swift Testing, and swift-argument-parser.

**Spec:** `docs/superpowers/specs/2026-11-07-alloy-design.md` §6.6 (target: Alloy at least on par with Zed; results go on a GitHub Pages site later). Roadmap: `docs/superpowers/plans/2026-11-07-alloy-roadmap.md`.

## Global Constraints

- Targets: `/Applications/Zed.app` (1.27.0, CLI `/opt/homebrew/bin/zed`), `/Applications/Delta.app` (0.1.0, `com.zed-industries.delta`), and Alloy (`Alloy/.build/release/Alloy`, built with `swift build -c release`). Record the version of each app in every result.
- Every metric is reported as median and p95 over N runs. Defaults: startup 10, typing 200 keystrokes, scroll 5 runs of 3 s, memory 5, large-file open 10, idle CPU 3 runs of 30 s. Each result also records:
  - the date
  - the Mac model and macOS version
  - the display refresh rate and scale
  - whether the run was on power or battery
  - cold or warm
- The harness never modifies an app's settings files. Zed's settings are read-only to us, and any per-run setting (such as disabling cursor blink) goes in a temporary profile or through CLI flags where the app supports them; otherwise it is recorded as a caveat.
- The harness kills only processes it launched, tracked by PID. **Never `pkill`/`killall` by name**: the user's own Zed may be running. If an instance of a target is already running, refuse with a message rather than touching it.
- Required permissions: Screen Recording and Accessibility for the terminal running the harness. Check them with `CGPreflightScreenCaptureAccess()` and `AXIsProcessTrusted()`, and print exact instructions when either is missing. Tests that need them are gated on `BENCH_LIVE=1`.
- Cold start uses `sudo -n purge` only if passwordless sudo works; otherwise cold start is reported as `"not measured: purge needs sudo"`. Never prompt for a password.
- Commit attribution lines as in Plan 1.

## Review Focus

1. **The user's own Zed or Delta is already running.** The harness refuses with a clear message naming the app and never kills or reuses it. Pinned in Task 6.
2. **Permissions are missing.** The harness prints which permission is missing, where to grant it, and exits non-zero before launching anything. Pinned in Task 6.
3. **A metric doesn't apply to an app** (for example, Delta may not open arbitrary files, and Alloy has no typing until Plan 4). The result records `"n/a: <reason>"` instead of a zero or a crash. Pinned in Task 1 (capabilities) and Task 6.
4. **Caret blink and cursor animation are mistaken for a typing response.** Changes inside a region at most 4 px wide are ignored. Pinned in Task 3.
5. **A launched app never shows a window** (crash, first-run dialog, Gatekeeper). The run times out after 30 s, is recorded as a failed sample with the reason, and the app's process tree is terminated. Pinned in Task 5.

---

## File Structure

```
Bench/
  Package.swift
  Sources/BenchCore/  Stats.swift  Results.swift  FrameDiff.swift  ProcessTree.swift  Targets.swift
  Sources/BenchDrivers/  Windows.swift  Capture.swift  Input.swift  Launcher.swift
  Sources/BenchScenarios/  Startup.swift  Typing.swift  Scroll.swift  Memory.swift  LargeFileOpen.swift  IdleCPU.swift
  Sources/alloy-bench/main.swift
  Tests/BenchCoreTests/…
  Corpus/  generate.swift  small.swift  medium.swift  large.swift  MANIFEST.sha256
  results/  YYYY-MM-DD-<machine>.json  YYYY-MM-DD-<machine>.md
  README.md
```

---

### Task 1: Package, targets and capability survey

**Files:**
- Create: `Bench/Package.swift`, `Bench/Sources/BenchCore/Targets.swift`, `Bench/README.md`
- Test: `Bench/Tests/BenchCoreTests/TargetsTests.swift`

**Interfaces:**
- Produces:
```swift
public enum Metric: String, Codable, CaseIterable, Sendable { case startup, typingLatency, scrollFrames, memory, largeFileOpen, idleCPU }
public struct TargetApp: Sendable {                // not Codable (holds a closure); results store id + version only
  public var id: String                       // "zed", "delta", "alloy"
  public var displayName: String; public var bundlePath: String?; public var executablePath: String
  public var launchArguments: @Sendable (_ file: String?) -> [String]
  public var unsupported: [Metric: String]    // metric → reason
  public static let zed: TargetApp; public static let delta: TargetApp; public static func alloy(buildDir: String) -> TargetApp
  public func version() -> String             // CFBundleShortVersionString; for Alloy `git -C <Alloy repo> describe --always --dirty`
}
```

- [ ] **Step 1: Survey the capabilities by hand and write the results into `Bench/README.md`.**
  - For Delta and Zed, find out:
    - how to launch each with a file to open (Zed: `zed <file>`; Delta: check `delta --help`, the `delta://` URL scheme and drag-open)
    - whether a fresh, isolated profile is possible (e.g. Zed's `--user-data-dir` if present in `zed --help`)
    - whether cursor blink can be disabled without touching user settings
  - For Alloy (Plan 1), typing is unsupported until Plan 4 ("read-only file panel").
  - Every unsupported metric gets a one-line reason.
- [ ] **Step 2: Write the failing tests:**
  - `targetsHaveStableIDs`: `zed.id == "zed"`, `delta.id == "delta"`, `alloy(…).id == "alloy"`.
  - `unsupportedMetricsHaveReasons`: every value in `unsupported` is non-empty.
  - `alloyTypingUnsupportedUntilPlan4`: `alloy(…).unsupported[.typingLatency]` contains `"Plan 4"`.
  - `zedLaunchArgsIncludeFile`: `zed.launchArguments("/tmp/a.swift")` contains `"/tmp/a.swift"`.
- [ ] **Step 3: Run the tests to confirm they fail.**
  Run: `swift test --package-path Bench --filter TargetsTests`
  Expected: compile failure.
- [ ] **Step 4: Implement** `Package.swift`:
  - Targets: BenchCore, BenchDrivers (→ BenchCore), BenchScenarios (→ both), and the `alloy-bench` executable (→ all, plus `ArgumentParser`).
  - `swift-argument-parser` pinned to an exact release at least two weeks old.
  - Fill in `Targets.swift` from the survey.
- [ ] **Step 5: Run the tests to confirm they pass.**
  Run: `swift test --package-path Bench --filter TargetsTests`
  Expected: all pass.
- [ ] **Step 6: Commit** with message `feat(bench): package skeleton, target apps and capability survey`.

### Task 2: Stats and results

**Files:**
- Create: `Bench/Sources/BenchCore/Stats.swift`, `Bench/Sources/BenchCore/Results.swift`
- Test: `Bench/Tests/BenchCoreTests/StatsTests.swift`, `Bench/Tests/BenchCoreTests/ResultsTests.swift`

**Interfaces:**
- Produces:
```swift
public struct Summary: Codable, Sendable, Equatable { public var count: Int; public var median: Double; public var p95: Double; public var min: Double; public var max: Double; public var unit: String }
public enum Stats { public static func summarize(_ samples: [Double], unit: String) -> Summary? }   // nil for empty; p95 = nearest-rank
public enum Outcome: Codable, Sendable, Equatable { case measured(Summary, failures: [String]), notApplicable(String), notMeasured(String) }
public struct Environment: Codable, Sendable, Equatable { public var date: String; public var machine: String; public var macOS: String; public var refreshHz: Double; public var scale: Double; public var onBattery: Bool; public var cold: Bool }
public struct RunResult: Codable, Sendable, Equatable { public var environment: Environment; public var apps: [String: String] /* id → version */; public var outcomes: [String: [Metric: Outcome]] /* app id → metric */ }
public enum Report { public static func markdown(_ r: RunResult) -> String; public static func fileStem(_ r: RunResult) -> String }  // "2026-11-08-Mac16,1"
```

- [ ] **Step 1: Write the failing tests:**
  - `medianOddEven`: `[3,1,2]` → median 2; `[1,2,3,4]` → median 2.5.
  - `p95NearestRank`: the samples `1...100` → p95 is 95.
  - `emptyIsNil`.
  - `resultsRoundTripJSON`: a `RunResult` with all three outcome kinds survives encode/decode unchanged.
  - `markdownTableHasOneRowPerMetricAndColumnPerApp`: the table header is `| Metric | Zed | Delta | Alloy |`; an `.notApplicable("x")` cell renders as `n/a (x)`; a measured cell renders as `12.3 ms (p95 15.0)`.
  - `markdownFlagsAlloySlowerThanZed`: when Alloy's median is worse than Zed's for a metric, that row ends with `⚠ behind Zed`. Lower is better for every metric in this plan.
- [ ] **Step 2: Run the tests to confirm they fail.**
  Run: `swift test --package-path Bench --filter 'StatsTests|ResultsTests'`
  Expected: compile failure.
- [ ] **Step 3: Implement** to the interfaces above.
- [ ] **Step 4: Run the tests to confirm they pass.**
  Run: `swift test --package-path Bench --filter 'StatsTests|ResultsTests'`
  Expected: all pass.
- [ ] **Step 5: Commit** with message `feat(bench): stats, results schema and markdown report`.

### Task 3: Frame-change detection

**Files:**
- Create: `Bench/Sources/BenchCore/FrameDiff.swift`
- Test: `Bench/Tests/BenchCoreTests/FrameDiffTests.swift`

**Interfaces:**
- Produces:
```swift
public struct PixelRect: Equatable, Sendable { public var x, y, width, height: Int }
public enum FrameDiff {
  public static func changedBounds(_ a: CGImage, _ b: CGImage, in region: PixelRect?, threshold: UInt8 = 16) -> PixelRect?  // per-channel abs diff > threshold
  public static func isContentChange(_ bounds: PixelRect?, caretMaxWidth: Int = 4) -> Bool                                  // false for nil or width ≤ caretMaxWidth
  public static func isBlank(_ image: CGImage) -> Bool                                                                     // all pixels within threshold of the first pixel
}
```

- [ ] **Step 1: Write the failing tests** using synthetic 200×100 RGBA `CGImage`s built in the test:
  - `identicalIsNil`.
  - `singleGlyphChangeIsContent`: an 8×12 block changed → bounds equal that rect, and `isContentChange` is true.
  - `caretBlinkIsNotContent` (Review Focus 4): a 2×16 column toggled → bounds non-nil, and `isContentChange` is false.
  - `regionLimitsSearch`: a change outside `region` → nil.
  - `belowThresholdIgnored`: a change of 10 in each channel → nil.
  - `blankDetection`: a uniform image → `isBlank` is true; a single differing pixel → false.
- [ ] **Step 2: Run the tests to confirm they fail.**
  Run: `swift test --package-path Bench --filter FrameDiffTests`
  Expected: compile failure.
- [ ] **Step 3: Implement.** Render both images into BGRA8 buffers once and scan rows; no Core Image.
- [ ] **Step 4: Run the tests to confirm they pass.**
  Run: `swift test --package-path Bench --filter FrameDiffTests`
  Expected: all pass.
- [ ] **Step 5: Commit** with message `feat(bench): frame-change detection with caret filtering`.

### Task 4: Process-tree memory and CPU

**Files:**
- Create: `Bench/Sources/BenchCore/ProcessTree.swift`
- Test: `Bench/Tests/BenchCoreTests/ProcessTreeTests.swift`

**Interfaces:**
- Produces:
```swift
public struct TreeSample: Sendable, Equatable { public var pids: [pid_t]; public var physFootprintBytes: UInt64; public var cpuNanoseconds: UInt64 }
public enum ProcessTree {
  public static func descendants(of pid: pid_t) -> [pid_t]          // recursive via proc_listchildpids, includes pid
  public static func sample(root pid: pid_t) -> TreeSample            // sums ri_phys_footprint and ri_user_time+ri_system_time (converted with mach_timebase_info)
  public static func cpuPercent(_ a: TreeSample, _ b: TreeSample, wallNanoseconds: UInt64) -> Double
}
```

- [ ] **Step 1: Write the failing tests.** They spawn their own children with `Process` and terminate them by PID in `defer`.
  - `descendantsIncludesGrandchildren`: `/bin/sh -c '/bin/sleep 30 & /bin/sleep 30 & wait'` → `descendants` contains the shell and both sleeps.
  - `footprintGrowsWithAllocation`: a child `python3 -I -c "b=bytearray(200*1024*1024); import time; time.sleep(30)"` has `physFootprintBytes` ≥ 150 MB after it signals readiness (it prints `ready`; wait for that line).
  - `cpuPercentOfBusyChild`: a `/bin/sh -c 'while :; do :; done'` child sampled 1 s apart → between 50 and 150.
- [ ] **Step 2: Run the tests to confirm they fail.**
  Run: `swift test --package-path Bench --filter ProcessTreeTests`
  Expected: compile failure.
- [ ] **Step 3: Implement** with `proc_listchildpids` and `proc_pid_rusage(pid, RUSAGE_INFO_V4, …)`.
- [ ] **Step 4: Run the tests to confirm they pass.**
  Run: `swift test --package-path Bench --filter ProcessTreeTests`
  Expected: all pass.
- [ ] **Step 5: Commit** with message `feat(bench): process-tree footprint and CPU sampling`.

### Task 5: OS drivers — launch, window, capture, input

**Files:**
- Create: `Bench/Sources/BenchDrivers/{Launcher,Windows,Capture,Input}.swift`
- Test: `Bench/Tests/BenchCoreTests/DriversLiveTests.swift` (all gated on `BENCH_LIVE=1`)

**Interfaces:**
- Consumes: `TargetApp`, `FrameDiff`, `ProcessTree`.
- Produces:
```swift
public struct LaunchedApp: Sendable { public let pid: pid_t; public let launchedAt: UInt64 /* mach_absolute_time */ }
public enum Launcher {
  public static func runningInstance(of app: TargetApp) -> pid_t?                    // by bundle id / executable path
  public static func launch(_ app: TargetApp, file: String?) throws -> LaunchedApp     // Process for executables, `open -n -a` avoided: exec the bundle's binary directly
  public static func terminate(_ launched: LaunchedApp) async                          // SIGTERM tree, SIGKILL after 5 s; only these pids
}
public enum Windows { public static func waitForMainWindow(pid: pid_t, timeout: Duration) async throws -> (windowID: CGWindowID, frame: CGRect) }  // layer 0, on-screen, ≥ 200×200
public actor WindowCapture {                                                           // SCStream on one window, frames delivered with mach host-time timestamps
  public init(windowID: CGWindowID, fps: Int)
  public func start() async throws; public func stop() async
  public func frames() -> AsyncStream<(hostTime: UInt64, image: CGImage)>
}
public enum Input {
  public static func activate(pid: pid_t) async
  public static func typeKey(_ char: Character, to pid: pid_t) -> UInt64                // posts keyDown/keyUp, returns post host time
  public static func scroll(lines: Int32, to pid: pid_t) -> UInt64
}
public enum Permissions { public static func missing() -> [String] }                  // ["Screen Recording", "Accessibility"] subset with System Settings paths
```

- [ ] **Step 1: Write the failing live tests,** run against TextEdit as a neutral app:
  - `launchFindsWindowAndCaptures`: launch TextEdit with a new temp `.txt` → `waitForMainWindow` returns within 10 s, and the capture yields ≥ 10 non-blank frames in 1 s.
  - `typingChangesFrame`: `typeKey("x")` → a frame with `isContentChange` arrives within 500 ms.
  - `timeoutWhenNoWindow` (Review Focus 5): `waitForMainWindow` on `/bin/sleep 60`'s pid throws a timeout after 2 s.
  - `terminateOnlyOwnTree`: after `terminate`, `ProcessTree.descendants(of:)` of the launched pid is empty, and an unrelated `sleep` started by the test is still alive.
- [ ] **Step 2: Run them to confirm they fail.**
  Run: `BENCH_LIVE=1 swift test --package-path Bench --filter DriversLiveTests`
  Expected: compile failure. Without `BENCH_LIVE`, the tests are skipped.
- [ ] **Step 3: Implement.** Set the `SCStreamConfiguration` `minimumFrameInterval` to the display refresh rate and `queueDepth` to 8; convert `CMSampleBuffer` presentation timestamps to host time. Post `CGEvent`s with `postToPid`.
- [ ] **Step 4: Run them to confirm they pass.** Grant the permissions first if prompted.
  Run: `BENCH_LIVE=1 swift test --package-path Bench --filter DriversLiveTests`
  Expected: all pass.
- [ ] **Step 5: Commit** with message `feat(bench): launch, window lookup, ScreenCaptureKit capture, CGEvent input`.

### Task 6: Scenarios and the `alloy-bench` command

**Files:**
- Create: `Bench/Sources/BenchScenarios/*.swift`, `Bench/Sources/alloy-bench/main.swift`, `Bench/Corpus/generate.swift`, `Bench/Corpus/{small,medium,large}.swift`, `Bench/Corpus/MANIFEST.sha256`
- Test: `Bench/Tests/BenchCoreTests/ScenarioPlanTests.swift`

**Interfaces:**
- Consumes: all of the above.
- Produces:
```swift
public protocol Scenario: Sendable { var metric: Metric { get }; func run(_ app: TargetApp, corpus: Corpus, runs: Int) async -> Outcome }
public struct Corpus: Sendable { public var small, medium, large: String /* absolute paths */ }
public enum Runner { public static func plan(apps: [TargetApp], metrics: [Metric]) -> [(TargetApp, Metric, applicable: Outcome?)]   // pre-fills .notApplicable
                     public static func run(apps: [TargetApp], metrics: [Metric], corpus: Corpus, runsOverride: Int?) async throws -> RunResult }
```
- Command line: `alloy-bench [--apps zed,delta,alloy] [--metrics …] [--runs N] [--cold] [--alloy-build <dir>] [--out Bench/results]`.
- Scenario definitions (each run launches fresh, measures, and terminates):
  - **startup:** from launch host time to the first non-blank captured frame of the main window. Warm by default; `--cold` runs `sudo -n purge` first.
  - **largeFileOpen:** launch with `large.swift`; time until a frame whose content change covers ≥ 30 % of the window height after the first non-blank frame. Stop as soon as text is painted.
  - **typingLatency:** open `small.swift`, put the caret at the end, and type 200 characters (letters, 150 ms apart); each sample is from the post time to the first content-change frame.
  - **scrollFrames:** open `large.swift`, post scroll events of 3 lines every 8 ms for 3 s, and record the intervals between consecutive frames that changed. Report the frame-interval median and p95, with the dropped-frame percentage (intervals > 1.5 × refresh period) recorded in `failures` as a note.
  - **memory:** `ProcessTree.sample` 10 s after `large.swift` is visible.
  - **idleCPU:** after 10 s settle with `small.swift` open, CPU % over 30 s.
- The corpus is a deterministic generator (a seeded LCG): `small` 200 lines, `medium` 5 000, `large` 100 000 lines of syntactically valid Swift. The files and the SHA-256 manifest are committed; `generate.swift --verify` checks them.
- Before anything launches:
  - If any target app already has a `runningInstance`, exit 2 with "Zed is already running (pid N). Quit it first; alloy-bench never touches apps it didn't launch." (Review Focus 1).
  - If `Permissions.missing()` is non-empty, exit 3 with the list and System Settings paths (Review Focus 2).

- [ ] **Step 1: Write the failing tests:**
  - `planMarksUnsupportedAsNA`: `plan([alloy], [.typingLatency])` pre-fills `.notApplicable` containing "Plan 4" (Review Focus 3).
  - `corpusManifestMatches`: hashing the committed corpus files matches `MANIFEST.sha256`.
  - `largeCorpusIs100kLines`.
- [ ] **Step 2: Run them to confirm they fail.**
  Run: `swift test --package-path Bench --filter ScenarioPlanTests`
  Expected: compile failure.
- [ ] **Step 3: Implement** the scenarios, `Runner`, the command line and the corpus generator. Write `results/<stem>.json` and `results/<stem>.md` through `Report`.
- [ ] **Step 4: Run the tests to confirm they pass.**
  Run: `swift test --package-path Bench`
  Expected: all non-live tests pass.
- [ ] **Step 5: First real run.** Quit Zed and Delta first, and only if the user has said it's OK to quit them; ask before quitting anything. Use the AC power and display refresh as found, recorded in the result.
  Run: `swift run --package-path Bench -c release alloy-bench --apps zed,delta`
  Expected: `results/<date>-<machine>.{json,md}` exist, every cell is measured or a stated n/a, and no target process launched by the harness is left running (`ProcessTree` check at exit).
- [ ] **Step 6: Commit** the harness, corpus and first results with message `feat(bench): scenarios, alloy-bench CLI, corpus, first Zed/Delta baseline`.
- [ ] **Step 7: Alloy checkpoint.** Once Plan 1 Task 12 is merged, run `swift build -c release` in `Alloy/`, then `alloy-bench --apps zed,alloy --metrics startup,largeFileOpen,scrollFrames,memory,idleCPU`. Commit the results. Any metric flagged `⚠ behind Zed` is listed in the task report for triage (roadmap Plan 6).
