# Any agent: theme skill and site refresh — design

Approved by the user on 2026-11-25 ("approved, go ahead with both"). It has two parts, and they ship in this order: Part A (an app
feature), then Part B (the site).

## Why

The user wants everyone to know that Alloy works with whatever agent or model they want. Since the site was written,
Alloy has gained ACP agents, plugins, a CSV table view, Keychain-only API keys and `alloy <file>`. None of that is on the
page, which still reads "for Claude Code and other agents". The theme skill is the last feature that works with Claude
only.

## Part A: the theme skill works with any agent

**Goals**
1. `/theme` and Settings › "Make a theme…" run with any agent, not only Claude.
2. "Install theme skill" can install the skill for agents outside Alloy, not only Claude Code.
3. The skill text names no Claude-only tool names.

**Non-goals.** Nothing here lets Alloy call a model itself. There is no new transport, and nothing changes in how
Claude sessions get their tools.

**Anti-goals.** Never write any agent's folder without a click. Never fail silently when an agent can't take Alloy's
tools.

**Approaches considered**
- (picked) Give ACP theme sessions the theme tool scope on the Alloy MCP server they already receive, and install the
  skill to the shared `~/.agents/skills` folder as well as `~/.claude/skills`.
- (rejected) Install into each agent's own folder (`~/.codex/skills`, `~/.gemini/skills`, `~/.config/opencode/skills`,
  and so on). That means more paths and more writes outside Alloy, for no gain: Codex, Gemini CLI, OpenCode and Goose
  all read `~/.agents/skills`, per their docs as of 2026-11-25.
- (rejected) Let the skill's "write the file yourself" mode cover every agent and leave the tools Claude-only. That loses
  the live preview and the contrast check for non-Claude agents.

**Decided**
- **Which agent.** A theme session runs on a backend:
  - `/theme` typed in a session uses that session's agent.
  - Settings › "Make a theme with <default agent>…" uses the default agent (`settings.defaultAgentID`, else Claude). The
    button label names that agent.
  - The ACP refusal "/theme is not available for …" goes away.
- **ACP theme sessions.**
  - `launchACP` adds `.theme` to the MCP scopes when `s.purpose == .theme`.
  - It sends the theme guidance as the system prompt. When shared notes are on, both guidance texts go, joined.
  - In text sent to ACP agents, tools are named by their short names (`theme_slots`, `theme_read`, `theme_check`,
    `theme_preview`, `theme_save`), as `Guidance.alloyToolShortNames` already does for notes.
  - Permission auto-allow for theme tools matches what a Claude theme session gets.
- **An agent that can't take Alloy's tools.** This covers an agent that doesn't advertise HTTP MCP, or a server that
  isn't running.
  - The theme session still starts.
  - Its transcript gets one notice: "<Agent> can't use Alloy's theme tools, so it will write the theme file into your
    themes folder instead; Alloy picks it up live."
  - The guidance switches to the skill's "write the file yourself" text, with the real themes folder path.
- **Installer targets.**
  - `ThemeSkillInstaller` installs to one or both of:
    - `.claudeCode`: `~/.claude/skills/alloy-theme`
    - `.sharedAgents`: `~/.agents/skills/alloy-theme`
  - Status is reported per target.
  - Settings shows two checkboxes under the skill button, both ticked by default:
    - "Claude Code"
    - "Codex, Gemini CLI, OpenCode, Goose"
  - The button acts on the ticked targets. Install, update and replace-confirm keep today's semantics, applied per target.
  - Note line: "OpenCode and Goose read both folders; the two copies are identical."
  - Hint: "Lets your agents make Alloy themes in any session, not just /theme."
- **Skill text.**
  - "In an Alloy theme session" mode is keyed on Alloy's theme tools being available, named generically: `theme_slots`
    etc., with "(Claude Code shows them as `mcp__alloy__theme_*`)".
  - Frontmatter `name` stays `alloy-theme`, equal to the folder name. Goose needs that.
  - The docs copy in `docs/skills/alloy-theme` is regenerated.
- **Rule update.** Alloy writes outside its own data only to `~/.claude/skills/alloy-theme` and
  `~/.agents/skills/alloy-theme`, and only when the user clicks.

**Verify**
- Unit tests:
  - per-target installer status and install, including the replace-confirm path;
  - ACP theme launch gets the `.theme` scope and the theme guidance;
  - `/theme` from an ACP session starts a theme session on that agent;
  - the no-HTTP-MCP fallback notice.
- Hands-on: in the real app, make a theme with OpenCode. Preview it, check it, save it, and see it in Settings.

## Part B: the site says "any agent"

The site source is `Bench/Sources/BenchCore/LandingContent.swift` and `LandingPage.swift`. The page is generated into
`Bench/site` and tested by `LandingPageTests`.

**Goals.** Alloy reads as the native editor for any coding agent. Every feature added since launch is on the page.

**Non-goals.** No redesign, no new build tooling, and no JavaScript. `downloadAvailable` stays false.

**Anti-goals.**
- A claim the app doesn't back. The rule is unchanged: a feature or claim appears only after a hands-on check.
- Any private content in a screenshot.

**Decided**
- **Hero.**
  - Title stays "Fast. Native. Yours."
  - Lead: "The native code editor for any AI coding agent, written in Swift, drawn on the GPU." (shortened by the user 2026-11-25)
  - The hero poster is reshot with a Claude Code session and an OpenCode session side by side. The hero video is reshot
    the same way, or else dropped in favour of the poster.
- **New section after the race: "Bring your agent. Bring your model."**
  1. Five agents built in, and any Agent Client Protocol agent can be added in Settings.
  2. Any model through the agent you pick, including local ones; shown with OpenCode running `qwen2.5-coder:7b` through
     Ollama.
  3. API keys live only in your macOS Keychain.
  - Two shots: the agents and local-model chat, and Settings › Agents.
- **Features.**
  - Row 1 text becomes agent-neutral.
  - The rows "Know who changed what" and "Sessions that don't collide" say "any agent" only if the hands-on check shows
    attribution and overlap warnings with an ACP agent. Otherwise their copy stays as it is.
  - New rows:
    - "Plugins": themes, language servers, commands, panels and agent tools, sandboxed. Shot: Settings › Plugins or a
      plugin panel.
    - "CSV as a table": edit cells, sort, keep or revert. Shot: a CSV in Table view.
- **Editor list.** Add "Open from the terminal: `alloy <file>`".
- **Themes.** Subtitle: "Built-in themes, themes from plugins, or describe one to your agent and Alloy builds it." This
  lands after Part A.
- **Privacy.**
  - "It never changes your agents' settings — the optional theme skill is installed only when you click it."
  - Add: "API keys are kept only in your macOS Keychain."
- **FAQ.**
  - "Does it work with other agents?" becomes "Which agents and models can I use?"
  - Add "Can I use a local model?" (yes, through an agent that supports one, e.g. OpenCode or Goose with Ollama).
  - "What do I need" says "at least one coding agent".
  - The page `<title>` and meta description become agent-neutral.
- **Proof strip.** Unchanged. Its numbers come from the benchmark.
- **Screenshots.**
  - Taken from the real app on a scratch sample project with nothing private in it, captured by window id.
  - Check the screen is unlocked first.
  - The user has approved taking whatever shots are needed.

**Verify**
- `swift test --package-path Bench` is green, with `LandingPageTests` updated for the new copy and sections.
- The committed site is regenerated (`committedSiteIsCurrent`).
- The page is viewed in a browser at desktop and phone width.
- Then merge, push and publish as usual.

## Left to the builder

- The exact layout of the new section, within the page's existing CSS.
- Image sizes and compression, keeping the page light.
- Test names.
