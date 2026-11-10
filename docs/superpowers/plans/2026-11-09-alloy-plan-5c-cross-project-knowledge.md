# Plan 5c: Shared Knowledge Across Projects, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pool shared notes and read records across every project Alloy has opened on this Mac, so sessions in different windows benefit from each other's reads, while sessions, ledger, claims and told-state stay per project.

**Architecture:** A new `KnowledgePool` (system SQLite, WAL) at `<appSupport>/Alloy/Shared/knowledge.sqlite` stores one row per note and one row per (session, file) read group, keyed by absolute real paths, so concurrent windows never overwrite each other. Each `Workspace` keeps `notes: NotesStore` and `readIndex: ReadIndex` as in-memory *views*: own-project files keep their relative keys, other projects' files use their absolute path as the key. Views reload when the pool's `data_version` changes; local mutations are diffed and written to the pool, so existing callers barely change.

**Tech Stack:** Swift 6, `import SQLite3` (macOS system library, no new package), MetalUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-09-alloy-cross-project-knowledge-design.md` (extends `2026-11-09-alloy-shared-knowledge-design.md`, "5a").

## Global Constraints

- Never write to `~/.claude` or the project's `.claude/`. Never pass `--bare`, `--permission-mode` or `--setting-sources`. Never brand anything "Claude Code".
- UI is MetalUI only; theme tokens only (ThemeGuardTests); every interactive view has an accessibility identifier.
- Zero warnings. No new package dependency (`SQLite3` is the system module).
- Pooled: notes (file and topic) and read records. Per project, unchanged location: `told.json`, sessions, ledger, claims, overlap files.
- The pool covers files under folders opened as projects in Alloy only; anything else gets today's refusal.
- Setting "Share with other projects": `AlloySettings.shareAcrossProjects`, default **true** (user decision), only active when `shareKnowledge` is on. It is an app-wide setting; off = every window sees and counts only entries written from its own project.
- Stale handling, limits and expiry are 5a's: `NotesStore.noteLimit` 2000 chars, 20 per subject, 200 topics (now pool-wide), stale notes expire 7 days after `staleSince`.
- Commit trailers on every commit:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` plus the Claude-Session line given in the dispatch. Never put the session URL in a tracked file.
- Tests never launch the real `claude` except the opt-in live test (Task 6), on the cheapest model.

## Review Focus

1. **Same folder by two spellings** (a symlinked path vs its real path, `/tmp` vs `/private/tmp`): one project, one set of keys. Test in Task 2.
2. **Nested projects** (`~/src` and `~/src/api` both opened): a file belongs to the deepest known root, except that the session's own root always wins for files under it. Test in Task 2.
3. **Pool unavailable** (unwritable folder, corrupt database file, locked past the busy timeout): reported once in the window's errors; the corrupt file is moved aside as `knowledge.sqlite.corrupt-<ts>` and a fresh pool starts; the editor keeps working on its in-memory view. Tests in Tasks 1 and 3.
4. **Two projects with the same folder name** (`work/app`, `personal/app`): displayed names are disambiguated with the parent folder. Test in Task 2.
5. **A known project deleted or moved**: its notes are never served as current (missing file is stale), nothing crashes, lookups for paths under the vanished root are refused. Test in Task 3.

---

### Task 1: KnowledgePool (SQLite store)

**Files:**
- Create: `Sources/AlloyCore/Knowledge/KnowledgePool.swift`
- Modify: `Sources/AlloyCore/Knowledge/NotesStore.swift` (`Note`), `Sources/AlloyCore/Knowledge/ReadIndex.swift` (`ReadEntry`)
- Test: `Tests/AlloyCoreTests/KnowledgePoolTests.swift`

**Interfaces:**
- Produces:
  - `Note` gains `public var authorName: String?` and `public var project: String?` (writer's real project root); `ReadEntry` gains the same two. Both decode leniently (absent → nil), so 5a files still load.
  - `public struct KnownProject: Sendable, Equatable { public var root: String; public var name: String }` (root is a real path, name its last component).
  - `public final class KnowledgePool: @unchecked Sendable` with one SQLite connection guarded by a private serial `DispatchQueue`:
    - `public init(url: URL, onError: @escaping @Sendable (String) -> Void) throws`: creates the folder, opens with `SQLITE_OPEN_FULLMUTEX`, `PRAGMA journal_mode=WAL`, `busy_timeout=5000`, creates schema v1 (`PRAGMA user_version = 1`). A file that is not a valid database is moved aside as `knowledge.sqlite.corrupt-<unix ts>` (with `-wal`/`-shm`), `onError` is told, and a fresh one is created.
    - `public func register(_ project: KnownProject)`; `public func knownProjects() -> [KnownProject]`
    - `public func dataVersion() -> Int64` (`PRAGMA data_version`)
    - `public func loadNotes() -> [Note]`; `public func loadReads() -> [ReadEntry]` (file paths absolute)
    - `public func upsert(notes: [Note])`; `public func delete(noteIDs: [UUID])`
    - `public func replaceReads(session: UUID, path: String, with entries: [ReadEntry])` (empty deletes the group)
    - `public func isImported(_ root: String) -> Bool`; `public func markImported(_ root: String)`
    - Reads run with `queue.sync`; writes run with `queue.async` inside a transaction (`BEGIN IMMEDIATE`), so a later read on the same pool sees every earlier write. Failures go to `onError`. `public func flush()` waits for queued writes (tests, shutdown).
  - Schema: `notes(id TEXT PRIMARY KEY, key TEXT NOT NULL, project TEXT, body BLOB NOT NULL)` with index on `key`; `reads(session TEXT, path TEXT, project TEXT, body BLOB NOT NULL, PRIMARY KEY(session, path))`; `projects(root TEXT PRIMARY KEY, name TEXT, imported INTEGER DEFAULT 0)`. `body` is the JSON of the `Note` / `[ReadEntry]`. `key` is the absolute path for file notes and `topic:<topicKey>` for topics.

- [ ] **Step 1: Write the failing tests** in `KnowledgePoolTests` (each test uses its own temporary folder):
  - `notesRoundTrip`: upsert two notes (one file, one topic) → `loadNotes()` returns both, equal; `delete(noteIDs:)` one → one left.
  - `readsReplaceGroup`: `replaceReads(s, "/r/a.swift", [e1, e2])` then `replaceReads(s, "/r/a.swift", [e3])` → `loadReads() == [e3]`; replacing with `[]` empties it.
  - `twoConnectionsLoseNothing`: two `KnowledgePool`s on one file; 200 notes upserted from each concurrently (`withTaskGroup`), `flush()` both → a third pool loads 400.
  - `dataVersionMovesOnOtherWriter`: pool A reads `dataVersion()`, pool B upserts + flushes → A's `dataVersion()` differs; A's own write does not need to change it.
  - `registryIsIdempotent`: registering one root twice → one `KnownProject`; `markImported` → `isImported` true, other roots false.
  - `corruptFileIsMovedAside`: write `"not a database"` to the file → init succeeds, `onError` called once with a message containing `corrupt`, a `knowledge.sqlite.corrupt-*` file exists, new pool is empty and usable.
  - `fiveANotesDecode`: a 5a `Note` JSON without `authorName`/`project` decodes with both nil.
- [ ] **Step 2: Run** `swift test --filter KnowledgePoolTests`. Expected: fails to compile (no `KnowledgePool`).
- [ ] **Step 3: Implement** `KnowledgePool` and the two model fields as specified.
- [ ] **Step 4: Run** `swift test --filter KnowledgePoolTests` and `swift test --filter NotesTools` → PASS.
- [ ] **Step 5: Commit** `feat(knowledge): KnowledgePool, a SQLite store shared across projects`.

### Task 2: Knowledge keys across known projects

**Files:**
- Create: `Sources/AlloyCore/Knowledge/KnowledgeScope.swift`
- Modify: `Sources/AlloyCore/Knowledge/NotesTools.swift` (`NotePath.resolve`, `openChecked`, the "outside" message), `Sources/AlloyCore/Knowledge/SharedContext.swift` (`prepareCandidates`)
- Test: `Tests/AlloyCoreTests/KnowledgeScopeTests.swift`, existing `NotesToolsTests`, `AlreadyReadTests`

**Interfaces:**
- Consumes: `KnownProject` (Task 1).
- Produces: `public struct KnowledgeScope: Sendable, Equatable`:
  - `public init(ownRoot: String, known: [KnownProject])`: `ownRoot` real path; `known` may include it.
  - `public func key(forReal path: String) -> String?`: relative path if strictly under `ownRoot`; else the absolute path if strictly under some other known root (deepest wins); else nil. A root itself is nil.
  - `public func absolute(_ key: String) -> String`: keys starting with `/` are absolute; others are `ownRoot + "/" + key`.
  - `public func root(ofKey key: String) -> String?` and `public func display(_ key: String) -> String`: own keys unchanged; other keys as `<project label>/<relative>`.
  - `public func label(ofRoot root: String) -> String`: the folder name, or `<parent>/<name>` when two known projects share the folder name.
  - `NotePath.resolve(_ raw: String, root: URL, scope: KnowledgeScope) -> NotePath?`: as today, but accepts a target under any root in the scope; `relative` is the scope key, `root` is the containing project's real root. A relative `raw` is still joined to the session's own root. The old 2-argument form calls it with a scope of only the own root.
  - The refusal text becomes: `"\(raw) is outside your Alloy projects; the notes tools only cover files under folders opened in Alloy."`
  - `prepareCandidates(message:recent:root:scope:)`: the lexical pre-check accepts any scope root form; candidates are scope keys.

- [ ] **Step 1: Write the failing tests** in `KnowledgeScopeTests` (real temp folders `own`, `api`, nested `own/vendor/lib` registered as its own project, and a symlink):
  - `ownFileKeepsRelativeKey`: `key(forReal: own/Sources/a.swift) == "Sources/a.swift"`.
  - `otherProjectFileUsesAbsoluteKey`: `key(forReal: api/Routes.swift) == "<real api>/Routes.swift"`; `display` of it `== "api/Routes.swift"`.
  - `outsideEveryProjectIsNil`: a file in an unregistered temp folder → nil; a known root itself → nil.
  - `symlinkSpellingIsOneProject`: scope built from `/tmp/...`-style path resolves a `/private/tmp/...` file to the same key (Review Focus 1).
  - `deepestRootWinsButOwnRootFirst`: with own = `own` and known `own/vendor/lib`, a file under `own/vendor/lib` keys relative to own; with own = `api`, the same file keys absolute and `root(ofKey:)` is `own/vendor/lib` (Review Focus 2).
  - `sameFolderNamesAreDisambiguated`: known `work/app` and `personal/app` → labels `work/app` and `personal/app`; a unique name stays bare (Review Focus 4).
  - In `NotesToolsTests`: `lookupAcceptsOtherKnownProject` (resolve with scope returns the absolute key) and `refusalNamesAlloyProjects` (an unregistered path → the new refusal text).
- [ ] **Step 2: Run** `swift test --filter "KnowledgeScopeTests|NotesToolsTests"` → new tests fail.
- [ ] **Step 3: Implement** `KnowledgeScope`, the new `NotePath.resolve`, the refusal text and `prepareCandidates`. `openChecked` checks `F_GETPATH` against the `NotePath.root` it was given (the containing project), not the session's root.
- [ ] **Step 4: Run** `swift test --filter "KnowledgeScopeTests|NotesToolsTests|AlreadyReadTests"` → PASS.
- [ ] **Step 5: Commit** `feat(knowledge): keys for files in other Alloy projects`.

### Task 3: Workspace on the pool

**Files:**
- Modify: `Sources/AlloyCore/Model/AlloySettings.swift`, `Sources/AlloyCore/Model/Workspace.swift` (init, `ensureLoaded`, `persistNotes`, `persistReads`, `updateSettings`, shutdown), `Sources/AlloyCore/Knowledge/NotesTools.swift` (`noteFileChanged`, `lookupFile`, `addNote`), `Sources/AlloyCore/Knowledge/ReadIndex.swift` (`trackReads`, `judgeRead`)
- Create: `Sources/AlloyCore/Knowledge/Workspace+Pool.swift`
- Test: `Tests/AlloyCoreTests/CrossProjectKnowledgeTests.swift`, existing knowledge tests

**Interfaces:**
- Consumes: `KnowledgePool`, `KnowledgeScope`, `NotePath.resolve(_:root:scope:)`.
- Produces:
  - `AlloySettings.shareAcrossProjects: Bool` (default `true`, `decodeIfPresent`, CodingKey `shareAcrossProjects`). `updateSettings` treats a change of it as a launch-options change (relaunch when idle).
  - `Workspace.pool: KnowledgePool?` opened at `<appSupport>/Alloy/Shared/knowledge.sqlite` on first `ensureLoaded`; nil (with one reported error) if it cannot open, in which case knowledge stays in memory for this run.
  - `Workspace.knowledgeScope: KnowledgeScope` (own real root + `pool.knownProjects()`), refreshed with the view.
  - `func refreshKnowledge()`: when `pool.dataVersion()` changed since the last load, rebuilds `notes` and `readIndex` from the pool: own-root paths → relative keys, other known roots → absolute keys, anything else dropped; with `shareAcrossProjects` off (or `shareKnowledge` off) only rows whose `project` is the own root. Called at the start of `lookupFile`, the topic lookup, `notes_read`, `sharedContext`, `judgeRead`, and `addNote`.
  - `persistNotes()` / `persistReads()` keep their names and call sites but write diffs: notes by id against the last synced set (upsert changed, delete removed); reads by `(session, absolute path)` group. New notes and reads are stamped with `authorName` (the session's name) and `project` (own real root) and stored with absolute paths.
  - Compaction generations move from `reads.json` to `<storeDirectory>/generations.json`.
  - Migration in `ensureLoaded`: if `!pool.isImported(ownRoot)`, existing `notes.json` / `reads.json` are imported (relative → absolute under the own real root, `project` = own root, `authorName` from the session records or nil), generations written to `generations.json`, the files renamed `notes.json.imported` / `reads.json.imported`, then `markImported`. Runs once; a second open imports nothing.
  - The workspace registers its own project (`KnownProject(root: real root, name: last component)`) on first load.
  - `noteFileChanged(_ key:)` reads the stamp at `knowledgeScope.absolute(key)`.

- [ ] **Step 1: Write the failing tests** in `CrossProjectKnowledgeTests` (two `Workspace`s on two temp project roots sharing one temp appSupport, each with its own pool connection, standing in for two windows):
  - `noteInOneWindowIsSeenInTheOther`: A adds a note on its `Routes.swift`; B's `lookupFile` for A's absolute path lists the note, marked current, without reopening B.
  - `readInOneWindowCountsAsRepeatInTheOther`: A records a whole-file read of `Routes.swift`; B judges a Read of the same absolute path → B's `redundantReads == 1`.
  - `staleAcrossWindows`: after A's note, the file changes on disk → B's lookup shows it `[stale]` and `notes_read` from B serves no text.
  - `switchOffIsolatesBothWays`: with `shareAcrossProjects = false` in both, A's note is not visible in B, B's note not in A; each still sees its own.
  - `migrationImportsOnce`: a 5a-style `notes.json` + `reads.json` in A's store → after open, notes visible in B; files renamed `.imported`; reopening A adds no duplicates (`pool.loadNotes().count` unchanged).
  - `vanishedProjectIsHarmless`: A writes a note, A's folder is deleted → B's lookup of the old path is refused or stale, never current, no crash (Review Focus 5).
  - `unwritablePoolReportsOnceAndKeepsWorking`: appSupport `Alloy/Shared` made a regular file → workspace opens, exactly one error mentions shared knowledge, `addNote` + `lookupFile` work in memory (Review Focus 3).
  - Existing `NotesToolsTests`, `AlreadyReadTests`, `ReadIndexTests`, `KnowledgeLaunchTests`, `ForkTests` stay green unchanged except for files that assert on `notes.json` / `reads.json` contents, which move to pool assertions.
- [ ] **Step 2: Run** `swift test --filter CrossProjectKnowledgeTests` → fail.
- [ ] **Step 3: Implement** as specified. Keep the per-project files (`told.json`, `claims.json`, `overlapTold.json`, `sessions.json`, ledger) untouched.
- [ ] **Step 4: Run** the full `swift test` → PASS (known flake: `CoordinationWarningsTests.aDeniedProposalClearsItsWarning`, rerun alone).
- [ ] **Step 5: Commit** `feat(knowledge): workspaces share notes and reads through the pool`.

### Task 4: Telling sessions about other projects

**Files:**
- Modify: `Sources/AlloyCore/Knowledge/AlreadyRead.swift`, `Sources/AlloyCore/Knowledge/NotesTools.swift` (`name(of:)`, `lookupFile`, topic lookup), `Sources/AlloyCore/Knowledge/Guidance.swift`, `Sources/AlloyCore/Knowledge/SharedContext.swift`
- Test: `Tests/AlloyCoreTests/CrossProjectKnowledgeTests.swift`, `AlreadyReadTests`, `NotesToolsTests`

**Interfaces:**
- Consumes: `KnowledgeScope.display`, `label(ofRoot:)`, `Note.authorName/project`, `ReadEntry.authorName/project`.
- Produces:
  - Reader / author names: a session of this window → its live name (as today); otherwise `"<authorName ?? "a closed session"> (in <label of project>)"` when `project` is another root, or `authorName ?? "a closed session"` when it is the own root.
  - "Already read" lines and `notes_lookup` output show paths with `display(_:)`; the block header and per-line format are otherwise unchanged.
  - Topic notes from another project end with ` (from <label>)`.
  - `Guidance.text` gains exactly this sentence (only when `shareAcrossProjects` and `shareKnowledge` are on): `Shared notes also cover files in the user's other Alloy projects: before reading a file from another repository, call notes_lookup with its absolute path.`
  - `sharedContext` candidates include files from other known projects (same caps: 50 named, 20 recent).

- [ ] **Step 1: Write the failing tests**:
  - `alreadyReadMarksOtherProject`: B is the `api` window, where session "Retry" reads `Routes.swift`; a session in A sends a message naming B's absolute path to `Routes.swift` → A's block has a line containing `api/Routes.swift` and `Retry (in api)`.
  - `topicFromOtherProjectIsLabelled`: B writes topic "auth flow"; A's topic lookup line ends with `(from api)`.
  - `closedForeignAuthorUsesStoredName`: B's session is deleted → A still shows `Retry (in api)`.
  - `guidanceMentionsOtherProjectsOnlyWhenOn`: `Guidance.text` contains the sentence with the switch on, not with it off.
- [ ] **Step 2: Run** `swift test --filter "CrossProjectKnowledgeTests|AlreadyReadTests|NotesToolsTests|KnowledgeLaunchTests"` → new tests fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter → PASS.
- [ ] **Step 5: Commit** `feat(knowledge): show which project shared knowledge came from`.

### Task 5: Settings switch

**Files:**
- Modify: `Sources/AlloyKit/SettingsView.swift`
- Test: `Tests/AlloyKitTests/SettingsViewTests.swift`

**Interfaces:**
- Consumes: `AlloySettings.shareAcrossProjects`, `Workspace.updateSettings`.
- Produces: a toggle `Toggle("Share with other projects", …)` with id `settings-share-other-projects`, placed directly under `settings-share-knowledge`, disabled while "Share knowledge" is off, saved with the other settings.

- [ ] **Step 1: Write the failing tests**: `shareOtherProjectsToggleSaves` (toggle off, save → settings file has `shareAcrossProjects: false`), `shareOtherProjectsDisabledWithoutSharing` (with share knowledge off the toggle is disabled), and keep `existingSettingsIdsStillWork` green.
- [ ] **Step 2: Run** `swift test --filter SettingsViewTests` → fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test --filter SettingsViewTests` → PASS.
- [ ] **Step 5: Commit** `feat(settings): Share with other projects`.

### Task 6: Live check and docs

**Files:**
- Modify: `Tests/AlloyCoreTests/LiveKnowledgeTests.swift`, `README.md` (Features), `docs/superpowers/specs/2026-11-09-alloy-shared-knowledge-design.md` (non-goal line points at the 5c spec)
- Test: `LiveKnowledgeTests`

- [ ] **Step 1: Add the opt-in live test** `crossProjectNoteReachesOtherWindow` (same gate and cheapest model as the existing live tests): two scratch git repos `app` and `api`, two `Workspace`s sharing one appSupport. Session in `api` reads `Routes.swift` and writes a note via `notes_write`; session in `app` is asked "What does ../api/Routes.swift do? Check the shared notes first." Assert: the `app` session called `mcp__alloy__notes_lookup` with `api`'s absolute path and its result contained the note text; or its first message carried an already-read line for `api/Routes.swift`.
- [ ] **Step 2: Run** it with the live flag once; record the outcome in the ledger. If the model ignores the guidance, it is a guidance problem, not a test to weaken: report it.
- [ ] **Step 3: README**: in Features, replace the shared-notes bullet with: several sessions in one repository, or one session per repository in separate windows, all share what they have learned; across repositories the benefit shows when work touches another repository's files or a shared topic; "Share with other projects" in Settings turns the cross-project part off. Remove nothing else.
- [ ] **Step 4: Run** full `swift build` and `swift test` → green; `FixturePrivacyTests` green.
- [ ] **Step 5: Commit** `docs: shared knowledge across projects; live cross-project check`.
