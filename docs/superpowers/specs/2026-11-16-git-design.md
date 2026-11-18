# Alloy: Git integration

Date: 2026-11-15. Status: draft for the user, revised after the builder check. Builds on Code mode
(`2026-11-15-alloy-code-mode-design.md`), the islands design (`2026-11-13-alloy-islands-design.md`) and the existing git
plumbing (`GitBaseline`, `Workspace.gitRun`, `FileWatcher`, `flushOutside`).

## Intent and why

The Code mode spec set the order "(1) Code mode itself, (2) project-wide search, (3) git, (4) terminal" and reserved a
Git tab slot in the Code sidebar ("no dead buttons"). This is project (3). The user wants the everyday git loop inside
Alloy: see what changed against HEAD in the gutter and the file tree, compare a file with HEAD, stage and unstage
(whole files and hunks), commit, see and switch branches, and blame a line on demand.

Alloy differs from other editors because several Claude sessions edit the same folder. Alloy already reviews those
edits (author bars, keep/revert, ledger diff), and a commit that makes a ledger file equal HEAD already clears that
review. Git must sit beside this model and not blur it: **author marks say who changed a line since review started;
git marks say what differs from HEAD.** They are two separate facts and are shown separately.

## Approaches

1. **Git CLI through a refactored version of the existing hardened runner, parsed by pure AlloyCore functions
   (recommended, our call).** Alloy already shells out to git with timeouts, kill escalation and no blocked pool
   threads. Porcelain v2 output is stable and made for tools. Hunk staging (`apply --cached`), blame, hooks and
   credentials behave exactly as in the user's terminal. Cost: one process per refresh, which is fine because
   refreshes are event-driven and coalesced.
2. **libgit2 linked in-process.** No process spawn, but it adds a C dependency that must build on macOS, Linux and
   Windows, grows the binary, does not run hooks the way git does, and is weak on blame and hunk staging. Against
   "lite and fast" in size and maintenance. Rejected.
3. **Hybrid: read `.git` files directly for cheap facts, CLI for the rest.** Alloy already reads `.git/HEAD` for the
   branch name; extending that to the index format is fragile (index v4, split index, sparse checkout). We keep only
   the existing HEAD read and use the CLI for everything else. Folded into approach 1.

## Goals

1. **Gutter change marks vs HEAD.** In Code mode, in the `.plain` presentation only (our call: inline and side-by-side
   already show the ledger diff, compare views show git hunks themselves), each open document shows added (bar),
   modified (bar) and deleted (`CodeChangeBar.deletedAbove`, a triangle at the top edge of the row after the deletion) marks against `HEAD`, computed
   in AlloyCore from the cached HEAD blob and the current buffer text with `TextDiff.hunks(old:new:context: 0)`.
   Marks are set with `asOf` the buffer version they were computed from, so MetalUI maps them through later edits
   (as `DiffDecorations` already does). They live in their own decoration owner `CodeDecorationOwner("git",
   priority: -1)` (our call, see Calls settled). Clicking a git bar opens the hunk popover (Goal 4), anchored with
   the existing `CodeView.popover(item:attachmentAnchor: .range(firstRowBytes, asOf:))`. Id: `code-git-hunk-popover`.
2. **File tree status colours.** File names take a colour by status: modified, added, renamed, untracked, conflicted,
   ignored (dimmed). Deleted files appear in the Git tab only. Folders take the strongest status of their children
   (conflicted > modified > added/renamed > untracked; ignored only if the folder itself is ignored). The author dot
   stays as is. Ids: existing `file-tree-row-<path>`; status is exposed as an accessibility value
   (`git-status-modified` etc.).
3. **Git sidebar tab.** The Code sidebar gets a tab model (new; today it has a single Files icon): `code-sidebar-tab-files`
   and `code-sidebar-tab-git`. The Git tab shows the branch header (name, and ahead/behind counts only when an upstream
   ref exists locally; no fetch), a `Refresh` button (`git-refresh`), then sections Conflicts, Staged, Changes,
   Untracked with per-file buttons (`git-stage-<path>`, `git-unstage-<path>`, `git-discard-<path>`), a multiline
   commit message (`git-commit-message`, MetalUI `TextEditor`), and `git-commit` / `git-commit-amend` buttons. Clicking
   a file opens Compare with HEAD (Goal 5). Rows sit in a `LazyVStack`, so a 100k-entry status costs only the
   visible rows.
4. **Hunk actions.** From the gutter popover or the compare view: stage hunk, unstage hunk, revert hunk
   (`git-hunk-stage`, `git-hunk-unstage`, `git-hunk-revert`). See "Hunk mechanics".
5. **Compare with HEAD / Index.** Two new in-memory `Presentation` cases, `.compareHead` and `.compareIndex` (our
   call), drawn by the side-by-side view with the base text on the left. Command: Git > Compare with HEAD
   (`git-compare-head`); the compare bar has a toggle `git-compare-against` (HEAD / Index). See "Compare view".
6. **Commit.** `git commit -F -` with the message piped on stdin; amend as an explicit button. Hook output and errors
   appear in an inline error row under the message (`git-commit-error`). Commit is disabled with no staged changes
   (unless amending), an empty message, unmerged entries, or a rebase in progress.
7. **Branch indicator and switching.** The existing `⎇ branch` in the title island (`title-branch`) becomes a `Menu`:
   recent local branches (the 8 most recently committed, our call), "Switch to branch..." (`git-branch-picker`),
   "New branch..." (`git-branch-new`). Detached HEAD shows the short hash. Branch lists are read only when the menu
   or picker opens. Switching with a dirty tree that git refuses shows git's own message; Alloy never stashes or
   forces (our call).
8. **Blame on demand.** Git > Blame Line (`git-blame-line`) and Toggle File Blame (`git-blame-file`). Line blame shows
   a popover (anchored at the line with the text-anchored popover) with author, date, short hash and summary. File
   blame shows initials and age (e.g. `MB 3d`) at the first row of each blame run in the gutter marker
   lane (`gutterMarkerLane(width: 6)`); full info (author, date, short hash, summary) on hover via `gutterHelp`,
   computed only on hover. Blame runs once per request
   and is cached until the file is saved or HEAD changes. Never computed while not requested.
9. **Git menu.** `CommandMenu("Git")` in `AppCommands`: Compare with HEAD, Stage File, Unstage File, Commit...,
   Switch Branch..., Blame Line, Toggle File Blame, Next Change / Previous Change (`git-next-change`,
   `git-prev-change`), Refresh. Disabled outside a repo, and outside Code mode where they need an editor.

## Calls settled after the builder check

- **Runner refactor (new work, not a wrapper).** Today `gitRun` hardcodes `/usr/bin/git` and a macOS `xcode-select`
  probe (`gitUsable`), discards stderr, returns `Data?` (nil on any non-zero exit), and always sets
  `GIT_OPTIONAL_LOCKS=0` and `GIT_LITERAL_PATHSPECS=1`; `GitBaseline.run` adds `-C root`. We extract one core,
  `GitProcess.run(args, in:, stdin: Data?, readOnly: Bool, terminateAfter:, killAfter:) -> GitResult { status,
  stdout, stderr, timedOut }` (AlloyCore, our call). It generalises the private `GitRun`/`ProcessBox` types with a
  stdin pipe (written then closed, so hooks reading stdin see EOF), a second readability handler for stderr (capped
  at 64 KB), and the exit status. `gitRun` becomes a thin wrapper with today's exact behaviour (stdout on status 0,
  nil otherwise), so `GitBaseline` and `gitHead` are unchanged and their tests guard the refactor.
- **Environment.** Every run sets `GIT_TERMINAL_PROMPT=0` and `GIT_LITERAL_PATHSPECS=1` (so every path is literal;
  pathspec-magic file names are safe) and passes `--` before paths (so a path starting with `-` is safe). Read runs
  (`readOnly: true`) also set `GIT_OPTIONAL_LOCKS=0`. Write runs leave it unset.
- **Read invariant.** Alloy's read commands never write `.git/`: `status` with `GIT_OPTIONAL_LOCKS=0` does not
  refresh the index, and Alloy never runs `update-index --refresh`. So `gitChanged` never echoes an Alloy read, and
  there is no refresh loop. A write command produces exactly one echo refresh, by design (Data flow 6). A test
  asserts that a status run leaves `.git/index` mtime unchanged.
- **Git executable (cross-platform, same design everywhere).** `GitExecutable.resolve()` runs once per app launch:
  `AlloySettings.git.gitPath` if set; otherwise the first `git` (`git.exe` on Windows) on `PATH`. If that is the
  macOS `/usr/bin/git` shim, the existing `xcode-select -p` check still decides usability, so no install dialog
  appears. Minimum git 2.23 (`git switch`, `restore`); older shows one explanatory line (our call). Linux and Windows
  use the same resolver; the watcher is the existing `FileWatcher` on each platform feeding the same hooks; git adds
  no platform code of its own.
- **Refresh triggers.** `workspace.gitChanged` fires only for `.git/` paths (`flushOutside`), so worktree edits need
  their own trigger. We add one hook, `Workspace.worktreeChanged: (([String]) -> Void)?` (`@ObservationIgnored`),
  called at the end of `flushOutside` with the batch's project-relative non-`.git` paths (the `rels` keys, before the
  open-document filter). That batch is already coalesced by `outsideCoalesce` and already excludes `.build`,
  `node_modules` and `.swiftpm`. All triggers feed one GitService coalescer: `gitChanged`, `worktreeChanged`,
  `onSaved` (Alloy's own save; its FSEvent may also arrive, and the coalescer merges them), `git-refresh`, and
  project open. Each run is a full `status` scoped to the project (our call: per-file status is not worth its
  bookkeeping). Paths at or under an entry the last status reported as ignored are dropped before they request a
  refresh (our call), so build output in ignored folders like `dist/` does not cause status runs.
- **Branch name ownership.** The title island keeps reading `workspace.branchName` (set from `.git/HEAD` in
  `baselineEventSeen()`, no spawn). The Git tab header reads the status `# branch.*` headers, which also give
  ahead/behind against the local upstream ref. Both update from the same `.git/HEAD` event; a brief disagreement
  during one coalesce window is acceptable (our call). Ahead/behind is display only: push, pull and fetch stay
  non-goals.
- **Two marks per row.** Author bars are drawn by the default owner (name `""`, priority 0). MetalUI gives each
  field to the higher priority, and a tie to the later name (`"git"` would beat `""`), so the git owner uses priority
  **-1** (our call). Git marks live in MetalUI's independent change lane (`CodeLineDecoration.changeBar`), so the git bar
  and the author bar show on the same row. The owner keeps priority **-1**. Clicks and context menus on a git bar
  arrive as `CodeGutterHit.Source.changeBar`; hovering one shows the hunk summary (e.g. `+3 −1`).
- **Commits and Claude review stay as today.** A commit that makes a ledger file equal HEAD still clears that
  review (`keepAllEdits`). Staging does not touch the ledger.
- **Persistence without a version bump (our call).** `UIState` decodes every field tolerantly
  (`decodeIfPresent` with a default) and an older Alloy ignores unknown keys, so two new optional top-level fields
  need no bump of `UIState.currentVersion` (a bump would make older builds treat the file as `.newer` and stop
  writing it): `codeSidebarTab: String?` ("files" / "git") and `gitCommitDraft: String?`. An older Alloy drops them
  when it next writes the file, which loses only the tab choice and a draft. `Presentation` is not persisted (it
  lives in `Workspace.presentations`, and `GroupState` stores only tabs and the active tab), so the new cases need no
  migration.

## Hunk mechanics (our calls)

- **Blob cache keyed by object id.** Porcelain v2 gives each entry's HEAD and index object ids (`hH`, `hI`).
  GitService keeps `[oid: text]` for open documents only, filled by `git cat-file blob <oid>`, at most 2 concurrent
  `cat-file` spawns (a save storm queues; repeated oids are fetched once). An unborn HEAD (`# branch.oid (initial)`)
  has no HEAD blobs and shows no marks.
- **Marks** diff HEAD text against the buffer. **Staging** diffs index text against the buffer: when the file is not
  partially staged the two are equal and the same hunks serve both. Stage hunk builds a `--unidiff-zero` patch of
  one index-vs-buffer hunk and runs `git apply --cached --unidiff-zero`; `apply --cached` touches only the index, so
  staging works from the unsaved buffer (it stages what the user sees) without saving. Unstage hunk builds the
  HEAD-vs-index hunk and applies it with `--cached -R`.
- **Revert hunk** is a buffer edit: it replaces the hunk's rows with HEAD's lines through the normal edit path, so
  it is undoable with ⌘Z and reaches disk and the ledger (as a user edit) on the next save. Before applying, it
  tests overlap with pending Claude edits: the hunk's buffer row range (deletion = the row after the deleted-above triangle) against
  the rows of every pending ledger edit for the file, both in the current buffer version. Any shared row asks
  "This also reverts Claude's unreviewed change" (Decisions Q2).
- **Paths and repo root.** On project open (and on a `.git` event at the root), `git rev-parse --show-toplevel
  --show-prefix` gives the repo top and the project's prefix inside it. Status runs `-C projectRoot status ... -- .`
  and strips the prefix from repo-relative paths; entries outside the project are dropped. Blob reads by oid need no
  path. Write commands (`add`, `restore --staged`, `apply`, `restore --worktree`) run at the repo top with
  repo-relative paths (`prefix + rel`) after `--`. Linked worktrees already work through `externalGitDir`.
- **Line endings, LFS, binaries, symlinks.** Blobs are read without filters, so with `core.autocrlf` HEAD text is LF
  while the buffer is CRLF. Before diffing, if the buffer uses CRLF and the HEAD blob has no CR, `\r\n` is
  normalised to `\n` on the buffer side for the diff only, and patches are built in the index's line ending. An LFS
  pointer blob (starts with `version https://git-lfs.github.com/spec/v1`), a binary blob (NUL in the first 8 KB),
  a symlink (mode `120000`) and a submodule show status only: no marks, no hunk actions.
- **Size cap.** Mark diffs run in a detached task, never on the main actor, and are skipped for buffers over 2 MiB
  (no marks, our call).
- **Discard.** Tracked file: `git restore --worktree -- <path>` after a confirmation that names the file; an open
  document reloads through the existing outside-change path. Untracked file: deleted (not `git clean`) after "Delete
  `<name>`? It is not tracked by git and cannot be restored." Submodule: discard disabled.

## Compare view (our calls)

- `.compareHead` / `.compareIndex` reuse `SideBySideView` with a new input `CompareSource`:
  `.ledger(EditRecord)` (today's behaviour) or `.git(GitCompare { base: .head | .index, hunks })`. The `CodePanel`
  cache key adds the two modes. `workspace.presentation(of:in:)` and `setPresentation` are unchanged.
- `PanelEditBar` stays edit-record-only. A new `GitHunkBar` component shows for `.git` sources: hunk counter, next /
  previous, stage / unstage / revert of the focused hunk. Gutter bar tags in the compare view index into a per-view
  `[UInt64: GitHunk]` table, the same pattern as today's `tags` for edits.
- Compare uses `-U3`-equivalent context folding; gutter marks use context 0.

## Defaults (our calls)

- Gutter marks on in Code mode `.plain`; never in Chat mode's file panel (it already shows the ledger diff).
- Status colours on; ignored files dimmed, not hidden.
- Untracked files listed in the Git tab and coloured in the tree, not marked in the gutter (the whole file would be
  one bar).
- Blame off until asked.
- Live marks while typing off (Decisions Q1).

## Non-goals

Push, pull, fetch, remotes and credentials; merge and rebase flows (conflicts are shown, resolution is the user's
editor work); stash; history/log browser; submodule management; partial-line staging; GitHub/PR integration; LFS;
`git init`.

## Anti-goals

- Any timer, poll or periodic `git status`. Idle frames and idle CPU stay at zero.
- Any git work on a keystroke. Marks follow typing through MetalUI's `asOf` mapping and are recomputed on save, on
  an outside change to the file, on a HEAD change, or (opt-in) on typing idle; never by spawning git.
- Raising the steady keystroke-frame guards (Chat 88, Code 91/107/117).
- Losing work: no force checkout, no stash, no reset, no `git clean`. Discard confirms; revert hunk is undoable.
- Git state in observed properties that change on every refresh.
- Writing git config (no `core.fsmonitor`, no `untrackedCache` changes; the user's own settings are honoured).

## Constraints

MetalUI only, and read-only from Alloy: gaps are filed with the MetalUI session, never worked around. Theme values
only (new keys in `Theme.swift`, covered by ThemeContrastTests/ContrastAuditTests). Accessibility ids on every
interactive view. Zero warnings. `swift test --no-parallel`. Linux/Windows mirror the macOS design (same runner,
same resolver, same hooks). Never write `~/.claude` or a project's `.claude`. Never invoke a git command that
writes outside the repo or prompts (`GIT_TERMINAL_PROMPT=0`).

## Design

### Architecture

- **AlloyCore/Git/** (pure, testable; inside AlloyCore so it can call the `internal` `TextDiff` and `PatchHunk`
  without widening their access): `GitStatusParser` (porcelain v2 `-z --branch` to `GitStatus { branch, oid,
  upstream, ahead, behind, operation, entries: [path: GitFileStatus] }`, handling `1` ordinary, `2` rename lines
  with the NUL-separated original path, `u` unmerged, `?` untracked, `!` ignored, and submodule fields), `GitHunks`
  (`TextDiff.hunks(context: 0)` to `[GitHunk { oldRange, newRange, kind }]`), `GitPatch` (a `--unidiff-zero` patch
  for one hunk), `GitBlameParser` (`--porcelain` to runs), `GitStatusRollup` (folder status), `GitProcess`,
  `GitExecutable`.
- **GitService (actor, AlloyCore):** owns the last `GitStatus`, the blob cache, the blame cache, the repo top and
  prefix, and the coalescer: a 0.5 s window on the injected clock (the existing `gitDebounce` pattern), at most one
  status run in flight, and a request during a run sets one dirty flag for exactly one follow-up run. It computes
  the status diff and the folder rollup off the main actor. Commands: `refreshStatus`, `stage(paths)`,
  `unstage(paths)`, `stageHunk`, `unstageHunk`, `discard(paths)`, `commit(message, amend)`, `switchBranch`,
  `createBranch`, `branches()`, `blame(path, lines?)`.
- **GitCoordinator (@MainActor, AlloyKit):** mirrors `LSPCoordinator.install(on:)`. Sets `workspace.gitChanged` and
  `workspace.worktreeChanged` (both unused today), and chains `onSaved` and `onStop` (calling the previous closure,
  since LSP already sets `onSaved`). It reads `AlloySettings.git` itself and applies values imperatively; no Code
  body reads git settings. It publishes through three narrow surfaces:
  - `GitTreeStatus`: per-row cells. A `@ObservationIgnored [path: GitStatusCell]` map, where `GitStatusCell` is a
    small `@Observable` class with one `status` field, created lazily for rows that are shown. A tree row reads only
    its own cell, so a status change re-runs only the rows whose status changed (unlike `FileTreeModel.marks`,
    which is one map every row observes).
  - `GitPanelModel`: observed only by the Git tab, so its updates cost nothing while the tab is hidden; when the
    Files tab shows, the Git tab is not in the tree at all.
  - Gutter marks: imperatively into each open document's `CodeDecorations` under owner `git`, like diff and
    diagnostic decorations.
- **CodeSidebarModel (@Observable, per window, AlloyKit):** the selected tab; persisted in `UIState.codeSidebarTab`.
  Only the tab row and the content switch read it.
- **Branch picker:** `QuickOpenField` and `QuickOpenList` are generalised to a row source (file paths or branch
  names), with `QuickOpenModel` unchanged in behaviour (its tests guard it) and a small `BranchPickerModel` beside
  it (our call).

### Data flow

1. Project open → `rev-parse` (top, prefix) → first status run.
2. FSEvents for worktree files → `flushOutside` (coalesced) → `worktreeChanged(paths)`; FSEvents under `.git/` →
   `gitChanged(paths)`; Alloy save → `onSaved(path)`. All → GitService coalescer (0.5 s) → `git status
   --porcelain=v2 -z --branch --untracked-files=normal --ignored=traditional -- .` (read run) → parse → diff against
   the previous status → update only changed tree cells and, when shown, the Git tab.
3. `.git/HEAD` or a ref of the current branch moved (commit, switch, a Claude session's own git) → the new status
   shows new `hH` oids → marks recompute for open documents whose oid changed; blobs not referenced by an open
   document are evicted.
4. Save, or an outside change merged into an open document → recompute that document's marks from the cached blob
   and the current buffer (a detached diff; a spawn only if the blob is not cached).
5. Typing → no work: MetalUI maps the marks forward through edits. With `liveMarks` on, one detached diff runs 750 ms
   after the last keystroke on `autosaveClock` (our call) and replaces the marks only if they differ.
6. Write commands → `GitProcess` write run → on success the FSEvents that follow drive one refresh; Alloy does not
   refresh twice. On failure, stderr shows inline and nothing retries.

### UI sketch

```
Code sidebar:  [ Files | Git ]
  ⎇ main  ↑2 ↓0            (counts only with a local upstream ref)
  Message ┌──────────────────────────┐
          │ Fix scroll jump          │
          └──────────────────────────┘
  [Commit]  [Amend]
  Staged (1)        Sources/App.swift        M  [−]
  Changes (2)       Sources/View.swift       M  [+] [↺]
                    Old.swift → New.swift    R  [+]
  Untracked (1)     notes.txt                ?  [+] [🗑]

Editor gutter:  12 ┃ ▌ (author bar, git change bar)
                14 ▸ deleted-above triangle at the row's top edge
```

### Persistence and settings

- `UIState.codeSidebarTab` and `UIState.gitCommitDraft` (see Calls settled). The draft is stored unencrypted in
  Alloy's per-project UI state file, like the rest of UI state; the settings section says so, and the draft is
  cleared on a successful commit.
- `AlloySettings.git`: `gutterMarks` (on), `statusColours` (on), `liveMarks` (off), `gitPath` (empty = resolve).
  Settings section ids `settings-git-*`.

### Failure modes

- **No usable git** (not found, the macOS shim without tools, or older than 2.23): Git tab shows one explanatory
  line; menu items disabled; probed once per launch.
- **Not a repo:** Git tab says so; title shows no branch.
- **Slow status:** the 10 s read timeout kills it; the Git tab shows the last good status with "Status timed out" and
  automatic refresh pauses until `git-refresh` is pressed (our call: no repeated slow runs). Untracked scanning uses
  git's default `normal` mode (untracked folders collapsed); `core.untrackedCache` and `core.fsmonitor` are honoured
  if the user set them, never set by Alloy.
- **Merge, rebase or cherry-pick in progress** (status shows it via `.git/MERGE_HEAD`, `CHERRY_PICK_HEAD`,
  `rebase-merge/`, `rebase-apply/`): a banner names it. Merge and cherry-pick: commit allowed once there are no
  unmerged entries (git completes the operation). Rebase: commit disabled with "Rebase in progress: continue it in a
  terminal".
- **Unborn branch:** Git tab works, everything shows as added or untracked, no gutter marks, amend disabled.
- **`index.lock` held** (a terminal or a Claude session running git): write commands show git's stderr; reads never
  take the lock. If the lock file is older than 60 s, the error row offers "Remove stale lock" (`git-remove-lock`)
  behind a confirmation naming the file (our call); Alloy never removes it on its own.
- **Concurrent `git add` by a Claude session during a hunk stage:** whichever takes `index.lock` second fails with
  git's message; nothing retries; the next refresh shows the result.
- **Hunk apply fails** (index changed underneath): show the error, refresh, no retry loop.
- **Commit with hooks or signing:** write runs have a 120 s timeout (our call) with SIGTERM, then SIGKILL 5 s later.
  Stdin is the message and is closed, so a hook or tty pinentry that reads stdin gets EOF and fails visibly. Git
  updates the branch ref only at the end, so a killed commit leaves no half commit; a SIGKILL may leave
  `index.lock`, handled above. Files a hook edits arrive through FSEvents and the normal outside-change path.
- **Branch switch with unsaved documents:** Switch first saves dirty documents (the same path as ⌘S, so the ledger
  sees user edits) and then runs `git switch`; if git refuses, its message shows and nothing else happens. Files
  the switch changes reload through the outside-change path (our call).
- **A Claude session runs `git commit`:** same FSEvents path; marks and tree update, ledger review clears as today.
- **Renames:** shown as `R` with "old → new" in the Git tab and the renamed colour in the tree; staging the new path
  stages the rename. Copies are not reported by `status` and are not handled.
- **Paths:** `-z` output, so `core.quotepath` does not matter; status paths are matched to documents by exact string
  (a case-only difference on a case-insensitive volume shows git's spelling, a known limitation).
- **Huge status:** parse, diff and rollup run in GitService; the main actor receives only changed cells and the
  visible Git tab rows are lazy.

## Performance plan

- **Idle cost zero:** no timers; refresh only from events, saves and the Refresh button; nothing observed changes
  while idle. Alloy's reads never write `.git/`, so there is no self-triggered loop.
- **Typing cost zero:** no git spawn and no diff per keystroke; git decorations are a separate owner whose rows
  MetalUI maps through edits, so a buffer edit does not reapply them. Live marks (opt-in) run a detached diff after
  750 ms idle and touch decorations only when the marks differ; that work is off the keystroke frame and outside
  the guards' measured frames.
- **Steady guards stay at 88 / 91 / 107 / 117:** tree rows read per-row cells that change only on status change;
  `GitPanelModel` is read only by the Git tab; the title reads the existing `branchName`; no Code body reads
  `AlloySettings.git`.
- **Spawn caps:** one status in flight plus one follow-up; at most 2 concurrent `cat-file`; blame only on request.
- **Gutter lane:** git reserves `changeLane(true)` while marks can show for the document (repo open, file
  tracked). File blame uses `gutterMarkerLane(width: 6)` while it is on and releases it when off: one deliberate
  text shift per toggle, never while typing (our call). Hover text is computed only on hover.
- **New guards:** `GitIdleTests` (no git spawn and 0 element requests across N idle frames with a repo open, using
  `gitSpawnCount`), `GitTypingFrameTests` (Code layouts keep 91/107/117 with marks and status colours on and the Git
  tab shown), a `BodyProbe` per new view (Git tab rows, tree rows under status change, branch menu, commit box)
  asserting no re-run on keystrokes and only changed rows re-run on a status change, a coalescing test (100 index
  events → at most 2 status runs), and a read-invariant test (status leaves `.git/index` untouched).
- **Memory:** blobs cached only for open documents; blame cache dropped when the file closes.

## Known MetalUI gaps (landed)

Gaps (a), (b) and (c) have landed in MetalUI (#377, #374, #375) and are adopted (task 11). Gap (d) remains conditional.

Verified present in MetalUI: `TextEditor`, `TextField`, `Menu`, `popover(isPresented:)` / `popover(item:)` with
`attachmentAnchor`, the `CodeView` text-anchored `popover(item:attachmentAnchor: CodeTextAnchor)` (`.caret`,
`.range(_, asOf:)`), `help(_:)` with a location closure, `LazyVStack`, `CodeDecorationOwner(name, priority:)`
(higher priority wins each field, tie to the later name), `onGutterBarClick`, `gutterBarContextMenu`,
`gutterMarkerLane(_:)`, `CodeGutterMarker(text, color:)`, `CodeVirtualRow`. `CodeGutterHit.Source` has only
`lineDecoration`, `virtualRow` and `gutterMarker`. The marker lane is two space advances wide.

- **(a) Independent change lane (landed, MetalUI #377).** Wanted: `CodeLineDecoration.changeBar: CodeChangeBar?` (enum `.added(Color)`,
  `.modified(Color)`, `.deletedAbove(Color)`) drawn in its own narrow lane beside `gutterBar`, enabled by
  `CodeView.changeLane(_ reserved: Bool)`, with `CodeGutterHit.Source.changeBar`. SwiftUI has no equivalent
  (closest: NSRulerView custom drawing). Needed so git and author bars show on the same row.
- **(b) Gutter hover text (landed, MetalUI #374).** Wanted: `CodeView.gutterHelp(_ text: @MainActor (CodeGutterHit) -> String?)`, so blame
  and hunk summaries show on hover of a marker or bar. The location-closure `help` gives a point but no way to map
  it to a gutter hit. SwiftUI equivalent: `.help` per view.
- **(c) Wider marker lane (landed, MetalUI #375).** Wanted: `CodeView.gutterMarkerLane(width: Int)` in characters, so file blame
  can show initials and age (e.g. `MB 3d`). Without it v1 shows two-character initials only.
- **(d) End-of-line annotation (only if the user picks inline blame, Decisions Q3).** Wanted:
  `CodeLineDecoration.trailingText: (String, CodeStyleID)?` drawn after the line's last glyph, not selectable, no
  layout shift. SwiftUI: none (closest: an overlay per line).

The earlier gap "popover anchored to a gutter hit" is dropped: the text-anchored `CodeView.popover` covers it.

## Testing strategy

- AlloyCore unit tests with throwaway repos (`AlloyTestSupport/Git.swift`): status parser (ordinary, rename with
  original path, unmerged, untracked, ignored, submodule, spaces, unicode and leading `-` in names, detached HEAD,
  unborn branch, no upstream, operation in progress), project below the repo top (prefix stripping), hunk
  computation incl. CRLF normalisation, LFS pointer and binary detection, patch round-trip (`apply --cached
  --check`), stage/unstage hunk from an unsaved buffer end to end, blame parser, folder rollup, coalescing with
  `ManualClock`, `GitProcess` exit status, stderr, stdin and timeout kill, the `gitRun` wrapper's unchanged
  behaviour, the read invariant, executable resolution.
- Interplay: Claude ledger edit then commit clears review (existing); revert hunk over a pending edit asks first;
  revert hunk is undoable; git owner never hides an author bar; `worktreeChanged` fires for project files and not
  for `.git/` paths.
- AlloyKit view tests: sidebar tabs and persistence, Git tab, branch menu and picker, commit box, compare
  presentations with `GitHunkBar`, settings section, menu enablement.
- Perf guards listed above.

## Suggested task breakdown

1. `GitProcess` refactor (stdin, stderr, status, readOnly env) with `gitRun` as a wrapper, `GitExecutable`
   resolver, `worktreeChanged` hook in `flushOutside`, + tests.
2. Pure parsers and models: status, rollup, hunks (context 0), patch, blame, line-ending and binary detection +
   tests.
3. `GitService` actor (coalescer, blob cache, repo prefix) and `GitCoordinator` wiring to `gitChanged` /
   `worktreeChanged` / `onSaved` / `onStop` + idle and read-invariant guards.
4. File tree status colours via per-row cells + theme keys + contrast entries.
5. Gutter marks under owner `git` (priority -1) + hunk popover + next/previous change.
6. `.compareHead` / `.compareIndex`, `CompareSource`, `GitHunkBar`, hunk actions.
7. Code sidebar tab model + Git tab: lists, stage/unstage/discard, commit box, operation banner, persistence.
8. Branch menu in the title island + generalised quick-open list + branch picker + new branch.
9. Blame line/file on demand.
10. Git menu, settings section, perf guard tests across Code layouts.
11. Adopt the MetalUI change lane, gutter hover and wider marker lane when the gaps land (follow-up).

Tasks 1-2 first; then 3; then 4-9 in parallel (7 before 8 only for the shared sidebar file, otherwise
independent); 10 last.

## Decisions for the user

1. **Gutter marks while typing.** (a) Recompute on save and outside changes only, with MetalUI mapping marks through
   typing (lightest, recommended); (b) also once on typing idle, as the `liveMarks` setting (default off);
   (c) live per keystroke (rejected: costs typing frames). Recommended: (a) with (b) available as a setting.
2. **Revert hunk over a pending Claude edit.** (a) Confirm, then revert as an undoable buffer edit that the ledger
   records as a user edit on save (recommended); (b) block until the Claude edit is kept or reverted in review;
   (c) revert without asking (it is undoable).
3. **Blame display.** (a) Gutter initials at each run, details in the line popover now and on hover after gap (b)
   (recommended, no layout shift while on); (b) inline end-of-line text like GitLens (needs gap d); (c) virtual
   rows above each run (works today, shifts layout).
4. **Ship order vs MetalUI change lane (superseded by task 11).** (a) Ship gutter marks now with the interim rule (git bar hidden on rows
   with an author bar), adopt the lane later (recommended); (b) wait for gap (a) before shipping gutter marks.
5. **Scope of v1.** (a) Everything in Goals (recommended); (b) leave blame and branch creation for a v1.1.


## Approved decisions (2026-11-16)

The user approved every recommendation above ("Approved build it"). Binding:
- 1(a)+(b): marks on save and outside changes; `liveMarks` (typing idle) is a setting, off by default.
- 2(a) confirm, then revert as an undoable user edit. 3(a) gutter initials, details in the popover.
- 4(a) ship before the MetalUI change lane with the interim rule. 5(a) full v1 scope.
- Ledger edits use `Author.user` plus edit-group id (code-intelligence.md decision 1).
- Task 11 (2026-11-16): gaps a, b, c adopted; interim rule removed.
