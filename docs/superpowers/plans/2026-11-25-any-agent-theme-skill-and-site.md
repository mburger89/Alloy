# Any-agent theme skill and site refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- Theme sessions and the theme skill work with any agent, not only Claude.
- The landing site presents Alloy as the editor for any coding agent, and shows every feature added since launch.

**Architecture:**
- **Part A:**
  - ACP theme sessions get the `.theme` scope on the Alloy MCP server they already receive.
  - They also get theme guidance written with short tool names. When the tools can't be used, a file-writing fallback
    takes their place.
  - The skill installer gains a second target, `~/.agents/skills/alloy-theme`.
- **Part B:**
  - Copy and section changes in the Swift site generator.
  - New screenshots taken from the real app.

**Tech Stack:** Swift 6, MetalUI, Swift Testing, the Alloy ACP transport, and the `alloy-bench site` generator.

**Spec:** `docs/superpowers/specs/2026-11-25-any-agent-theme-skill-and-site-design.md`

## Global Constraints

- **Writing outside Alloy's own data:** only to `~/.claude/skills/alloy-theme` and `~/.agents/skills/alloy-theme`, and
  only on a user click. Tests inject a temporary home. Nothing may touch the real `~/.claude`, `~/.agents` or
  `~/.config/opencode`.
- **Key storage:** no API keys or secrets in files. Keys go to the Keychain only.
- **Worktrees:** use sibling worktrees: `../Alloy-themeskill` on branch `feat/theme-skill-any-agent`, and `../Alloy-site2`
  on branch `site/any-agent`. Never use Agent `isolation: worktree`.
- **Test processes:** kill only your own `swift test` or app PIDs. Never use a broad `pkill`.
- **MetalUI:** it is read-only. Report any gap in it; never work around one.
- **Cleanup:** delete every test artifact you create, including screenshots that aren't committed, logs and scratch
  projects.
- **SwiftLint:** it must stay clean. A blocking CI job runs `swiftlint --strict`.
- **Exact copy:** these strings are fixed by the spec.
  - Hero lead: "The native code editor for any AI coding agent, written in Swift, drawn on the GPU." (shortened by the user 2026-11-25)
  - New section title: "Bring your agent. Bring your model."
  - Themes sub: "Built-in themes, themes from plugins, or describe one to your agent and Alloy builds it."
  - Privacy line: "It never changes your agents' settings — the optional theme skill is installed only when you click
    it."
  - Privacy addition: "API keys are kept only in your macOS Keychain."
  - Theme-tools fallback notice: "<Agent> can't use Alloy's theme tools, so it will write the theme file into your
    themes folder instead; Alloy picks it up live."
  - Skill checkbox labels: "Claude Code" and "Codex, Gemini CLI, OpenCode, Goose".
  - Skill note: "OpenCode and Goose read both folders; the two copies are identical."
  - Skill hint: "Lets your agents make Alloy themes in any session, not just /theme."

## Review Focus

1. **Skill edited in only one folder.** If the user changed the installed skill in `~/.claude` but not in `~/.agents`,
   only that target asks before replacing; the other installs without asking. Tested in Task A4.
2. **Agent without HTTP MCP.** A theme session on an agent that doesn't take HTTP MCP gets the fallback notice and the
   file-writing prompt. It never starts silently without its tools. Tested in Task A3.
3. **"Ask before shared notes" is on.** The ACP theme tools are not auto-allowed, matching Claude sessions. Tested in
   Task A3.
4. **Relaunched theme session.** A restarted or relaunched ACP theme session still gets the `.theme` scope and the theme
   guidance. Tested in Task A3.
5. **Default agent removed.** If the default agent's definition is deleted, the Settings button reads "Make a theme
   with Claude…" and starts a Claude session. Tested in Task A4.

---

### Task A1: Installer targets

**Files:**
- Modify: `Sources/AlloyCore/Themes/ThemeSkillInstaller.swift`, `Sources/AlloyKit/Themes/ThemeController.swift:64`,
  `Sources/Alloy/main.swift:75`
- Test: `Tests/AlloyCoreTests/ThemeSkillInstallerTests.swift`

**Interfaces:**
- Produces:
  - `public enum ThemeSkillTarget: String, CaseIterable, Sendable { case claudeCode, sharedAgents }`
  - `ThemeSkillInstaller.init(home: URL, target: ThemeSkillTarget = .claudeCode)`, plus `public let target:
    ThemeSkillTarget`
  - `ThemeController.skillInstallers: [ThemeSkillTarget: ThemeSkillInstaller]`, which replaces `skillInstaller`
- `.claudeCode` installs to `<home>/.claude/skills/alloy-theme`, and `.sharedAgents` to `<home>/.agents/skills/alloy-theme`.

- [ ] **Step 1: Write the failing tests**
  - `sharedAgentsDirectory`: `ThemeSkillInstaller(home: tmp, target: .sharedAgents).directory.path` ends with
    `/.agents/skills/alloy-theme`.
  - `targetsAreIndependent`: install to `.sharedAgents`. That target's status is `.current`, `.claudeCode`'s status is
    `.notInstalled`, and `<tmp>/.claude` does not exist.
  - The existing tests stay unchanged; the default target is `.claudeCode`.
- [ ] **Step 2: Run the tests and confirm they fail**
  - Run: `swift test --filter ThemeSkillInstallerTests`
  - Expected: a compile failure, because `target` is unknown.
- [ ] **Step 3: Implement**
  - Add the target to the installer, and update the doc comment so it names both paths.
  - `main.swift` builds one installer per `ThemeSkillTarget.allCases` from `homeDirectoryForCurrentUser`.
  - `SettingsView` reads `skillInstallers[.claudeCode]` for now; Task A4 replaces this.
- [ ] **Step 4: Run the tests and confirm they pass**
  - Run: `swift test --filter "ThemeSkillInstallerTests|SettingsThemeSkillTests|ThemeSkillGuardTests"`
  - Expected: PASS.
- [ ] **Step 5: Commit** with the message "Theme skill installer: Claude Code and shared agents targets".

### Task A2: Agent-neutral skill text and guidance

**Files:**
- Modify: `Sources/AlloyKit/Themes/ThemeSkill.swift`, `Sources/AlloyCore/Themes/ThemeGuidance.swift`,
  `Sources/AlloyCore/Knowledge/Guidance.swift`, `docs/skills/alloy-theme/*` (regenerated)
- Test: `Tests/AlloyKitTests/ThemeSkillGuardTests.swift` and a new `Tests/AlloyCoreTests/ThemeGuidanceTests.swift`

**Interfaces:**
- Produces:
  - `ThemeGuidance.text`: Claude wording, unchanged.
  - `ThemeGuidance.acpText: String`: the same instructions, with the tools named `theme_slots`, `theme_read`,
    `theme_check`, `theme_preview` and `theme_save`.
  - `ThemeGuidance.fileModeText(themesFolder: String) -> String`: the skill's "Anywhere else" instructions, given the
    real folder path.
  - `Guidance.themeToolShortNames: [String]`
  - `Guidance.isAlloyToolTitle(_ title: String, server: String, includeTheme: Bool = false) -> Bool`

- [ ] **Step 1: Write the failing tests**
  - `acpTextUsesShortNames`: `acpText` contains `theme_preview` and does not contain `mcp__alloy__`.
  - `fileModeTextNamesFolder`: `fileModeText(themesFolder: "/x/Themes")` contains `/x/Themes`, and contains no
    `mcp__`.
  - `skillNamesToolsGenerically`: in `ThemeSkill.files(themesFolder:)["SKILL.md"]`, `mcp__alloy__theme_` appears only
    inside the sentence "Claude Code shows them as `mcp__alloy__theme_*`". The frontmatter `name: alloy-theme` is
    unchanged.
  - `themeTitleAutoAllow`:
    - `isAlloyToolTitle("alloy: theme_preview", server: "alloy", includeTheme: true)` is true.
    - With `includeTheme: false` it is false.
    - A plugin `p_abc123_theme_preview` is false either way.
- [ ] **Step 2: Run the tests and confirm they fail**
  - Run: `swift test --filter "ThemeGuidanceTests|ThemeSkillGuardTests"`
  - Expected: FAIL.
- [ ] **Step 3: Implement**
  - Write the guidance texts and the `includeTheme` flag.
  - Rewrite the SKILL.md mode headings so they key on "Alloy's theme tools (`theme_slots`, `theme_read`, `theme_check`,
    `theme_preview`, `theme_save`; Claude Code shows them as `mcp__alloy__theme_*`)".
  - Regenerate the docs copy: `ALLOY_WRITE_SKILL_DOCS=1 swift test --filter docsCopyMatchesGeneratedSkill`.
- [ ] **Step 4: Run the tests and confirm they pass**
  - Run the Step 2 command, plus `--filter docsCopyMatchesGeneratedSkill`.
  - Expected: PASS.
- [ ] **Step 5: Commit** with the message "Theme skill and guidance name Alloy's theme tools for any agent".

### Task A3: ACP theme sessions

**Files:**
- Modify:
  - `Sources/AlloyCore/Model/Workspace.swift`: `newThemeSession` at :743, and the slash routing at :1348-1352
  - `Sources/AlloyCore/Model/Workspace+ACP.swift`: `launchACP`
  - `Sources/AlloyCore/Agents/ACPLaunchConfiguration.swift`
  - `Sources/AlloyACP/ACPTransport.swift`: `openSession` at :147, and `permissionRequested` at :385
  - `Sources/AlloyCore/Themes/ThemeWorkshop.swift`
- Test: `Tests/AlloyCoreTests/ThemeSessionTests.swift` and `Tests/AlloyACPTests` (transport)

**Interfaces:**
- Consumes: from Task A2, `ThemeGuidance.acpText`, `ThemeGuidance.fileModeText(themesFolder:)` and
  `Guidance.isAlloyToolTitle(_:server:includeTheme:)`.
- Produces:
  - `Workspace.newThemeSession(description: String?, backend: SessionBackend? = nil) async -> Session`. A `nil` backend
    means `defaultBackend`.
  - `ACPLaunchConfiguration.autoAllowThemeTools: Bool = false`
  - `ACPLaunchConfiguration.promptWithoutTools: String?`
  - `ACPLaunchConfiguration.toolsUnavailableNotice: String?`
  - `ThemeWorkshop.themesFolderPath: String`; `ThemeController` already has it.
  - `public var Workspace.defaultAgentName: String`, which returns `agentDisplayName(for: defaultBackend)`.

- [ ] **Step 1: Write the failing tests**, using the existing fake ACP transport factory (see `ACPComposerTests` for the
  pattern).
  - `slashThemeInACPSessionUsesThatAgent`: `/theme dusk` in a session with backend `.acp("opencode")` creates a session
    whose `purpose == .theme` and `backend == .acp("opencode")`. No "/theme is not available" notice appears.
  - `acpThemeLaunchGetsThemeGuidance`:
    - The captured `ACPLaunchConfiguration` of a theme session has `mcp != nil`.
    - Its `systemPrompt` contains `ThemeGuidance.acpText`.
    - Its `autoAllowThemeTools` is true.
    - Its `promptWithoutTools` is `ThemeGuidance.fileModeText(themesFolder: <workshop path>)`.
    - Its `toolsUnavailableNotice` is the spec's notice, with the agent's name filled in.
  - `acpThemeAskBeforeSharedNotes`: with `askBeforeSharedNotes = true`, `autoAllowThemeTools` is false.
  - `acpThemeRelaunchKeepsTools`: relaunch the session (the settings-change relaunch path). The second captured
    configuration still has the theme guidance.
  - `newThemeSessionDefaultsToDefaultAgent`: with `defaultAgentID = "opencode"` and `backend: nil`, the session's backend
    is `.acp("opencode")`.
  - Transport, `themeFallbackWithoutHTTPMCP`:
    - Set up an agent whose `initialize` doesn't advertise `mcpCapabilities.http`, with `promptWithoutTools = "FILE"` and
      `toolsUnavailableNotice = "N"`.
    - Expect notice "N" to be emitted.
    - Expect the system prompt or preface sent to be "FILE".
    - Expect no "Shared notes are unavailable" notice.
  - Transport, `themeToolAutoAllowed`: with `autoAllowThemeTools = true`, a permission request titled
    `alloy: theme_save` is answered `allow_once` without a card.
- [ ] **Step 2: Run the tests and confirm they fail**
  - Run: `swift test --filter "ThemeSessionTests|ACPTransport"`
  - Expected: FAIL.
- [ ] **Step 3: Implement**
  - `launchACP`: when the session's `purpose == .theme`:
    - Insert `.theme` into the scopes.
    - Set `guidance` to the shared guidance (if `shareKnowledge` is on) and `acpText`, joined by `"\n\n"`.
    - Set `autoAllowThemeTools = !settings.askBeforeSharedNotes`.
    - Set `promptWithoutTools` and `toolsUnavailableNotice`.
    - When `mcpToken` or `serverURL` is nil, still pass the fallback fields.
  - Transport:
    - When `servers` is empty and `promptWithoutTools` is set, use it as the guidance. Emit `toolsUnavailableNotice`
      instead of the shared-notes notice.
    - Auto-allow when either `(autoAllowAlloyTools && isAlloyTool)` or `(autoAllowThemeTools && theme title)` holds.
  - Remove the ACP `/theme` refusal. Route `.theme` to `newThemeSession(description:backend: s.backend)`.
- [ ] **Step 4: Run the tests and confirm they pass**
  - Run the Step 2 command, then the full `swift test`.
  - Expected: PASS.
- [ ] **Step 5: Commit** with the message "Theme sessions run on any agent".

### Task A4: Settings: per-target install and the agent-named button

**Files:**
- Modify: `Sources/AlloyKit/SettingsView.swift`, the `ThemeSection` at :375-520
- Test: `Tests/AlloyKitTests/SettingsThemeSkillTests.swift`

**Interfaces:**
- Consumes:
  - From Task A1: `skillInstallers` and `ThemeSkillTarget`.
  - From Task A3: `Workspace.defaultAgentName` and `newThemeSession(description:backend:)`.

- [ ] **Step 1: Write the failing tests**, all against a temporary home.
  - `bothTargetsTickedByDefault`: two checkboxes, with ids `settings-theme-skill-target-claudeCode` and
    `settings-theme-skill-target-sharedAgents`, both on. Clicking Install writes both folders.
  - `untickedTargetUntouched`: untick `sharedAgents`, then install. `.agents` does not exist.
  - `editedTargetAsksOnlyForItself`:
    - Pre-write a changed `SKILL.md` under `.claude` only.
    - The button shows "Update theme skill…". Confirming replaces `.claude` and installs `.agents`.
    - With `.claude` unticked, the button installs `.agents` without any confirm.
  - `noTargetTickedDisablesButton`.
  - `makeThemeButtonNamesDefaultAgent`:
    - With `defaultAgentID = "opencode"` the label is "Make a theme with OpenCode…".
    - After the opencode definition is removed, it reads "Make a theme with Claude…".
  - The hint and note texts match the Global Constraints.
- [ ] **Step 2: Run the tests and confirm they fail**
  - Run: `swift test --filter SettingsThemeSkillTests`
  - Expected: FAIL.
- [ ] **Step 3: Implement**
  - The combined button state over the ticked targets:
    - all `.notInstalled` → Install;
    - any `.different` → "Update theme skill…" with the confirm;
    - all `.current` → installed, disabled.
  - Install acts per target, with `expecting` set to that target's status.
  - The status is read off the main actor, as today.
- [ ] **Step 4: Run the tests and confirm they pass**
  - Run the Step 2 command, then the full `swift test`.
  - Expected: PASS.
- [ ] **Step 5: Commit** with the message "Settings installs the theme skill for Claude Code and other agents".

### Task A5: Hands-on check, then merge

- [ ] **Step 1:** Build the branch app (`scripts/bundle-macos.sh` in the worktree).
- [ ] **Step 2: Launch a scratch copy.**
  - Launch it with a scratch `ALLOY_DATA_DIR` and a scratch sample project.
  - Add a custom agent "OpenCode (local)": command `opencode`, args `acp`, env
    `OPENCODE_CONFIG=<scratch>/opencode.json`. That file points OpenCode at Ollama's `qwen2.5-coder:7b`.
  - Never write `~/.config/opencode`.
  - Check the screen is unlocked first. Grep the whole lockcheck output for `ScreenIsLocked 1`.
- [ ] **Step 3: Make a theme with it.**
  - Use `/theme` in an OpenCode session.
  - Confirm the preview repaints the app, the contrast check runs, and the theme is saved and listed in Settings.
  - Capture one screenshot of the preview, kept for Part B as `shot-theme-agent.png`.
- [ ] **Step 4: Check the installer.**
  - Click Install with a temporary `HOME` for the scratch app.
  - Confirm both folders under the temporary home.
- [ ] **Step 5: Merge and publish.**
  - Merge to master.
  - `git push origin master:main`, then `tools/publish-public.sh --message "Theme skill and /theme work with any agent"`.
  - Remove the worktree and branch, then rebuild `build/Alloy.app`.
  - Delete the scratch data, the scratch project and the scratch OpenCode config.

### Task B1: Site copy and sections

**Files:**
- Modify: `Bench/Sources/BenchCore/LandingContent.swift`, `Bench/Sources/BenchCore/LandingPage.swift`, and the `<title>`
  and meta description wherever `LandingPage` writes them
- Test: `Bench/Tests/BenchCoreTests/LandingPageTests.swift`

**Interfaces:**
- Produces:
  - `LandingContent.agentsTitle`, `agentsSub`, `agentsPoints: [(String, String)]`
  - `agentsImages: [LandingContent.Feature]`: two shots, `shot-agents.png` and `shot-agents-settings.png`
  - New `features` entries, with images `shot-plugins.png` and `shot-csv.png`
- Missing assets render the existing plain panel.

- [ ] **Step 1: Write the failing tests**, in `LandingPageTests`.
  - `heroLeadIsAgentNeutral`: the page contains the exact hero lead, and does not contain "for Claude Code and other AI
    coding agents".
  - `agentsSectionFollowsRace`:
    - "Bring your agent. Bring your model." appears after the race section and before the shared-notes section.
    - It lists Claude Code, Codex, Gemini CLI, OpenCode and Goose, and "Agent Client Protocol".
    - It mentions a local model via Ollama, and the Keychain.
  - `newFeatureRows`: titles for Plugins and "CSV as a table". The editor list contains `alloy <file>`.
  - `privacyAndFAQAgentNeutral`:
    - The exact privacy line and privacy addition are present.
    - FAQ questions "Which agents and models can I use?" and "Can I use a local model?" are present.
    - "What do I need" mentions "at least one coding agent".
  - `themesSubAnyAgent`: the exact themes sub.
  - `titleAndMetaAgentNeutral`: neither the `<title>` nor the meta description names Claude Code alone.
- [ ] **Step 2: Run the tests and confirm they fail**
  - Run: `swift test --package-path Bench --filter LandingPageTests`
  - Expected: FAIL.
- [ ] **Step 3: Implement**
  - Put the copy in `LandingContent`. Render the new section in `LandingPage` with the existing section and feature
    CSS. No JavaScript, and no external resources.
  - Agent-neutral wording for feature row 1:
    - Title: "Many agent sessions. One folder."
    - Text: "Run Claude Code, Codex, Gemini CLI, OpenCode, Goose — or any ACP agent — side by side. Plans, questions and
      permission requests are answered in place."
  - Rows 2 and 3 stay as they are until Task B2 decides.
- [ ] **Step 4: Regenerate the committed site and run the tests**
  - Regenerate it with `alloy-bench site`, per `Bench/README`.
  - Run: `swift test --package-path Bench`
  - Expected: PASS, including `committedSiteIsCurrent`.
- [ ] **Step 5: Commit** with the message "Site: any agent, any model; plugins and CSV table".

### Task B2: Screenshots and claims check

This task runs after Task A5. Use a scratch sample project with nothing private in it, and capture by window id.

- [ ] **Step 1: Check the claims.**
  - With the OpenCode agent editing a file, check whether its lines get session colouring and whether an overlapping
    Claude edit raises the overlap warning.
  - If both hold, set rows 2 and 3 to say "any agent". Otherwise leave them as they are. Record the result in the
    commit message.
- [ ] **Step 2: Capture the shots into `Bench/site/assets`:**
  - `hero-poster.png`: Claude Code and OpenCode sessions side by side. Re-encode `hero.mp4` the same way if practical;
    otherwise delete `hero.mp4`, and the page uses the poster.
  - `shot-agents.png`: OpenCode on local `qwen2.5-coder:7b`.
  - `shot-agents-settings.png`: Settings › Agents. Show secret names only, never a value.
  - `shot-plugins.png`
  - `shot-csv.png`
  - `shot-theme-agent.png`, from Task A5, if the page uses it.
  - Keep each image under about 400 KB.
- [ ] **Step 3: Check every image for private content** (names, emails, tokens, paths under `/Users/<name>`).
- [ ] **Step 4: Regenerate the site and run** `swift test --package-path Bench`. Expected: PASS.
- [ ] **Step 5: Commit** with the message "Site: new screenshots for agents, plugins, CSV". Delete the scratch project,
  the data dir and any shots not used.

### Task B3: Look, merge, publish

- [ ] **Step 1: Look at the page.**
  - Open `Bench/site/index.html` in a browser at 1280 px and 390 px wide.
  - There is no horizontal scroll, and every image loads.
- [ ] **Step 2: Merge and publish.**
  - Merge `site/any-agent` to master.
  - `git push origin master:main`, then `tools/publish-public.sh --message "Site: any agent, any model"`.
  - Remove the worktree and branch.
