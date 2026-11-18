# alloy-bench

Benchmark harness comparing Zed, Delta, Alloy and the optional editors VS Code, Cursor, Sublime Text and IntelliJ IDEA (spec section 6.6; ids `zed`, `delta`, `alloy`, `vscode`, `cursor`, `sublime`, `idea`). Separate SwiftPM package, no MetalUI dependency.
Run tests: `swift test --package-path Bench`.

## Capability survey (read-only: `--help`, Info.plist, docs; no GUI launched)

| | Zed 1.27.0 | Delta 0.1.0 | Alloy | VS Code 1.147.0 | Cursor 3.30.14 | Sublime Text Build 4215 | IntelliJ IDEA 2026.3 |
|---|---|---|---|---|---|---|---|
| App binary | `/Applications/Zed.app/Contents/MacOS/zed` (CLI shim: `/opt/homebrew/bin/zed`) | `/Applications/Delta.app/Contents/MacOS/delta-app` (CLI: `.../delta`) | `<Alloy repo>/.build/release/Alloy` | `/Applications/Visual Studio Code.app/Contents/MacOS/Code` (read from Info.plist; bundle id `com.microsoft.VSCode`) | `/Applications/Cursor.app/Contents/MacOS/Cursor` (bundle id `com.todesktop.230313mzl4w4u92`) | `/Applications/Sublime Text.app/Contents/MacOS/sublime_text` (bundle id `com.sublimetext.4`) | `/Applications/IntelliJ IDEA.app/Contents/MacOS/idea` (bundle id `com.jetbrains.intellij`) |
| Open with a file | `zed <file>` (also `path:line:col`). The harness launches the app binary, which takes `paths_or_urls` and `--user-data-dir` but not the CLI shim's `-n` | `delta open <PATH_OR_URL>` (path or `delta://` link; activates app); URL scheme `delta://` registered. No documented flag to open a file in an editor view | `Alloy <project-dir> [<file>]` | `Code <file>` plus `--disable-extensions --skip-welcome --skip-release-notes --disable-workspace-trust`; flags checked against the bundled `bin/code --help`. Open: whether typing needs a focus click | Same flags as VS Code (same Electron base). Open: first-run login or onboarding that no flag skips | `sublime_text --safe-mode <file>`; `--safe-mode` read from `--help`. Open: nothing known | `idea <file>`; the GUI binary's `--help` was not run. Open: pid after launch (the launcher may hand off to another process) |
| Isolated profile | Yes: `--user-data-dir <DIR>` | None found in `delta --help` (only `--json`, `--debug`) | n/a (no persistent profile) | Yes: `--user-data-dir <DIR>` and `--extensions-dir <DIR>/extensions`, with a seeded `User/settings.json` | Same as VS Code | Safe mode uses its own sandboxed data folder, not cleaned by the harness. Open: whether it persists state outside the run | Yes: `IDEA_PROPERTIES` points at a per-run `idea.properties` (config, system, plugins and log paths) plus seeded `config/options/ide.general.xml`. Open: licence and data-sharing consent live outside the profile, so a first-run dialog may remain |
| Disable cursor blink w/o touching user settings | Not via CLI. Setting `cursor_blink` lives in settings.json, which the harness must not edit. With `--user-data-dir` a temp profile could carry its own settings.json (config dir is separate from data dir, so unconfirmed); otherwise record as a caveat. Harness additionally ignores diffs in regions <= 4 px wide | No setting/flag found; record as caveat | No blink in Plan 1 | Seeded per-run `editor.cursorBlinking: solid` (read from the settings schema, unverified live) | Same as VS Code | Safe mode ignores user settings, so the caret may blink; recorded as a caveat | Not handled; the harness ignores diffs in regions <= 4 px wide |

Note: `zed` CLI forks the real app and exits; the harness launches the app binary directly so the tracked PID is the app.

## Unsupported metrics (recorded as `n/a: <reason>`)

- Alloy: all metrics supported. Typing is measured through the file panel's `CodeView`: the harness clicks once at the file panel centre (the same point scrolling uses, below the tab strip) to focus it, then runs the same keystroke script as Zed.
- Delta / typingLatency: agent-first app, no documented way to open a file into an editor surface; unverified.
- Delta / largeFileOpen: `delta open` takes a path or delta:// link only; no editor-open semantics documented.
- Delta / scrollFrames and memory: Delta opens projects, not files; needs a live probe to learn what it displays.
- Zed: all metrics supported.
- VS Code, Cursor, Sublime Text, IntelliJ IDEA: no metric is marked unsupported; nothing is known impossible without a live probe. Open questions for the live probe: VS Code and Cursor typing focus (whether a click is needed), Cursor first-run login, Sublime safe-mode data folder persistence, IntelliJ consent state outside the profile and its pid after launch. A metric the probe shows to be impossible becomes `n/a: <reason>` then.
- Live probe (2026-11-18): a fresh Cursor profile stops at a mandatory Log In / Sign Up screen, so Cursor runs against the user's own logged-in profile (extensions disabled). Sublime Text's `--safe-mode` opens a modal "Safe Mode" notice that swallows keystrokes and scrolling, so Sublime runs against its own profile. IntelliJ IDEA shows the JetBrains User Agreement on first launch; the user accepts it once by hand (the harness never accepts agreements). Delta was blocked by a macOS "access files on a removable volume" prompt, which the user answers once.

Revisit the Delta entries when a live (BENCH_LIVE=1) probe is possible.

## Measurement notes

- **Warm-up launch.** Warm `startup` runs begin with one untimed launch of each app, so first-launch system work
  (for example the code-signature check of a freshly built or installed binary) is never timed. It applies to every app
  alike and is noted in each startup result. `--cold` purges instead and has no warm-up.

- **Use a static desktop.** `startup` and `largeFileOpen` capture the whole main display from before the launch and
  look for the app window's region to change. Anything else that changes on screen before the window exists (video,
  notifications, animated wallpaper, another app) invalidates the run ("screen region changed before window existed").
  Any excluded run makes the whole metric `not measured`; a median of survivors is never published.
- Keep the screen awake, the machine on AC power, and the target window's future position free of other windows.
- `scrollFrames` posts scroll events to the window centre through the session event tap, so the harness aborts the run
  if the launched app is not frontmost or another window covers that point.
- The "window on screen" time recorded in the notes comes from polling CGWindowList every 5 ms. It lags the compositor by
  a few to tens of ms and is context only, not a metric.

## Running a benchmark

Run it only on a quiet machine: nothing else may be using the screen, keyboard or mouse.

1. **Permissions.** Grant the terminal (the app that launches `swift run`) Screen Recording and Accessibility in
   System Settings > Privacy & Security, then restart the terminal. The harness checks both and exits with exact
   instructions (exit code 3) before launching anything.
2. **Quit every selected editor first.** The harness refuses (exit code 2) when one is running, matched by bundle id
   (`dev.zed.Zed`, `com.zed-industries.delta`, `com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92`, `com.sublimetext.4`,
   `com.jetbrains.intellij`) and by executable path (`zed`, `delta-app`, `Code`, `Cursor`, `sublime_text`, `idea`), and names the main app pid. It re-checks before
   each app's block of metrics. It never kills an app it did not launch.
3. **Keep the target area clear.** Before each app's block the harness refuses (exit code 4) when any other app's
   normal window (layer 0, the terminal running the harness included) covers more than 10 % of the central 60 % x 60 %
   of the main display, where target windows open. The message names the owning app: move or minimize it (the harness
   never moves other apps' windows). A paint failure ("not painted", "no frame change", "fewer than 2 changed frames")
   re-runs the check and appends "covered by <app>" to its reason. Results measured before the refusal are still written.
   Other exit codes: 2 an instance is already running, 3 missing permissions, 5 target executable not found.
4. **Command** (from the repository root):

   ```
   swift run --package-path Bench -c release alloy-bench --apps zed,delta
   swift run --package-path Bench -c release alloy-bench --apps zed,delta,alloy --alloy-build <Alloy repo root>
   swift run --package-path Bench -c release alloy-bench --apps vscode,cursor,sublime,idea
   ```

   `--alloy-build` points at the Alloy repo root (build it first with `swift build -c release`; the binary is
   `<root>/.build/release/Alloy`). Other flags: `--metrics a,b`, `--runs N`, `--cold` (needs passwordless `sudo -n purge`),
   `--attribute` (launches Alloy, only Alloy, with `ALLOY_FRAME_TIMING=1` and appends its internal per-input-kind frame
   phases, medians of queue / build / encode / input-to-present, to Alloy's metric notes; attribution only, it never
   feeds a verdict, and a missing or unreadable `frame-timing.json` just means no extra notes), `--out DIR`.
   `--trace <time|allocations|hitches|gpu|concurrency>` attaches `xctrace` to the first run of each (app, metric) and
   saves `Bench/traces/<result stem>/<app>-<metric>.trace` (git-ignored). It needs Developer Tools access
   (`sudo DevToolsSecurity -enable`, once); the attach happens after launch, so launch work is missing from the trace;
   a failed attach becomes a note and never fails the run. Traced runs include profiler overhead and `publish` refuses them.
   `startup` and `largeFileOpen` are not traceable (they measure the launch itself, which happens before the attach);
   they get a note instead. Zed was not seen to refuse the Allocations attach; it needs the same authorization as any other app (see "Memory allocations: use Instruments" below). A failed attach is noted as "trace unavailable".
   Without Developer Tools access `--trace` exits with code 2 before launching anything.
   Summarise a recorded trace with `swift run --package-path Bench -c release alloy-bench hotspots <file>.trace [--top 25]`:
   for `time` traces the top functions by self samples and by total samples, for `allocations` traces the top
   responsible callers by bytes still live and by total bytes. Other kinds list the trace's tables and point at
   Instruments. An empty allocations table prints "no rows in <table>"; a time profile with no samples prints "no samples in
   time-profile: the app was not on the CPU while recording (an idle app records nothing)" and still exits 0.
   `--out` and the trace directory default to `Bench/results` and `Bench/traces` of the enclosing repo, wherever you run from.

   **Memory allocations: use Instruments.** `--trace allocations` is not supported in practice: xctrace waits for macOS to
   authorize inspecting the app and, when started by the harness, never gets it (the harness gives up after 120 s and notes
   the trace as unavailable). Record allocations in Instruments instead: open Instruments, choose the Allocations template,
   pick the app as the target (for Alloy, `.build/release/Alloy` with a file argument), record, and save the `.trace`.
   `alloy-bench hotspots` can try to summarise a saved Allocations trace, but its Allocations reader has not yet been
   checked against a real recording. `--trace time` (Time Profiler) needs no authorization and works from any session.
   For Alloy alone there is a password-free alternative: launch it with `MallocStackLogging=1` (and `ALLOY_DATA_DIR` set to a
   scratch folder), then run `heap <pid>` (live objects by type), `vmmap --summary <pid>` (footprint by region and malloc
   fragmentation) and `malloc_history <pid> -allBySize` (allocation call stacks; its largest entries are virtual
   reservations, not resident memory). Stack logging adds its own memory, so compare footprints with it off.

5. **Where results go.** `Bench/results/<YYYY-MM-DD>-<HHMMSS>-<machine>.json` (schema version 1: summaries, raw samples,
   notes, failures, requested vs completed runs per metric, harness git SHA, environment incl. thermal state) and a
   matching `.md` report with a Note column and a Notes section.
6. **While it runs.** Do not touch the keyboard or mouse (the harness injects input). Turn on Do Not Disturb. Keep the
   terminal away from where app windows open: activating an app dims the previous frontmost window and invalidates
   runs. Use a single display: capture is main-display only. Keep the screen awake and the Mac on AC power.
7. **Approximate run time.** About 25 minutes for zed and delta together: startup 10 launches, typing one launch
   (~30 s), scroll 5 x ~15 s, memory 5 x ~25 s, memoryIdle + idleCPU 3 x ~45 s, largeFileOpen 10 launches, per app. Each of vscode, cursor, sublime and idea adds roughly another 10 to 12 minutes (IntelliJ more, with indexing).

### What each app is given to open

Each run copies the scenario's corpus file (`Bench/Corpus/small.rs` or `large.rs`) into a fresh temporary directory
that holds only that file, and opens the copy; `Bench/Corpus` itself is never opened, so the committed corpus cannot
be modified.

- Zed: the file, plus `--user-data-dir <fresh temp dir per run>` (an isolated profile; Zed's own settings are not touched).
- Alloy: `<directory> <file>`.
- Delta: the directory (it opens projects, not files), which contains only that file.
- VS Code, Cursor, Sublime Text, IntelliJ IDEA: the file, plus the per-run profile below.

### Per-run profiles

Each editor gets a fresh temporary profile per run; no real profile under the user's library is read or edited.

- VS Code and Cursor: `--user-data-dir <profile>` and `--extensions-dir <profile>/extensions`, with `--disable-extensions`, and a seeded `User/settings.json` (telemetry off, no updates, no startup editor, solid cursor).
- Sublime Text: the file only; no profile directory (its own profile, see the live-probe note above).
- Cursor: the VS Code flags without `--user-data-dir`/`--extensions-dir` (its own logged-in profile).
- IntelliJ IDEA: `IDEA_PROPERTIES` names a per-run `idea.properties` whose config, system, plugins and log paths sit in the profile, plus a seeded `config/options/ide.general.xml`.

The landing page race stays Alloy vs Zed; the /benchmarks page lists every measured editor.

### Survivor policy

- typingLatency, scrollFrames, memory, memoryIdle and idleCPU publish the median and p95 of the surviving runs plus the
  list of failures (shown as "N failed").
- startup and largeFileOpen are strict: any excluded run (window never appeared, screen changed before the window,
  capture dropped frames) makes the whole metric `not measured`; a median of survivors is never published.
- `memoryIdle` is the process-tree footprint at the end of the idleCPU window with small.rs open, from the same launches.

### Delta isolation caveat

Delta has no isolation flag (`--user-data-dir` equivalent), so it runs against the user's real Delta profile and state.
This caveat is recorded in the notes of every Delta result.

### Leftovers

At exit the harness lists, and only reports, any process matching a target app that started after the harness did
(stderr warning, and in the result's `notes`). It never kills them.

## Publishing

1. `swift run --package-path Bench alloy-bench run` and check the generated `.md` report.
2. `swift run --package-path Bench alloy-bench publish <result.json>` scrubs the result and adds it to `Bench/published`
   (partial runs are refused unless `--allow-partial`).
3. `swift run --package-path Bench alloy-bench site` renders the landing page `Bench/site/index.html` (served at the Pages
   root), the results page `Bench/site/benchmarks/index.html` (served at `/benchmarks/`), and copies each published JSON
   to `Bench/site/data/`. Screenshots, the hero video and its poster live in `Bench/site/assets/`; the landing page uses
   whichever of them exist. The pages are static: inline CSS and SVG, no JavaScript, no external resources. An existing
   `Bench/site/appcast.xml` (written by the release script) is left alone.
   To combine two runs (say a second run that re-measured apps whose adapters were fixed) into one result before step 2:
   `swift run --package-path Bench alloy-bench merge <base.json> <override.json> [--apps a,b,...] --drop-first-startup --out <merged.json>`.
   Every app in `--apps` (default: every app in the override) takes all its outcomes, run counts and version from the
   override; the other apps keep the base's. Both runs must share machine model, macOS, display refresh/scale and power
   source (and warm/cold), otherwise merge refuses; attributed and traced runs are refused too. The later run's date and
   time are kept, and result-level notes record the merge (and a differing harness SHA). `--drop-first-startup` removes
   the first startup sample of every app's measured `startup` outcome, recomputes its summary and adds a note. It is the
   retroactive equivalent of the warm-up launch (see "Measurement notes") and applies to every app alike, never to a
   startup outcome that already has a warm-up launch. No other metric is touched. The merged file is an ordinary result:
   pass it to `publish`.
4. Commit `Bench/published` and `Bench/site`. `SitePageTests.committedSiteIsCurrent` fails when either page is stale.

The page is hosted on GitHub Pages from the public repository: `.github/workflows/pages.yml` deploys `Bench/site` when
it changes on `main` (or on a manual run), with no build step. It runs only in the public repository, whose Pages source
must be set to "GitHub Actions" in its settings.

## Corpus

The corpus files are generated by a script rather than taken from a real project (a deviation from spec section 6.6
that the plan chose deliberately); `Bench/Corpus/MANIFEST.sha256` pins their hashes.
