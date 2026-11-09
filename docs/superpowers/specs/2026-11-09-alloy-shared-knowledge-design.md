# Alloy: shared knowledge between sessions (design)

Status: approved by the user (2026-11-09). It extends the Alloy design (`2026-11-07-alloy-design.md`), especially §6.3 (hosting sessions) and §6.5 (coordination: Alloy's MCP server `mcp__alloy__*`).

## 1. Why

Several Claude Code sessions run on one folder, and they keep re-reading files that another session, or the same session, has already read. The user feels this in three ways, all at once:

- **time:** waiting for reads;
- **usage:** tokens counted against the plan's limits;
- **context:** a session's window fills with things the group already knows.

The fix must cut all three.

A session can't see another session's memory, because each is its own `claude` process with its own conversation. So "sharing" means Alloy does one of three things:
- starts a session from a copy of another's conversation (fork);
- tells a session what is already known (an "already read" note);
- answers a session's question from a shared store, so the session doesn't open the file (shared notes).

## 2. Goals

1. **Fork.** Start a new session from a copy of an existing session's conversation, so it begins knowing everything the original read. It is available from a button and from a `/fork` slash command.
2. **"Already read" notes.** When a session is about to work on files that other sessions have read, Alloy adds a short note to the message it sends. The note says who read each file, when, whether it has changed since, and a summary if one exists.
3. **Shared notes.** A tool every session can use to:
   - look up what the group knows about a file or topic before opening it;
   - fetch the **unabridged text, or just a line range**, of a file another session has already read, while that text still matches disk;
   - record a short summary or finding.
4. **Sessions check the notes before reading a file.** This is guidance, not enforcement. Alloy tells every session at launch to check the shared notes first and to leave a short note after reading something important. Writing summaries is part of the session's normal work (user decision).
5. **Measure whether it works.** Alloy counts every read a session made of a file that the notes could have answered (same file, unchanged since it was recorded), and shows the count. If sessions skip the notes, the user sees it and the guidance can be tightened.

## 3. Non-goals

- **Enforcing the check.** No hook blocks or rewrites a session's Read (user decision, 2026-11-09). If a session re-reads anyway, that is allowed; it is counted (goal 5).
- **Automatic summaries made by Alloy.** Alloy never spends usage summarising files on its own (user decision). Summaries come only from sessions' normal work.
- **Sharing the model's memory itself.** Out of reach: the contents still have to arrive in the session's own context. The savings come from fewer tool round trips, snippets instead of whole files, and summaries instead of re-reads.
- **Sharing across projects.** Notes belong to one project folder.

## 4. Anti-goals (failures even if it "works")

- **A session acting on stale knowledge.** Every stored text and summary is tied to the exact file state it describes. Once the file changes, stale full text is never served, and a stale summary is clearly marked stale. A stale answer is worse than a re-read.
- **Permission noise.** A notes tool that asks for approval on every call would be worse than nothing (see §5).
- **Notes that crowd the chat.** "Already read" notes are short (one line per file) and visible but quiet in the UI.
- **Silent behaviour.** The user can always see what was shared with a session and what a session looked up or wrote.

## 5. Constraints

All of the Alloy design's constraints apply. In particular:
- Never write to `~/.claude` or the project's `.claude/`.
- Never pass `--bare`, `--permission-mode` or `--setting-sources`.
- Never brand anything "Claude Code".
- The UI is MetalUI only.
- Theme tokens only.
- Every interactive view gets an accessibility identifier.
- Fixtures are real scrubbed CLI output.
- Zero warnings.

**Permission exception (user decision, 2026-11-09).** Sessions may use Alloy's shared-notes tools **without asking**, unless the user switches on the setting **"Ask before sessions use shared notes"** (off by default). This is a deliberate, narrow exception to "permissions follow the user's Claude settings":
- It covers only Alloy's own notes tools, which read and write nothing but Alloy's notes.
- Every other tool still follows the user's Claude settings exactly.

**Everything per session is passed at launch.** That covers the MCP server config (`--mcp-config`, which `LaunchConfiguration` already supports), the guidance text, and the allow rule for the notes tools. Nothing goes into the user's settings files.

## 6. How it works (decided parts)

### 6.1 Fork

**Entry points:**
- a **"Fork"** item in each session's menu in the sidebar;
- **`/fork`** in the composer;
- `/fork <name>` names the new session.

**Behaviour:**
- It forks from the session's **current point**.
- The new session is named **"<name> (fork)"** and can be renamed.
- It appears next to the original in the sidebar with its own colour, and starts idle, waiting for the user's first message.
- If the source session is **mid-turn**, the fork waits until it is idle, with a small "forking when idle" indicator.
- If the source has **no conversation yet** (never launched, or freshly cleared), the fork action is disabled with a tooltip.

**Mechanism:** the CLI resumes the source conversation as a new one; `--resume <id>` combined with the CLI's fork-session option. The builder confirms the exact flags with a real CLI probe and records the stream-json behaviour in the protocol notes.

**Shared knowledge:** the fork's shared-notes and "already read" state starts as a copy of the source's view. Edits made after the fork are attributed to the fork's own session id, as for any session.

### 6.2 "Already read" notes

**When:** before Alloy sends a user message to a session, it checks for files that:
- (a) the message names (a path, an `@` mention or an attachment), or
- (b) the session itself has read or edited recently. Tabs are not used here, because they belong to the whole workspace, not to a session.

It notes only files that **another** session has read. Files the session read itself are never noted.

**Told once (my call):** a file is noted to a session once. It is noted again only when the file's state or its summary changes. This "already told" state is kept per session, persisted, and copied when a session is forked.

**Content:** one line per file:
```
src/Workspace.swift — read by "auth refactor" at 14:02, unchanged since. Summary: <summary if one exists>.
```
or
```
— read by … at 14:02, changed since (by you / by "auth refactor" / outside Alloy).
```

**How it is sent:**
- It is added to the message as a short, clearly separated context block.
- It is capped: at most N files (builder's call, starting around 8), and well under 2k characters in total.
- The note never contains full file text. The session asks the shared notes for text if it needs it.

**UI:** a small chip on the user's message bubble ("shared: 3 files") that expands to show exactly what was added.

### 6.3 Shared notes (MCP tools)

These are part of Alloy's MCP server (`mcp__alloy__*`, design §6.5). Names are the builder's call; these are the capabilities.

**`notes_lookup(path or topic)`** returns:
- for a file:
  - who has read it and when;
  - whether its text can be served, meaning the file is unchanged since a session read it;
  - every summary or finding recorded for it, each marked **current** or **stale**;
- for a topic: matching findings.

**`notes_read(path, lines?)`** returns the **unabridged text**, or the given line range, of a file a session has read. It succeeds only when the file is unchanged since that read. Otherwise it says the file changed and the session should read it fresh.

**`notes_write(path or topic, text)`** records a summary or finding.
- It is tied to the file's state at the time: the ledger version and disk stamp.
- It has a size cap (builder's call, around 1–2k characters).
- It is attributed to the writing session.

**Where the text comes from (my call, after the builder check):**
- Alloy keeps no copy of file contents.
- It keeps a small **read index**: which session read which file (and which line ranges), when, and the file's stamp at that moment.
- `notes_read` reads the file **fresh from disk, off the main thread**. It serves the text only when the current stamp equals the stamp recorded at the session's read.
- `notes_read` serves only files some session has read. Alloy never volunteers files no session has opened.
- Files above 1 MB, and binary files, are noted but never served.

**Staleness:**
- Every read-index entry and note carries the file stamp (inode, size, mtime, ctime: Alloy's `FileStamp`) and the ledger version it describes.
- On any change Alloy sees (watcher, save, session edit), the file's read-index entries stop serving text and its notes are marked stale. Stale notes are kept, shown as stale, and cleared after some time (builder's call).

**Persistence:** per project, kept with Alloy's other per-project data, and surviving restarts. On reopen, every entry is checked against the current disk stamp before it is used.

### 6.4 Guidance at launch

Every session Alloy launches gets a short, fixed instruction appended to its system prompt (the CLI's append-system-prompt flag; the builder confirms it with a probe). The instruction says:
- before reading a file, check the shared notes;
- if the notes hold current text, use it, or ask for only the lines you need;
- after reading a file you'll rely on, record a one-to-three-sentence summary;
- treat stale notes as hints only.

The exact wording is the builder's call. Keep it under about 150 words, and never brand it "Claude Code".

### 6.5 Measuring (goal 5)

- **A "redundant read"** (my call) is a Read by a session, or by a subagent inside it, of a file whose read-index entry or note was current at that moment.
  - The session's own earlier reads count.
  - Reads made after the session's context was compacted, after its last compaction boundary, do **not** count: re-reading then is legitimate.
  - A fork inherits its source's reads.
- **Counts:** per session and per project.
- **Where it shows:**
  - in the session's stats, next to tokens and cost (design §6.3, item 9);
  - as a small "notes saved / reads skipped the notes" line in the sidebar footer, or in session details (builder's call).
- **No nagging:** it is never shown as a warning.

### 6.6 Settings

**Settings view (user request, 2026-11-09):** the gear button in the sidebar footer stops opening the small "Path to claude" popover. Instead it opens a proper **Settings view** that holds every app-wide setting:
- the Claude path, with Detect and Save;
- the two toggles below;
- future app-wide settings as they arrive.

Per-session controls (model, permission mode) stay where they are. The builder chooses the form: a separate settings window, or a full-panel view with a close button. Existing settings ids are kept or remapped in the tests.


- **"Ask before sessions use shared notes"**: off by default. When on, the notes tools follow the user's normal permission flow, and permission cards appear.
- **When a setting changes (my call):** running sessions pick up the change at their next idle point. Alloy relaunches each one in place with `--resume`, the same mechanism dormant sessions already use, and shows a small "settings applied" notice in that session's chat.
- **"Share knowledge between sessions"**: a master switch, on by default. Off disables:
  - the notes tools;
  - "already read" notes;
  - the launch guidance.

  Fork stays available.

## 7. Order and sizing

**User decision (2026-11-09):** shared knowledge merges into **Plan 5 (Coordination)**. It uses Coordination's Alloy MCP server, its launch-time configuration and its told-once rule. Within Plan 5, shared knowledge is built first. Plan 5 starts after the user's hands-on checks of Plans 3–4.

Suggested order inside Plan 5:
1. Probe the CLI's fork and append-system-prompt flags.
2. Build Alloy's MCP server, which shared knowledge and Coordination both use.
3. The read index and staleness.
4. The notes tools.
5. "Already read" notes.
6. Fork (button and `/fork`).
7. Launch guidance and settings, including applying changes at idle.
8. Count redundant reads.
9. Then Coordination's own scope, as in the roadmap.

## 8. Left to the builder

- Exact MCP tool names and schemas.
- The note cap.
- Where stale notes expire.
- The exact guidance wording.
- Where the redundant-read count appears.
- How the "forking when idle" indicator looks.

All within the decisions above.
