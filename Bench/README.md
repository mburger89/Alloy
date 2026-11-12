# alloy-bench

Benchmark harness comparing Zed, Delta and Alloy (spec section 6.6). Separate SwiftPM package, no MetalUI dependency.
Run tests: `swift test --package-path Bench`.

## Capability survey (read-only: `--help`, Info.plist, docs; no GUI launched)

| | Zed 1.27.0 | Delta 0.1.0 | Alloy |
|---|---|---|---|
| App binary | `/Applications/Zed.app/Contents/MacOS/zed` (CLI shim: `/opt/homebrew/bin/zed`) | `/Applications/Delta.app/Contents/MacOS/delta-app` (CLI: `.../delta`) | `<Alloy repo>/.build/release/Alloy` |
| Open with a file | `zed <file>` (also `path:line:col`). The harness launches the app binary, which takes `paths_or_urls` and `--user-data-dir` but not the CLI shim's `-n` | `delta open <PATH_OR_URL>` (path or `delta://` link; activates app); URL scheme `delta://` registered. No documented flag to open a file in an editor view | `Alloy <project-dir> [<file>]` |
| Isolated profile | Yes: `--user-data-dir <DIR>` | None found in `delta --help` (only `--json`, `--debug`) | n/a (no persistent profile) |
| Disable cursor blink w/o touching user settings | Not via CLI. Setting `cursor_blink` lives in settings.json, which the harness must not edit. With `--user-data-dir` a temp profile could carry its own settings.json (config dir is separate from data dir, so unconfirmed); otherwise record as a caveat. Harness additionally ignores diffs in regions <= 4 px wide | No setting/flag found; record as caveat | No blink in Plan 1 |

Note: `zed` CLI forks the real app and exits; the harness launches the app binary directly so the tracked PID is the app.

## Unsupported metrics (recorded as `n/a: <reason>`)

- Alloy: all metrics supported. Typing is measured through the file panel's `CodeView`: the harness clicks once at the file panel centre (the same point scrolling uses, below the tab strip) to focus it, then runs the same keystroke script as Zed.
- Delta / typingLatency: agent-first app, no documented way to open a file into an editor surface; unverified.
- Delta / largeFileOpen: `delta open` takes a path or delta:// link only; no editor-open semantics documented.
- Delta / scrollFrames and memory: Delta opens projects, not files; needs a live probe to learn what it displays.
- Zed: all metrics supported.

Revisit the Delta entries when a live (BENCH_LIVE=1) probe is possible.

## Measurement notes

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
2. **Quit Zed and Delta first.** The harness refuses (exit code 2) when either is running, matched by bundle id
   (`dev.zed.Zed`, `com.zed-industries.delta`) and by executable path, and names the main app pid. It re-checks before
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
   they get a note instead. Zed's hardened runtime is expected to refuse the Allocations attach; the run note then says "trace unavailable".
   Without Developer Tools access `--trace` exits with code 2 before launching anything.
   Summarise a recorded trace with `swift run --package-path Bench -c release alloy-bench hotspots <file>.trace [--top 25]`:
   for `time` traces the top functions by self samples and by total samples, for `allocations` traces the top
   responsible callers by bytes still live and by total bytes. Other kinds list the trace's tables and point at
   Instruments. An empty table prints "no rows in <table>".
5. **Where results go.** `Bench/results/<YYYY-MM-DD>-<HHMMSS>-<machine>.json` (schema version 1: summaries, raw samples,
   notes, failures, requested vs completed runs per metric, harness git SHA, environment incl. thermal state) and a
   matching `.md` report with a Note column and a Notes section.
6. **While it runs.** Do not touch the keyboard or mouse (the harness injects input). Turn on Do Not Disturb. Keep the
   terminal away from where app windows open: activating an app dims the previous frontmost window and invalidates
   runs. Use a single display: capture is main-display only. Keep the screen awake and the Mac on AC power.
7. **Approximate run time.** About 25 minutes for zed and delta together: startup 10 launches, typing one launch
   (~30 s), scroll 5 x ~15 s, memory 5 x ~25 s, memoryIdle + idleCPU 3 x ~45 s, largeFileOpen 10 launches, per app.

### What each app is given to open

Each run copies the scenario's corpus file (`Bench/Corpus/small.rs` or `large.rs`) into a fresh temporary directory
that holds only that file, and opens the copy; `Bench/Corpus` itself is never opened, so the committed corpus cannot
be modified.

- Zed: the file, plus `--user-data-dir <fresh temp dir per run>` (an isolated profile; Zed's own settings are not touched).
- Alloy: `<directory> <file>`.
- Delta: the directory (it opens projects, not files), which contains only that file.

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
3. `swift run --package-path Bench alloy-bench site` renders `Bench/site/index.html` and copies each published JSON to
   `Bench/site/data/`. The page is static: inline CSS and SVG, no JavaScript, no external resources.
4. Commit `Bench/published` and `Bench/site`. `SitePageTests.committedSiteIsCurrent` fails when the page is stale.

The page is hosted on GitHub Pages from the public repository: `.github/workflows/pages.yml` deploys `Bench/site` when
it changes on `main` (or on a manual run), with no build step. It runs only in the public repository, whose Pages source
must be set to "GitHub Actions" in its settings.

## Corpus

The corpus files are generated by a script rather than taken from a real project (a deviation from spec section 6.6
that the plan chose deliberately); `Bench/Corpus/MANIFEST.sha256` pins their hashes.
