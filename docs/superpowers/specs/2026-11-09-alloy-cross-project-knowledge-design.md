# Alloy: shared knowledge across projects (design)

Status: approved by the user (2026-11-09), with "Share with other projects" on by default (user decision). It extends the shared-knowledge design
(`2026-11-09-alloy-shared-knowledge-design.md`, "5a") and lifts its non-goal "Sharing across projects".

## 1. Why

Alloy opens one project per window. Sessions in one window already share what they have read (notes, "already read"
lines, redundant-read counts). Sessions in different windows share nothing, because each project keeps its own store.

The user works on several repositories at once, sometimes with one session per repo, and wants every session to
benefit from sharing either way (user decision: "a notes store shared across projects: each repo keeps its own window,
but what sessions have read is pooled").

Sharing across repos pays off where the work crosses repos: a session in `app` reads `api/Routes.swift`, which a
session in the `api` window already read and summarised, or two windows need the same topic note ("auth flow").

## 2. Goals

1. **One pool per Mac.** Shared notes (file notes and topics) and the read records behind "already read" and the
   redundant-read count are pooled across every project Alloy has opened on this Mac.
2. **Cross-repo lookups.** A session can look up, read from and write notes about a file in another known project,
   by absolute path or by the path it already uses.
3. **Cross-repo "already read".** When a session names, or has recently worked on, a file in another known project
   that a session in any window has read, it gets the usual one-line "already read" entry, marked with that project.
4. **Live across windows.** A note written in one window is visible to sessions in every other open window on their
   next lookup or message, without a relaunch.
5. **Counted.** A read of another project's file that the pool could have answered counts as a repeat read, as today.

## 3. Non-goals

- Pooling sessions, the edit ledger, claims, overlap/tug-of-war warnings or session messages. Each project keeps its
  own (user decision).
- Sharing across Macs, or between two clones of one repository (a clone is a different folder with different file
  states; notes are tied to exact file states).
- Granting file access. Whether a session may read a file outside its own folder stays with the user's Claude
  settings; Alloy only answers from what was already read.
- A notes browser UI.

## 4. Anti-goals

All 5a anti-goals still hold: no stale text served, stale summaries clearly marked, no permission noise, quiet chat,
nothing silent. Added:
- **Leaking unrelated folders.** The pool only covers files under folders the user opened as projects in Alloy.
  Anything else is still refused.
- **Losing notes when two windows write at once.** Concurrent writers must never overwrite each other.

## 5. Decisions

These are my calls unless marked as the user's; the user approves them with this document.

- **Keying: absolute real path.** File notes and read records are keyed by the file's real (symlink-resolved)
  absolute path. Stamps (mtime, size, inode, ctime) are only meaningful on one Mac, which is the scope. Shown to
  sessions and in the UI as `<project name>/<relative path>` (project name = folder name) when the file is in another
  project, and as the plain relative path when it is in the session's own project, as today.
- **Topics are pooled.** One topic namespace for all projects; each topic note records the project it was written
  from, shown as "(from api)" when that differs from the reader's project.
- **Known projects.** A registry of every project root Alloy has opened (already implied by the per-project store
  folders). The notes tools accept a path under the session's project or under any known project root; anything else
  gets today's "outside" refusal. A known project whose folder no longer exists simply has no current notes.
- **Authors.** Notes and reads store the writing session's name and project name at write time, so another window can
  say "read by Retry (in api)". Sessions in the reader's own window keep resolving their live name, as today.
- **Store: one SQLite database** at `<appSupport>/Alloy/Shared/knowledge.sqlite` using the macOS system SQLite
  (`import SQLite3`, no new package dependency), WAL mode with a busy timeout. Every lookup, "already read" build and
  repeat-read check queries it, so another window's writes are seen without file watching. Writes are single-row
  inserts or updates, so two windows never overwrite each other's work. The in-memory note and read caches stop being
  authoritative.
- **What stays per project:** `told.json` (who was already told what), sessions, ledger, claims and the other
  coordination files keep their current per-project location.
- **Migration.** On first launch with the pool, each project's existing `notes.json` and `reads.json` are imported
  into the database when that project opens (relative paths become absolute under its root), then renamed
  `*.imported` and left in place.
- **Setting: "Share with other projects"**, a switch under "Share knowledge" in Settings, **on by default** (user decision), inactive
  when "Share knowledge" is off. Off means this project's sessions only see and count entries from their own project,
  and what they write is kept to their own project. Changing it relaunches sessions like the other knowledge switches.
- **Guidance** (system prompt addition) gains one line: notes also cover files in the user's other Alloy projects;
  use `notes_lookup` with the absolute path before reading a file from another repo.
- **README**, once it ships and is checked: several sessions in one repo, or one session per repo in several windows,
  all share what they have learned; across repos the benefit shows when work touches the other repo's files or a
  shared topic.

## 6. Left to the builder

Schema and indexes; the exact candidate rule for out-of-project files in the "already read" block (same cap of 50
named + 20 recent); how expiry runs against the shared database (once per window launch and on a timer is fine); the
wording of marked lines, within the existing one-line style; test layout.

## 7. How it is checked

- Two `Workspace`s on different roots sharing one app-support folder (two windows in one test process): a note and a
  read in one are visible to the other's lookup, "already read" block and repeat-read count, marked with the project.
- Two separate database connections writing concurrently lose nothing.
- A path outside every known project is still refused; a dangling symlink and a project-root path still refused.
- Migration imports 5a stores once and is idempotent.
- The switch off isolates a project both ways.
- Stale handling unchanged: change the file in one window, the other window's lookup marks the note stale and never
  serves the old text.
- A live check with two real Alloy processes on two scratch repos.
