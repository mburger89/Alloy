# Benchmark: more editors (VS Code, Cursor, Sublime Text, IntelliJ IDEA)

Status: approved 2026-11-18. Short design (small change to the existing `alloy-bench` harness).

## Intent
Broaden the comparison data: race Alloy against the editors people actually use, not only Zed and Delta.
Same measures as today, more editors. No new kinds of measurement.

## Goals
- Add four targets to `Bench/Sources/BenchCore/Targets.swift`, each a `TargetApp` like `zed` and `delta`:
  VS Code, Cursor, Sublime Text, IntelliJ IDEA (the free edition, Homebrew cask `intellij-idea`).
- Each adapter defines: the app and real executable (read `CFBundleExecutable`, never a CLI shim that forks),
  bundle id, how to open one file, a per-run throwaway profile, seeded files that skip first-run screens, the
  typing click point if the editor does not open focused, and caveats printed next to its numbers.
- `--apps` accepts the new ids (`vscode`, `cursor`, `sublime`, `idea`); the running-instance refusal (exit 2)
  covers them by bundle id and executable path.
- The /benchmarks page lists every measured editor. The landing page race stays Alloy vs Zed.

## Per-editor decisions
| Editor | Throwaway profile | First-run screens skipped | Caveats |
|---|---|---|---|
| VS Code | `--user-data-dir <tmp>` + `--extensions-dir <tmp>`, `--disable-extensions` | `--skip-welcome --skip-release-notes --disable-workspace-trust`; seeded `User/settings.json`: telemetry off, update mode none, startup editor none, cursor blinking solid | none expected |
| Cursor | same flags as VS Code (same Electron base) | same as VS Code | a fresh profile may show login/onboarding; if no flag or seeded state skips it, the affected metrics are `n/a: <reason>` |
| Sublime Text | `--safe-mode` (separate data folder, no packages) | update check off where safe mode allows | safe mode ignores user settings, so the caret may blink (the harness already ignores diffs ≤ 4 px wide) |
| IntelliJ IDEA | `IDEA_PROPERTIES` env → a per-run properties file setting `idea.config.path`, `idea.system.path`, `idea.plugins.path`, `idea.log.path` under the temp dir | seeded config skipping licence/terms, data sharing, import settings, project trust, tip of the day | post-open indexing inflates startup and memory; stated in its caveats |

## Constraints
- Existing fairness rules are unchanged: a metric that cannot be fair is `n/a: <reason>`; any disturbed run makes
  the metric `not measured`; nothing measured under a trace is published. Never edit a user's real editor settings.
- The harness never kills an app it did not launch.
- Unit tests cover each adapter's arguments, environment, seeded files and refusal matching without launching anything.
- Live verification (BENCH_LIVE=1 probe: each editor opens straight into the file in its throwaway profile) is done
  by the orchestrator with the user's go-ahead, because it takes over the screen; an adapter whose first-run screen
  cannot be skipped records the reason instead of a workaround that clicks through UI.

## Approaches
1. **Per-editor `TargetApp` adapters (chosen).** Follows the existing pattern; each editor's quirks live in code with tests.
2. Config-file editor descriptions. Rejected: the quirks (env-var profiles, seeded files, shims) need code anyway.

## Left to the builder
Exact seeded-file contents and flag spellings, verified against each installed app's `--help` and Info.plist.
