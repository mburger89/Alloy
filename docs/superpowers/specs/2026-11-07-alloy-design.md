# Alloy — design

Date: 2026-11-07
Status: draft for approval

Alloy is a native macOS code editor built on MetalUI (`../MetalUI`) with LLM sessions at its core. It hosts several Claude Code sessions working in the same folder, shows every change attributed to the session that made it, lets you review those changes live (inline or side-by-side), and helps the sessions coordinate so they don't trample each other. A second goal is to measure MetalUI against Zed and Delta with real numbers.

Items marked **(builder's call / my call)** were not decided by the user; they are defaults the builder may revisit.

---

## 1. Why

The user runs several Claude Code terminals on the same folder. The pain: **losing track of which session changed which files**, and collisions between sessions that are **only noticed later**. Alloy fixes that by hosting the sessions itself, so every edit is known, attributed, and visible the moment it happens, and so sessions are told about each other's changes before they collide.

The second reason is MetalUI: Alloy is a demanding real app that pushes MetalUI toward editor-grade text and performance, and the benchmark suite answers "how does MetalUI compare with Zed and Delta (both GPUI-on-Metal)?" with measured numbers.

## 2. Goals

1. **Host Claude Code sessions** inside the editor (not watch external terminals). Several sessions, one folder.
2. **Attribute every edit** to its session: per file, per line, live.
3. **Rich, central chat** for each session, with thinking, tool calls, file edits, and shell output clearly visible, color-coded by type via the theme, each with a descriptive icon.
4. **Live diff review**, inline and side-by-side, per session; revert any individual edit.
5. **Coordination**: warn the user *and* make sessions aware of each other's active and proposed changes so they adjust on their own, without wasting tokens.
6. **Benchmark** Alloy (MetalUI) against Zed and Delta: measured numbers, repeatable — and **at least on par with Zed**, results published on a GitHub Pages site.

## 3. Non-goals (for v1)

- Full IDE editing: go-to-definition, autocomplete/LSP, multi-cursor, refactoring, git panels, extensions. **Future** — v1's code view must be built so these can be added (see §6.4).
- Sharing or distributing Alloy. It is a personal tool. It uses the user's existing `claude` login; no API-key flow, no claude.ai login inside Alloy.
- Linux/Windows. macOS only for v1 **(my call)**; MetalUI's cross-platform ports make it possible later.
- Non-Claude LLMs **(my call)**. The session layer should be an abstraction so others could be added, but v1 ships only Claude Code.
- Separate git worktrees per session. The user's workflow is all sessions on the same folder.

## 4. Anti-goals (failure even if it "works")

- **Sessions going red and trampling each other, needlessly spending tokens.** Coordination that creates noise, alarm, argument or ping-pong is worse than none. Every coordination feature is judged against this.
- Alloy blocking or pausing sessions on its own. The user explicitly does not want edits blocked.
- Modifying the user's global Claude Code config. Everything Alloy needs is passed per launch.
- Working around MetalUI gaps inside Alloy instead of fixing them in MetalUI (standing rule: MetalUI gaps go to the MetalUI session).

## 5. Constraints

- **UI framework:** MetalUI only, via a path dependency like `MetalUI/Examples/Jotter` (`.package(name: "MetalUI", path: "../MetalUI")`). MetalUI is SwiftUI-API-shaped over Metal; minimum macOS 14; swift-tools 6.x.
- **MetalUI gaps:** whenever Alloy needs something MetalUI lacks, file it with the MetalUI Claude session with use case, stopgap, and wanted API — and keep any stopgap in Alloy minimal and logged in `Alloy/docs/metalui-gaps.md`. Known gaps from the survey (2026-11-07):
  - **G1 Code view:** MetalUI's `TextEditor` is a controlled `String` with whole-text undo snapshots — not viable for large files. Need a buffer-backed (rope/piece-table) text view with per-range styling, line numbers, gutter decorations, efficient incremental layout. (May be built as a MetalUI component, or as a custom element on MetalUI's `drawText`/`GPUSurface` — decide with the MetalUI session; the user's rule favors MetalUI owning reusable pieces.)
  - **G2 Block markdown** for chat (code fences with highlighting, lists, headings). MetalUI only has inline markdown in `Text`.
  - **G3 Icons:** no SF Symbols / `Image(systemName:)`. Need an icon system (vector paths) or SF Symbol support.
  - **G4 Tabs** (no `TabView`).
  - **G5 Two-axis scrolling** for wide code (documented as not offered).
  - **G6 Variable-height virtualized list** suited to long chat transcripts (check `List` row-height model vs `LazyVStack`).
  - **G7 Perf instrumentation:** signposts / frame-time hooks to support benchmarks.
- **Claude Code:** installed at 2.1.319 on this machine. Alloy runs the user's installed `claude` binary.
- Alloy must not be branded or named "Claude Code".

## 6. How it works (decided parts)

### 6.1 Layout (user picked mockup "A", with "B"'s chat)

Three columns, resizable (`HSplitView`):

- **Left sidebar:** sessions list (each with its own color, status, a ⚠ when involved in an overlap, and per-session token/cost), then **changed files**, each marked with one dot per session that touched it.
- **Center: the chat** for the selected session — the heart of the app. Diffs appear *inside* the chat at the point the edit happened (as in mockup B), expandable, with actions.
- **Right: file panel** with tabs; the file with a live diff, each changed line's gutter colored by the session (or the user) that changed it; toggle between inline and side-by-side.

The approved mockups are in `docs/mockups/` (`layout.html` — the user chose **A**, with **B**'s in-chat diffs; `chat-detail.html` — confirmed as pictured). Recreate them in MetalUI; they are references, not assets. They predate two decisions: the edit buttons are now **Keep / Revert / Open in file / Side by side**, and each block carries an icon.

### 6.2 The chat (user confirmed the mockup)

- Each block type has its own **theme color** and a **descriptive icon**:
  - thinking — purple, brain/sparkle icon, collapsible, italic
  - read / search (Read, Grep, Glob) — teal, document / magnifier icons
  - shell (Bash) — amber, terminal icon, with command, exit code, duration, output
  - file edit / write — green/red diff, pencil / new-document icons, with **Keep / Revert / Open in file / Side by side**
  - web — globe; subagent — person/robot; error — red ✕; overlap — ⚠ amber
  - Claude's replies — plain text with block markdown
- **Session color** is a stripe down the chat's left edge; type colors and session colors never compete.
- Long blocks collapse to a one-line summary ("Read login.swift · 120 lines"); click to expand.
- Streaming: text and thinking appear as they arrive.
- **Permission prompts** appear in the chat as Approve / Deny cards.
- Coordination messages (from Alloy or another session) appear in the chat with their own color and icon, so the user can follow them.
- Colors live in the theme as tokens (MetalUI `ThemeColorKey`), so the palette is changeable.

### 6.3 Hosting sessions

- One `claude` subprocess per session, all with the project folder as cwd, using the user's existing login.
- **Finding `claude`:** auto-detect like the user's shell does (resolve via the login shell `PATH`; on this machine `/opt/homebrew/bin` or `~/.local/bin`); a **setting holds an override path**.
- Launch shape (from the 2026-11-07 docs research; verify on the installed version):
  `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --include-hook-events --replay-user-messages --session-id <uuid> --mcp-config <alloy-mcp> --settings <alloy-hooks> --allowedTools "mcp__alloy__*"`
  - Do **not** use `--bare` (it disables hooks).
  - Everything Alloy-specific is passed per launch; nothing is written to `~/.claude` or the project's `.claude/`.
- Events rendered: `system/init`, `stream_event` (partial text/thinking), `assistant` (text, thinking, tool_use), `user` (tool_result + `tool_use_result` with `structuredPatch`), `result` (cost/usage), hook events.
- **Permissions follow the user's own Claude Code settings** (user decision). Alloy does not force a `--permission-mode` or pre-approve tools other than its own `mcp__alloy__*`; the user's and project's settings files load as usual (`--bare` is off). Whatever those settings leave as "ask" becomes an **Approve / Deny** card in the chat, answered through the stream-json control protocol (`control_request` → Alloy's UI → `control_response`; fallback `--permission-prompt-tool` on Alloy's MCP server). The user can switch a session's mode (default / accept edits / plan / auto…) from the chat, as in the CLI.
- **The chat input supports everything the user uses in the CLI** (user decision: "a pretty heavy user… include all of them"):
  - **Slash commands** — built-in ones (`/compact`, `/model`, `/clear`, …), the user's custom commands and skills — with autocomplete. Commands that work in stream-json mode are passed through; ones that are interactive-only in the CLI are rebuilt by Alloy on the control protocol or the matching flags (e.g. `/model` → change model, `/clear` → new session id). The builder must verify each against `claude` 2.1.319 and list any that truly can't be supported, rather than silently dropping them.
  - **Plan mode**, with the plan shown as a card the user can approve or send back.
  - **AskUserQuestion** — Claude's multiple-choice questions shown as a card; the answer goes back via `updatedInput`.
  - **Image paste / drop** into the message.
  - **`@file` mentions** with project file autocomplete.
  - **Interrupt** (Esc) and **queueing a message while Claude is working** (`priority: "next"`).
  - Resume / history of past sessions.
- **Resume:** Alloy owns session ids; reopening the project resumes sessions with `--resume` and rebuilds the chat from the `.jsonl` transcript.
- Session lifecycle: new, rename, interrupt (SIGINT ends the turn cleanly), stop, resume.
- **To verify empirically early** (docs were thin): exact control-protocol JSON; that `--settings`-supplied `http` hooks run without `--bare`; whether PostToolUse `tool_response` for Edit includes `structuredPatch`; where `tool_use_result` sits on the `user` message. A throwaway probe script against `claude` 2.1.319 is the right first task.

### 6.4 Edits, attribution and review

- **Edits go straight into the file** (no proposal/accept gate). The user can revert later.
- Alloy records every edit as an **edit record**: session (or "you"), file, timestamp, tool_use id, hunks (from `structuredPatch`, falling back to diffing before/after).
- **Edit history is a text CRDT (user decision, 2026-11-07)** — a small Swift one in `AlloyCore`, modeled on Zed's buffer minus networking, not a library. Every inserted span carries a permanent identity (edit id + offset, hence author); deleted text stays as tombstones tagged with the deleting edit. It is used for identity, not merging: Alloy applies edits one at a time as tool results arrive. What this gives:
  - **Character-level attribution**: two sessions changing different parts of one line are both credited. Line coloring is derived from the characters (a line's owner = latest live edit that inserted on it).
  - **Revert by identity**: hide the edit's inserted spans, un-delete its tombstones. No context search. A revert is a conflict only when another live edit has since inserted into or deleted from this edit's inserted text; then nothing changes and the user resolves it by hand.
  - **Stable anchors** that track text through later edits — used by coordination (Plan 5) for overlap regions and proposed changes.
  - Diffs, Keep (fold an edit's spans into the baseline and drop its tombstones) and the file panel's colors all derive from this one structure.
  - The MetalUI `CodeBuffer` (G1) emits an edit stream; the user's own saved edits feed this history as author "You". The typing hot path stays in MetalUI's buffer.
- **Edits made outside Alloy** (the user in Zed, `git checkout`, a session's Bash `sed`): detected via file watching and attributed to "outside" (or, for Bash, to the session that ran the command when timing/`bashEditDiff` makes that clear). **(my call)**
- **The user's own edits** in the code panel are one more author ("You"), with its own color; sessions are told about them like any other change.
- **Code view v1:** read + small fixes, fast. Syntax highlighting, line numbers, author-colored gutter, inline and side-by-side diff, find in file, undo/redo. Built on a real buffer with an incremental syntax tree (tree-sitter is the obvious choice; **builder's call** with the MetalUI session) so LSP features can be layered on later.

### 6.5 Coordination (user decisions in bold)

1. **Warn the user and let the sessions work it out — both.**
2. **Never block an edit.** Before a session edits (PreToolUse hook, an `http` hook to Alloy's localhost server), Alloy checks for overlap with **other sessions' active changes and proposed changes** (a proposed change = an edit tool call that has been issued but not yet applied, e.g. awaiting permission). On overlap, the hook returns `additionalContext` only — no permission decision — telling the session what changed so it **adjusts accordingly**.
3. **Only real overlap triggers it:** the same or adjacent lines (a small line margin, **builder's call**, start ~3 lines), not "same file".
4. **Messages are short and factual**, never alarmist: who, when, which lines, and the compact diff. Example: *"auth refactor changed login.swift lines 40–58 3 minutes ago: <diff>"*. Capped well under the 10k-char hook limit.
5. **Shared tools for sessions** via Alloy's MCP server (`mcp__alloy__*`): list other sessions and their changed files/lines; send a message to another session; mark a file/region "I'm working on this". Messages between sessions are delivered by writing a `user` message to the target's stdin with `priority: "next"` and shown in both chats.
6. **Rate-limit cross-session messages** to prevent ping-pong (limits are **builder's call**).
7. **Tug-of-war detection:** if the same lines flip between two sessions (A → B → A), Alloy **sends the session that made the latest edit an instruction to stop editing those lines and move on**, e.g. *"Lines 40–58 of login.swift are going back and forth between you and auth refactor. Leave them as they are now and move on with the rest of your task."* — and alerts the user at the same time. If that session edits those lines again anyway, the alert escalates to the user. Alloy never pauses a session itself.
8. **User-facing warnings:** ⚠ on the sessions involved and the file in the sidebar, the warning inline in both chats where it happened, and a small notice if the user is looking at another session. Red is reserved for things that truly need the user.
9. **Token visibility:** per-session tokens and cost in the sidebar, so waste is visible early.

### 6.6 Benchmarks (Alloy vs Zed vs Delta)

- **Target (user decision): Alloy must be at least on par with Zed (GPUI) on every measured number; better is a plus.** A shortfall is a defect: find whether it is Alloy's or MetalUI's, and send MetalUI causes to the MetalUI session. The plan therefore needs benchmark checkpoints after the code view and chat land, not only at the end.
- **Results will be published on a GitHub Pages site** (user decision). No Pages site exists yet for `mburger89/MetalUI` (checked 2026-11-07); which repo hosts it and its design are a later step **(my reading: MetalUI's site)**. The harness writes machine-readable results (JSON/CSV) plus charts-ready data so the page can be generated from them.
- A separate harness (its own target or package in the Alloy repo, **builder's call**) that drives all three apps the same way from outside, on this Mac: `/Applications/Zed.app` (1.27.0) and `/Applications/Delta.app` (Zed Industries' agent-first app, 0.1.0, also GPUI on Metal).
- **Measured numbers**, many runs, report median and p95, with the date, app versions, display refresh rate, and machine state recorded:
  1. Startup to first frame (cold and warm).
  2. Typing latency (keystroke to pixels), e.g. CGEvent injection + ScreenCaptureKit change detection, in the Typometer style.
  3. Scroll frame times on a large file.
  4. Memory (`phys_footprint`) idle and after opening a large file, including child processes.
  5. Time to open a large file.
  6. Idle CPU.
- Fixed test inputs (a set of real source files including a very large one) committed to the repo.
- Results saved as dated files in the repo, plus a readable summary.
- Agent-UI comparisons with Delta (e.g. scrolling a long transcript) are **desirable, builder's call** on how to make them fair.
- Known pitfalls to handle: Gatekeeper first-launch, warm vs cold caches, ProMotion/vsync, Screen Recording + Accessibility permissions for the harness, background indexing/thermal variance.

### 6.7 Settled after the builder review (my calls — check these)

- **Diff base and "Keep".** Each file's baseline is its content when Alloy first saw it this project-session (on open, or the first time a session touched it). The live diff is baseline → now, split by author. **Keep** marks an edit reviewed and folds it into the baseline, so it leaves the diff and the changed-files list. A **git commit** also resets the baseline for committed files. Edit records, line ownership and baselines **persist across relaunch** in the project's app-support folder (not inside the repo).
- **"Active change" for overlap warnings** = another session's edits that are not yet Kept, plus its proposed changes. Each specific overlap is told to a session **once**; repeated edits to the same region by the same pair don't re-notify unless the region changes again. This is the main noise control for the anti-goal.
- **The user's own typing**: the buffer is the source of truth while focused; it **autosaves after a short pause** (~1 s) and when focus leaves. A "You" edit is recorded and announced to sessions on save, like any other edit. If a session edits a file with unsaved changes, Alloy saves the user's text first, then applies the session's edit on disk and reloads the buffer — the user's typing is never lost.
- **MetalUI dependency**: per the standing rule, gaps G1–G7 go to the MetalUI session now; Alloy builds in parallel and uses only minimal, logged stopgaps (e.g. read-only highlighted `Text` rows for the code view until G1 lands). Phases that need G1 are not blocked on it.
- **Opening files**: any file in the project, through a quick-open (⌘P) and clicking paths in the chat; the sidebar shows changed files. A full file tree is a later addition.
- **One project per window**; each window owns its sessions, its MCP server and its hook endpoint. Several windows may be open.

## 7. Repo and process

- New repo (`Alloy`) (own git repo), MetalUI as a path dependency `../MetalUI`.
- **Create the project with MetalUI's CLI** (user's instruction), not by hand: `swift run --package-path ../MetalUI metalui new Alloy --path <parent dir> --local ../MetalUI` (see `MetalUI/docs/getting-started.md` and `docs/rules/tooling.md`; bundle id via `--bundle-id`, **builder's call**). `Alloy/docs/` already exists holding this spec — if the CLI refuses an existing folder, scaffold to a temporary path and move this `docs/` folder in, rather than hand-writing the package. Further targets (`AlloyKit`, `AlloyBench`) are added to the generated manifest.
- Structure **(builder's call)**, suggested: `AlloyKit` (models, session hosting, attribution, coordination — testable without UI), `Alloy` (app, MetalUI views), `AlloyBench` (benchmark harness), tests using MetalUI's headless `MetalUITesting` for UI.
- MetalUI gaps (G1–G7 and any found later) go to the MetalUI session to implement; Alloy keeps `docs/metalui-gaps.md`.
- Suggested order **(builder's call)**: (1) probe the Claude Code stream/hook/control protocol; (2) session hosting + plain chat; (3) edit records + attribution + changed-files sidebar; (4) rich chat blocks + icons; (5) file panel/code view + diffs + revert; (6) coordination; (7) benchmarks — start the benchmark harness early on Zed/Delta since it doesn't depend on Alloy features.

## 8. Left to the builder

Exact palette values and icon shapes; module layout; edit-record storage format; overlap margin and rate limits; how revert handles fuzz; tree-sitter vs other highlighter (with MetalUI session); how session colors are assigned; persistence format for session list and settings; benchmark harness internals.
