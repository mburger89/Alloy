# Release readiness for 0.1.0

The user asked to fix the issues found before the first public release. A read-only audit on 2026-11-19 covered tests, the release pipeline, first launch, security and privacy, and docs and site. This spec lists what each of two branches fixes.

## Already fine (do not change)

- `scripts/release-macos.sh 0.1.0 --dry-run` passes: bundle, ad hoc sign, DMG, verify.
- No `try!` or `as!` in Sources, and no force unwrap reachable from user input.
- LocalServer binds 127.0.0.1, checks Host and Origin, requires a bearer token on every route, compares tokens in constant time, and bounds request sizes.
- Secrets are stored only in the Keychain. LICENSE is MIT.

## Track A: app, packaging and tests (branch `fix/release-app`)

1. **No Claude CLI.** Today, when `claude` is not found, the session just shows "Can't start". The error message, which lists the paths tried, is stored in `SessionStatus.failedToLaunch(message)`, but nothing shows it.
   - In `failLaunch`, always add an `.error` transcript notice that carries the message.
   - Claude sessions add the hint "Install Claude Code and run `claude` once to sign in, or set its path in Settings".
   - ACP sessions show their preset's install hint.
   - The chat column shows the message whenever the status is `.failedToLaunch`.
   - Sending a message on a failed session tries to launch it again.
2. **No Command Line Tools.** On a Mac without the Command Line Tools, running git or xcrun pops the macOS "install developer tools" dialog. Avoid that in two places:
   - `FileIndex` runs `/usr/bin/env git`. Use `GitExecutable.current` instead. Run git only when it reports `.usable(path:)`, run that path directly, and otherwise fall back to `walk()`.
   - The sourcekit-lsp lookup (`xcrun --find sourcekit-lsp`) must first check that a developer directory is selected (`xcode-select -p` succeeds, or `DEVELOPER_DIR` is set). Reuse GitExecutable's guard if possible.
3. **Corrupt settings.json.** When settings.json fails to decode, rename it to `settings.json.corrupt-<timestamp>` before any defaults are saved, and show a one-line notice. This matches how sessions and the ledger are already moved aside.
4. **Data permissions.** Create Alloy's support directory, including under `ALLOY_DATA_DIR`, with permissions 0700. The ACP history files stay 0600.
5. **Session token on the command line.** The per-session bearer token is currently passed inside the JSON given to `--mcp-config` and `--settings`, where other processes can read it with ps.
   - Write that JSON to files with permissions 0600, in a 0700 per-session directory inside the support directory.
   - Pass the file paths instead. The Claude CLI accepts a file for both flags. Check this with `claude --help`; if it doesn't, keep the current behaviour and report it.
   - Delete the files when the session ends and on launch, to clear leftovers.
   - The Claude launch is otherwise unchanged: same flags, same order. Only the JSON strings become paths.
6. **Sparkle.** `UpdateStartPolicy` accepts only the `https` scheme. Add a test for this. Confirm that Settings has a toggle for automatic update checks; if it doesn't, add one bound to Sparkle's `automaticallyChecksForUpdates`.
7. **Info.plist.** Add:
   - `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription` and `NSAppleEventsUsageDescription`. Each says in one plain line that Alloy opens and runs tools in the folders you choose.
   - `LSApplicationCategoryType` set to `public.app-category.developer-tools`.
   - `NSHumanReadableCopyright` set to "Copyright © 2026 Max Burger. MIT License." (the LICENSE holder's name).
8. **Third-party notices (release blocker).**
   - Add `THIRD-PARTY-NOTICES.md` at the repo root with the full licence texts for: Sparkle, SwiftTreeSitter, the tree-sitter runtime, every bundled grammar, and everything MetalUI ships or vendors (read ../MetalUI for its notices, vendored code, icon sets and fonts).
   - `bundle-macos.sh` copies LICENSE and the notices file into `Contents/Resources`.
   - Add an "Acknowledgements" entry to the app menu, next to About, that opens the bundled notices file.
9. **Build paths in the binary.** After copying the executable, `bundle-macos.sh` removes every LC_RPATH that starts with `/Applications`, `/Library/Developer`, `/var/run` or `/Users`.
10. **DMG.** Ship a Retina background with 1x and 2x representations (for example a 1200x800 image at 144 dpi, or a multi-representation TIFF), and set the volume icon from Alloy.icns.
11. **Tests that fail by design.** Make each deterministic, and never raise a limit:
    - `CommandPalettePerformanceTests.rankingTwoThousandCommandsIsQuick` fails every time in debug, at 208–211 ms against a 200 ms limit. Replace the wall-clock assertion with a deterministic work bound: a package-visible counter in FuzzyMatch of candidates scored and DP cells evaluated. Also assert the top results for each query. The timed figure stays in Bench. Optionally add a fast path that rejects a candidate without allocating `Array(cand.utf8)`.
    - `ViewSelectionTests.aJumpScrollsOnlyThatPanesView` uses `runUntil` with a 10 s deadline. Replace it with a frame-bounded settle (`settle(n)` or `runUntilIdle()`) followed by an `#expect`.
    - `ByteCopiesTests.readHoldsOneCopy`: copy the corpus file into a per-test temp directory so nothing else can touch it. Make the failure message say which check failed, including errno for read failures. Tighten the capacity check to "a single allocation" (capacity minus count is at most 16 KB + 1).

## Track B: docs and site (branch `docs/release-site`)

1. **Release notes.** Replace `docs/releases/0.1.0.md` with the reviewed draft, which the orchestrator passes in. Before keeping the following claims, check each against the code:
   - `/theme` works with any agent. The ACP design hides `/theme` for ACP agents, so word it as Claude Code sessions only.
   - Automatic update checks can be turned off in Settings. Track A adds this toggle if it is missing, so keep the claim.
2. **README.**
   - Add an Install section at the top: download Alloy.dmg from Releases, drag it to Applications, open it, choose a folder, then install and sign in to an agent. Requirements: Apple silicon and macOS 14 or later.
   - Claude Code is first-class and supported directly. Codex, Gemini CLI, OpenCode, Goose and custom agents run over ACP; link docs/acp.md.
   - Add a features section that covers Code mode: tree, tabs, splits, terminal, git, project search, command palette, multi-cursor, folding, keyboard settings and language servers.
   - Move the build-from-source steps under "Building from source".
   - Remove stale status, phase and pending-check text.
   - Add a privacy section: no telemetry and no account; the only requests Alloy itself makes are update checks; agents and language servers you run make their own connections.
   - Add "Reporting problems" (GitHub Issues), a licence line that points to THIRD-PARTY-NOTICES.md, and a docs list trimmed to user-facing docs.
3. **SECURITY.md and issue templates.** Add `SECURITY.md`, which says how to report a vulnerability privately through GitHub's private vulnerability reporting. Add bug report and feature request templates under `.github/ISSUE_TEMPLATE`.
4. **Site (Bench LandingContent and LandingPage, then regenerate Bench/site).**
   - Claude Code stays the lead and first-class. Copy that says Alloy is only for Claude Code becomes "for Claude Code and other AI coding agents". Add an "Other agents" feature or FAQ entry naming Codex, Gemini CLI, OpenCode, Goose and custom ACP agents.
   - The FAQ requirement becomes "at least one supported agent installed and signed in".
   - Requirements are Apple silicon and macOS 14+. Fix the privacy line as in the README. Link GitHub Issues.
   - `downloadAvailable` stays false. It is switched on only after the signed release exists.
   - Keep the existing structure, benchmark numbers and screenshots.

## Approved decisions

- The user asked to "fix any issues that we find and get ready for full release". Positioning (the orchestrator's call, from the user's ACP request): Claude stays first-class and the lead; other providers, including local ones, are a headline benefit.
- Apple silicon only for 0.1.0. No universal binary.
- No telemetry is added. No new network calls.
- Secrets live only in the Keychain. The "Add secret" entry stays disabled until MetalUI's SecureField lands; that is a separate follow-up, not part of these branches.
- Frame guards must not rise: chat 46; code 46/62/72; knownPopoverGap 0; steadyCompare 77; terminal 0/0/55; idle 0.
