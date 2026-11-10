# Alloy

Alloy is a native macOS code editor built around LLM sessions. It hosts several [Claude Code](https://claude.com/claude-code)
CLI sessions on a project folder at the same time, shows every change each session makes as a live diff attributed to
that session, and lets the sessions share what they have already read.

You are not limited to one repository at a time: each Alloy window holds one project, and you can run several windows
side by side, one per repository, each with its own sessions, diffs and history.

It is built on [MetalUI](https://github.com/mburger89/MetalUI), a GPU-rendered Swift UI framework.

![Alloy with two Claude Code sessions, Retry and Averages, on one project: the chat shows an edit diff and the code panel shows Forecast.swift with each session's changes marked in its own colour](docs/images/alloy-hero.png)

## Why

Running more than one agent on a project works until you cannot tell who changed what, and until each agent re-reads
the same files. Alloy is an editor designed around that situation:

- Every character in a file is attributed to the session that wrote it, to you, or to an outside change.
- Several sessions in one repository, or one session per repository in separate windows, all share what they have learned, so the next session does not start from zero. Across repositories the benefit shows when work touches another repository's files or a shared topic; "Share with other projects" in Settings turns the cross-project part off.
- Chat is a first-class surface (tool blocks, diffs, plans, questions), not a terminal.

## Status

An early-stage personal project. macOS only for now. Expect rough edges and changing internals.
Coordination between sessions is implemented; its hands-on check in the app is still pending.

## Features

Sessions and chat
- Several concurrent sessions, each its own `claude` process, with streaming chat, collapsible thinking, tool blocks
  that show input and result, permission cards, and interrupt.
- Question cards (answer and send) and plan cards (approve, or send back with feedback).
- Markdown replies with headings, lists, tables and syntax-highlighted code fences with a Copy button.
- Composer with `@file` and slash-command autocomplete, image paste and drop, queued sends (steer or queue while a
  session is busy), and mode and model controls.
- Slash commands, handled by Alloy or passed to the CLI; see [docs/slash-commands.md](docs/slash-commands.md).
- Session rename, details view, fork (`/fork [name]`), and history replay when a session is resumed.
- Sessions and the edit ledger persist per project. After a relaunch sessions show as "Paused" and resume on the next
  message.

Editing and diffs
- Editable code panel with tree-sitter highlighting, tabs, quick-open (Cmd-P), find, save and autosave. Large and
  non-UTF-8 files open read-only.
- A per-file edit ledger with author gutter bars and tints, removed lines shown inline, and Keep and Revert per edit.
- Side-by-side diff with synchronized scrolling.

  ![Side-by-side diff of Forecast.swift: the old text on the left, the new text on the right, with edits marked by session colour](docs/images/alloy-side-by-side.png)

*Side by side: the file before and after the sessions' edits, scrolling together.*
- Edits by other programs show as "outside"; changes made by a session's Bash command are attributed to that session.
  `git commit` clears the reviewed files' baseline.
- If a session changes a file while you have unsaved edits, the changes are merged.

Shared knowledge (on by default)
- A loopback MCP server gives each session three tools, `notes_lookup`, `notes_read` and `notes_write`, backed by an
  index of the files each session has read.
- When a message names a file another session has read, Alloy adds a short quoted "Shared by other sessions" block
  saying whether the file changed since. Note text is marked as written by another session and treated as a hint.
- Redundant-read counts per session and per project; a Settings view with the `claude` path and sharing switches.

![A chat message with its "shared: 1 file" chip expanded to the exact note text Alloy added from another session's read](docs/images/alloy-shared-knowledge.png)

*The "shared: 1 file" chip, expanded: exactly what Alloy told this session about a file another session had read.*

Coordination between sessions
- Overlap warnings, which never block. Alloy registers PreToolUse and PostToolUse `http` hooks (for Edit, Write,
  MultiEdit and NotebookEdit) on its loopback server. When a session is about to change lines that another session (or
  you, with unsaved typing) has changed or is changing, within three lines, the hook answers with a short note that the
  CLI hands to the model (`additionalContext`) and the edit goes ahead. Each overlap is told once per session (again
  after a compaction), and also appears as a notice in the chats involved.
- Four more tools next to the notes tools: `sessions_changes` (what the other sessions are doing: files, lines,
  claims), `send_message` (a short message to another session by name), and `claim_region` / `release_region`. A claim
  is a hint, not a lock: it shows in other sessions' overlap notes and ends ten minutes after its owner last edited
  the file.
- Messages between sessions arrive as the other session's next input and show in its chat as a "From" row. Limits: 5
  per minute between two sessions (both directions together) and 10 per minute per session; the sender is told when
  a limit is hit. No session can be named "Alloy", so "From Alloy" is never a session.
- Tug-of-war detection: when two parties change the same lines back and forth (A, then B, then A within ten minutes),
  Alloy raises an alert, tells the session that just edited to leave those lines and move on (a message from Alloy
  itself), and escalates the alert once if that session edits them again. Alerts are not saved across a restart.
- Warnings in the UI: a mark on the affected sessions and files in the sidebar, and a notice above the chat. They clear
  when the edits are kept, reverted or committed, and after ten minutes without activity; a dismissed warning stays
  dismissed unless it escalates.
- Settings: "Ask before sessions use Alloy's tools" covers all seven Alloy tools.

## Themes

Alloy ships six built-in themes: Dracula (the default), Alloy Dark, Alloy Light, Solarized Dark, Solarized Light and
One Dark. Pick one in Settings (the gear in the sidebar): "One theme" uses a single theme always, "Match system"
uses a light and a dark theme that follow the system appearance. A pick repaints at once and never touches your
sessions.

Your own themes are `*.json` files in the user themes folder, which Alloy watches, so an edit applies live:

- `~/Library/Application Support/Alloy/Themes`
- or `$ALLOY_DATA_DIR/Alloy/Themes` when `ALLOY_DATA_DIR` is set

"Open themes folder" in Settings opens it. The file format and every colour slot are in [docs/themes.md](docs/themes.md).
Making themes with Claude (`/theme`) is coming later.

## Requirements

- macOS 14 or later.
- Swift 6.1 or later (Xcode 16.3 or later).
- A sibling checkout of MetalUI at `../MetalUI` (`Package.swift` depends on it by path):

  ```sh
  git clone https://github.com/mburger89/MetalUI.git ../MetalUI
  ```

- The [Claude Code](https://claude.com/claude-code) CLI installed and logged in. Alloy runs your installed `claude`
  with your existing login; permissions follow your own Claude Code settings. If `claude` is not found, set
  `ALLOY_CLAUDE_PATH` or `claudePath` in `~/Library/Application Support/Alloy/settings.json`.

## Build, run and test

```sh
swift build -c release
.build/release/Alloy <project-dir> [file]
swift test
```

- `<project-dir>` is the project; `file` (optional) opens in the code panel at launch. With no arguments Alloy reopens
  the last project, or asks for a folder. `/` and your home folder itself are never accepted as a project.
- To work on several repositories at once, launch Alloy once per repository (for example
  `.build/release/Alloy ~/src/app &` and `.build/release/Alloy ~/src/api &`). Each window keeps its own sessions,
  edit ledger and shared notes; the projects do not interfere with each other. The folder need not be a git repository.
- The tests never launch the real `claude`. Opt-in live tests drive the real CLI against a scratch repository in your
  temporary directory and cost real (small) API usage, on the cheapest model:

  ```sh
  ALLOY_LIVE=1 swift test --filter LiveKnowledgeTests
  ALLOY_LIVE=1 swift test --filter LiveCoordinationTests
  ```

- The absolute timing bounds of `OverlapIndexTests` (the relative ones always run) need `ALLOY_PERF=1`, on a quiet
  machine: `ALLOY_PERF=1 swift test --filter OverlapIndexTests`.

- To package an app bundle: `scripts/bundle-macos.sh` produces `build/Alloy.app`, signed ad hoc (bundle id
  `dev.alloy.Alloy`). Put a 1024 x 1024 `Packaging/icon-1024.png` in place first for an icon; set
  `CODESIGN_IDENTITY` to sign for distribution.

## Benchmarks

`Bench/` is a separate Swift package that compares typing latency, startup, large-file open, scrolling and memory
for Alloy against Zed and Delta. It only drives apps it launched itself, refuses to run if Zed or Delta is already
open, and never edits their settings. It needs Screen Recording and Accessibility permission and a quiet machine; see
[Bench/README.md](Bench/README.md). Unit tests: `swift test --package-path Bench`.

## Privacy and permissions

- Alloy never writes to `~/.claude` or to the project's `.claude/` directory. It reads the CLI's own transcript
  files to replay history. Its own state lives in `~/Library/Application Support/Alloy`.
- The hooks and tools are passed to each `claude` process on its command line (`--settings`, `--mcp-config`), never
  written to a settings file. Your own hooks and settings keep running beside them. A hook that fails or times out
  never blocks a tool call.
- Alloy's tool and hook server listens on 127.0.0.1 only, on an ephemeral port, and every session has its own random
  bearer token.
- The only tools pre-approved (`--allowedTools`) are Alloy's seven: the three notes tools and the four coordination
  tools (`sessions_changes`, `send_message`, `claim_region`, `release_region`). Turn on "Ask before sessions use
  Alloy's tools" in Settings to disable that pre-approval. Everything else follows your Claude Code permission settings and
  asks through permission cards.

## Project layout

- `Sources/AlloyCore`: UI-free logic (wire protocol, `claude` process, sessions, edit ledger, shared knowledge, local
  tool server, `Workspace`).
- `Sources/AlloyKit`: the MetalUI views and launcher model.
- `Sources/AlloyHighlight`: tree-sitter highlighting.
- `Sources/Alloy`: the executable entry point.
- `Sources/AlloyTestSupport`: test doubles shared by the test targets.
- `Tests/`: protocol, process, ledger and workspace tests, plus UI tests driven in a headless window through
  MetalUI's `MetalUITesting`.
- `Bench/`: the benchmark package.
- `tools/ccprobe`: protocol probe scripts; `scrub.py` anonymises recorded fixtures.
- `Packaging/`, `scripts/`: app bundle packaging.

## Docs

- [docs/slash-commands.md](docs/slash-commands.md): how slash commands are routed.
- [docs/protocol-notes.md](docs/protocol-notes.md), [plan 3](docs/protocol-notes-plan3.md),
  [plan 5](docs/protocol-notes-plan5.md): verified behaviour of the `claude` stream-json protocol.
- [docs/metalui-gaps.md](docs/metalui-gaps.md), [docs/metalui-code-api.md](docs/metalui-code-api.md): MetalUI gaps
  and the code-view API Alloy uses.
- [docs/superpowers/specs](docs/superpowers/specs) and [docs/superpowers/plans](docs/superpowers/plans): the design
  specs and implementation plans, kept as a record of how the project was built.

## License

MIT. See [LICENSE](LICENSE).
