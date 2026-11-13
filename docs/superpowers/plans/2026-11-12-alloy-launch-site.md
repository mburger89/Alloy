# Alloy Launch Site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Signed, notarised DMG releases on GitHub, an Alloy that updates itself through Sparkle 2 with its own
MetalUI update UI, and a static landing page at the GitHub Pages root that gets visitors to download.

**Architecture:** Shell release tooling around the existing `scripts/bundle-macos.sh`; Sparkle 2's `SPUUpdater` driven
by a custom `SPUUserDriver` in AlloyKit; a Swift site generator in the `Bench` package (next to the benchmark page
generator) that renders `/`, `/benchmarks/` and `appcast.xml` into `Bench/site`, deployed by the existing Pages
workflow.

**Tech Stack:** Swift 6, SwiftPM, Sparkle 2 (SwiftPM binary package), MetalUI, `codesign` / `notarytool` / `stapler`
/ `hdiutil`, `gh`, static HTML + CSS (+ small inline JS), GitHub Pages.

**Spec:** `docs/superpowers/specs/2026-11-12-alloy-launch-site-design.md`

## Global Constraints

- Bundle identifier `com.unicornlabs.Alloy`; version semver from 0.1.0, `CFBundleVersion` a monotonically increasing integer; tag `v<version>`.
- No secrets in the repo, CI or logs: signing identity name from `ALLOY_SIGN_IDENTITY`, notary keychain profile name from `ALLOY_NOTARY_PROFILE`, EdDSA key read by Sparkle's tools from the login keychain. Scripts fail with a clear message when either env var is missing (except in `--dry-run`).
- Releases are cut locally; the release script asks for confirmation (`y`) before tagging, uploading and publishing.
- Sparkle pinned to an exact version; `SUEnableSystemProfiling` NO; feed `https://mburger89.github.io/Alloy/appcast.xml`; automatic checks daily and at launch; install on quit only.
- No Sparkle AppKit windows: a custom user driver with MetalUI UI. A missing MetalUI capability is filed with the MetalUI session, never worked around.
- Site: static, no external resources (no CDN, fonts, analytics, cookies); inline JS only for the race and theme swatches; every number from published benchmark JSON at generation time; works without JS (race shows final bars).
- Download URL `https://github.com/mburger89/Alloy/releases/latest/download/Alloy.dmg`.
- Existing benchmark page moves to `/benchmarks/`; `/data/*` URLs keep working; old `/index.html` deep links land on `/`.
- Public repo privacy gate applies (no personal paths, files under 5 MB); never write `~/.claude` or the project's `.claude`.
- Never launch the GUI app from a subagent; never pkill; commit trailers `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and the session link trailer.
- Work happens in the sibling checkout `../Alloy-bench` on a branch `feat/launch-site` (the main checkout is busy with LSP work).

## Review Focus

1. A release run interrupted midway (notarisation rejected, network down, `n` at the prompt): nothing is tagged, uploaded or published, and the error says what failed (Task 2 test `releaseStopsBeforePublishingOnFailure`).
2. An update arrives while Claude sessions are running: nothing installs until the user quits or chooses Restart, and sessions shut down cleanly first (Task 4 test `installWaitsForQuit`).
3. The update feed is unreachable or malformed: no error dialog storm; one quiet "couldn't check" in Settings (Task 4 `feedErrorIsQuiet`).
4. A visitor with JavaScript off, reduced motion on, or a phone: the page is complete, readable and the Download button works (Task 5 `pageWorksWithoutScript`, `reducedMotionDisablesAnimation`).
5. A benchmark JSON where Alloy loses a test: that test is not offered in the race and no proof-strip number claims it (Task 5 `raceOffersOnlyWins`).

---

### Task 1: Bundle identity, hardened runtime and versioned bundles

**Files:** Modify `Packaging/macOS/Info.plist`, `scripts/bundle-macos.sh`; Create `Packaging/macOS/Alloy.entitlements`; Test `Tests/AlloyKitTests/PackagingTests.swift` (reads the plist and script as files).

**Interfaces:** Produces `scripts/bundle-macos.sh [--version X.Y.Z --build N]`: sets `CFBundleShortVersionString`/`CFBundleVersion` in the bundled plist; signs with `--options runtime --timestamp --entitlements Packaging/macOS/Alloy.entitlements` when `ALLOY_SIGN_IDENTITY` is set, ad hoc otherwise (unchanged default). Embeds and signs `Contents/Frameworks/*.framework` inside-out when present (used by Task 3).

- [ ] Test `bundleIdentifierIsUnicornLabs` (`CFBundleIdentifier == "com.unicornlabs.Alloy"`), `entitlementsAreMinimal` (the entitlements plist contains only keys Alloy needs: none for sandbox; `com.apple.security.cs.disable-library-validation` absent unless justified in the report), `bundleScriptAcceptsVersion` (running `scripts/bundle-macos.sh --version 0.1.0 --build 7` in a temp copy produces a plist with those values; ad hoc signature verifies).
- [ ] Run, FAIL → implement → PASS (filtered, then full `swift test`) → commit `feat(release): com.unicornlabs.Alloy, hardened runtime, versioned bundles`.

### Task 2: Release script: notarise, staple, DMG, GitHub Release

**Files:** Create `scripts/release-macos.sh`, `Packaging/macOS/dmg/` (background image, layout), `Tests/ReleaseScriptTests/` (shell-driven Swift tests using stub `xcrun`, `gh`, `hdiutil` on `PATH`).

**Interfaces:** `scripts/release-macos.sh <version> [--dry-run]`: checks clean tree on `master` == `origin/main` and that `tools/publish-public.sh` has been run for this commit; bundles (Task 1) with `--build $(git rev-list --count HEAD)`; `xcrun notarytool submit --keychain-profile "$ALLOY_NOTARY_PROFILE" --wait` for the zipped app, staples; builds `Alloy.dmg` (app + Applications link), signs, notarises, staples; `spctl -a -t open --context context:primary-signature -vv Alloy.dmg` and `codesign --verify --deep --strict` must pass; writes `build/release/<version>/` with `Alloy.dmg` and `Alloy-<version>.dmg` (same bytes); prompts `Publish v<version>? [y/N]`; on `y`: `git tag v<version>`, `gh release create v<version> -R mburger89/Alloy` with both DMGs and notes from `docs/releases/<version>.md`, then calls Task 3's appcast step. `--dry-run` signs ad hoc, skips notarisation, never tags or publishes.

- [ ] Tests with stubs recording their argv: `dryRunNeverPublishes`, `missingEnvFailsClearly`, `releaseStopsBeforePublishingOnFailure` (stub notarytool exits 1 → no `gh`/`git tag` calls, message names the step), `answerNoPublishesNothing`, `publishUploadsStableAndVersionedDMG`.
- [ ] FAIL → implement → PASS → commit `feat(release): notarised DMG release script`.

### Task 3: Sparkle 2 dependency and appcast generation

**Files:** Modify `Package.swift` (Sparkle binary package, exact pin; AlloyKit depends on it), `scripts/bundle-macos.sh` (embed `Sparkle.framework`), `Packaging/macOS/Info.plist` (`SUFeedURL`, `SUEnableSystemProfiling` NO, `SUEnableAutomaticChecks` YES, `SUScheduledCheckInterval` 86400, `SUPublicEDKey` placeholder replaced at bundle time from `ALLOY_SPARKLE_PUBLIC_KEY`, required for release builds), `scripts/release-macos.sh` (after publishing: `generate_appcast` over `build/release/*/Alloy-*.dmg` into `Bench/site/appcast.xml` with `--download-url-prefix https://github.com/mburger89/Alloy/releases/download/v<version>/`, release notes from `docs/releases/<version>.md` rendered to HTML), `Tests/AlloyKitTests/PackagingTests.swift`.

- [ ] Tests: `infoPlistHasSparkleKeys`, `releaseBundleRequiresPublicKey` (bundle without `ALLOY_SPARKLE_PUBLIC_KEY` in release mode fails), `bundleEmbedsSignedSparkle` (dry-run bundle contains `Contents/Frameworks/Sparkle.framework` and `codesign --verify --deep --strict` passes), `appcastStepWritesSiteFeed` (stub `generate_appcast`; argv and output path checked).
- [ ] FAIL → implement → PASS → commit `feat(update): Sparkle 2 packaging and appcast generation`.

### Task 4: Updater with Alloy's own UI

**Files:** Create `Sources/AlloyKit/Update/UpdateController.swift` (owns `SPUUpdater`, conforms a `@MainActor` custom user driver), `Sources/AlloyKit/Update/UpdateModel.swift` (`@Observable` state: idle / checking / available(version, notes) / downloading(progress) / readyToInstall(version) / error(message), last check date, automatic checks flag), `Sources/AlloyKit/Update/UpdateBanner.swift` (sidebar row "Alloy <v> is ready — Restart to update", notes sheet), Settings row (automatic checks toggle, last checked, "Check for Updates…"), app menu item "Check for Updates…"; Modify `Sources/Alloy/main.swift` (start the updater only in a bundled app with a feed URL; never in tests or `swift run`), the quit path (install on quit after sessions stop); Test `Tests/AlloyKitTests/UpdateTests.swift`.

**Interfaces:** `protocol UpdateDriving` abstracts Sparkle's callbacks so tests feed a fake: `UpdateController(driver: UpdateDriving, model: UpdateModel)`. Sparkle's user-driver methods map onto `UpdateModel` transitions; install is only ever triggered by quit or the banner's Restart (which runs the normal shutdown first).

- [ ] Tests with a fake driver: `foundUpdateShowsBanner`, `notesSheetShowsReleaseNotes`, `installWaitsForQuit` (readyToInstall does not install until quit; quit runs `stopAll` before install), `restartRunsShutdownThenInstalls`, `feedErrorIsQuiet` (no modal; Settings shows "Couldn't check for updates" with time), `automaticChecksToggleIsPersisted`, `updaterNotStartedOutsideBundle`, `bannerDoesNotRerunWhileTyping` (BodyProbe pattern from `ViewRerunTests`).
- [ ] FAIL → implement → PASS → commit `feat(update): self-updating with Alloy's own update UI`.

### Task 5: Site generator: landing page, /benchmarks/, redirects

**Files:** Create `Bench/Sources/BenchCore/LandingPage.swift` (renders `/index.html` from the published benchmark index + a content model), `Bench/Sources/BenchCore/LandingContent.swift` (copy from the spec, verbatim titles: "Fast. Native. Yours.", "Stop paying to read the same file twice." / "Your sessions share what they learn.", etc.), `Bench/site/assets/` (screenshots, poster, video — added by Task 6), Modify `Bench/Sources/alloy-bench/SiteCommand.swift` (render `/` landing, `/benchmarks/index.html` = existing page, keep `/data/`, write `appcast.xml` only if Task 3 produced one), `Bench/Sources/BenchCore/SitePage.swift` (links relative to `/benchmarks/`), `.github/workflows/pages.yml` (paths unchanged: `Bench/site/**`), Tests in `Bench/Tests/BenchCoreTests/LandingPageTests.swift`.

**Interfaces:** `LandingPage.render(index: PublishedIndex, runs: [PublishedRun], content: LandingContent) -> String`; `RaceData.wins(from: PublishedRun) -> [RaceTest]` returns only metrics where Alloy's median beats Zed's (and includes Delta's value only where measured).

- [ ] Tests: `raceOffersOnlyWins` (a fixture where Alloy loses memory → memory absent from race and proof strip), `everyNumberComesFromData` (no digits in rendered numeric slots that aren't in the JSON), `noExternalResources` (no `http(s)://` in `src`/`href` except GitHub and the download URL; no `<link rel=stylesheet>` to other origins), `pageWorksWithoutScript` (race bars render at final widths in HTML; Download is a plain link), `reducedMotionDisablesAnimation` (CSS has a `prefers-reduced-motion` block), `benchmarksMovedAndDataStays` (`/benchmarks/index.html` exists, `/data/*.json` unchanged), `committedSiteIsCurrent` extended to the landing page.
- [ ] FAIL → implement → PASS (`swift test --package-path Bench`) → commit `feat(site): landing page at the Pages root, benchmarks at /benchmarks/`.

### Task 6 (controller): screenshots, hero clip, first release

Not a subagent task (needs the GUI and the user's credentials).
- [ ] Controller captures screenshots and a ≤ 20 s hero clip (H.264, muted, ≤ 4 MB) from the real app on a scratch project, Dracula theme, with a few short Claude turns; adds them to `Bench/site/assets/`; regenerates the site; privacy gate.
- [ ] User does the hand steps in the spec (certificate, `notarytool store-credentials`, `generate_keys`), exports `ALLOY_SIGN_IDENTITY`, `ALLOY_NOTARY_PROFILE`, `ALLOY_SPARKLE_PUBLIC_KEY`.
- [ ] Controller merges, publishes the public sync, runs `scripts/release-macos.sh 0.1.0` (user answers `y`), checks the live page, the download, Gatekeeper on a fresh download, and an update from a locally built 0.0.9 to 0.1.0 via a test appcast.
