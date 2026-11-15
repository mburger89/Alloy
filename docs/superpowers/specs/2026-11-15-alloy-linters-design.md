# Alloy: linters through language servers

Date: 2026-11-15. Status: draft for the user's review. Extends `2026-11-12-alloy-lsp-design.md` (LSP v1, on master).

## Intent and why

The user wants to "catch problems in Claude's edits before I accept them". Alloy already shows language-server
diagnostics in the diff view (`Sources/AlloyKit/Code/DiffDecorations.swift`) and counts them in the file panel header.
Linters such as Ruff and ESLint report through the same LSP diagnostics channel, so the user asked to "add support for
linters like Ruff, eslint, etc" and chose approach 1 below.

## Approaches

1. **One main server plus linters (user's pick).** A file keeps its one main language server and also gets every
   enabled linter server that matches it. Diagnostics from all of them merge into the same view, labelled by source.
   Go to definition, semantic tokens and later phase-2 features stay with the main server.
2. **One server per language, user picks.** Simple, but choosing Ruff means losing Pyright's type checking (or the
   reverse), which works against catching problems in Claude's edits. Rejected.
3. **Alloy runs linter commands itself** (`ruff check --output-format json` on save, parse JSON or SARIF). Per-linter
   parsing code, no live updates, and efm-langserver already covers linters with no server. Rejected.

## Goals

1. **Linters next to the main server.** A server entry gets a role: `main` (today's behaviour, one per file) or
   `linter` (any number per file). `ServerRegistry` keeps `server(forPath:)` for the main server and adds
   `linters(forPath:) -> [ServerConfig]` (enabled linters whose extensions or file names match). `LSPManager` tracks,
   per path, the main server plus its linter servers; it opens, changes, saves and closes the document on each of them
   with the same sync rules as v1, and starts each lazily like v1 (first matching document shown).
2. **Merged diagnostics.** Each server's diagnostics for a path are kept separately and the shown set is their union, so
   one server's update never wipes another's. Each item carries its source: the diagnostic's own `source` field if the
   server sends one, else the server's display name. The virtual message row shows it, e.g. `ruff: F401 'os' imported
   but unused` (with the `code` when present). The header's error/warning counts and next/previous problem cover the
   union.
3. **Linters only lint.** Alloy sends linters document sync and reads their diagnostics (push, or pull if that is all
   a linter offers). It does not ask them for definitions, semantic tokens, hover or completion, and it does not apply
   their code actions or formatting (v1 non-goals stay).
4. **Built-in linter entries** (found on the login-shell PATH like v1; never installed or downloaded):
   | id | name | command | files |
   |---|---|---|---|
   | `ruff` | Ruff | `ruff server` | py, pyi |
   | `eslint` | ESLint | `vscode-eslint-language-server --stdio` | js, jsx, mjs, cjs, ts, tsx |
   | `biome` | Biome | `biome lsp-proxy` | js, jsx, mjs, cjs, ts, tsx, json, jsonc, css |
   | `golangci-lint` | golangci-lint | `golangci-lint-langserver` | go |
   | `efm` | efm-langserver | `efm-langserver` | none built in: the user lists the files in settings |
   ESLint's server needs answers to `workspace/configuration` (at least `validate: "on"`, `run: "onType"`,
   `workingDirectory` mode `auto`, `nodePath: null`, `experimental: {}`, `problems: {}`, `rulesCustomizations: []`)
   instead of v1's nulls; golangci-lint-langserver needs `initializationOptions.command`
   (`["golangci-lint", "run", "--output.json.path=stdout", "--show-stats=false"]` or the v1-format equivalent for the
   installed version). These per-server answers live in the built-in table, not in general code.
5. **Clippy for Rust.** A setting "Use Clippy" on the rust-analyzer entry sends `check.command = "clippy"` in its
   initialization options (rust-analyzer's own setting). Off by default **(my call: Clippy is slower and opinionated)**.
6. **Settings.** Settings › Language servers lists linters in their own group "Linters" under the servers, each with
   found / not found and an on/off switch (same row style, ids `settings-linter-<id>`). The Clippy switch sits on the
   rust-analyzer row (`settings-lsp-rust-analyzer-clippy`). Users can add their own linter in `settings.json`
   `languageServers` with `"role": "linter"`, and can set `role` on a built-in entry to override it.
7. **Status.** The file panel header shows the main server's status as today, followed by the linters running for the
   file (e.g. `Pyright · Ruff`). A linter that is not installed is not shown in the header **(my call: the header is
   narrow; Settings shows not found)**. A failed linter shows `Ruff failed`, as v1 does for servers.

## Defaults (my calls)

- **Linters are on by default when found**, like servers in v1. A user with Ruff installed gets Ruff findings without
  touching settings. Each can be switched off.
- **Biome and ESLint both on** when both are installed, because projects usually install only one of them. No conflict
  detection.
- **Duplicates are kept.** Pyright and Ruff can both flag an unused import; both show, each labelled. Merging
  look-alike diagnostics across tools is guesswork.

## Calls settled after the builder check (my calls)

1. **Several findings on one line.** The message row under a line shows every distinct diagnostic on it, stacked one
   per row, most severe first, up to 3, then `+N more`. Each row reads `<source> <code>: <message>`, e.g.
   `ruff F401: 'os' imported but unused`. `LSPDiagnostic` gains `code` (string or number, as the server sends it).
   The existing 200-virtual-row cap still holds across the file.
2. **The manager does the merge.** `LSPManager` keeps diagnostics per (path, server), applies v1's version mapping per
   server, and yields the union per path; `LSPResult.diagnostics` stays per path. The UI layer does not change shape.
3. **One role per server id.** A server is either `main` or `linter`, never both. Main servers keep today's
   "user claims first" lookup. Linters have their own list-valued lookup (by file name and by extension), so a linter
   claiming `.ts` never competes with typescript-language-server. The manager's definition and semantic-token paths
   only ever use the main server; linters get sync and diagnostics only.
4. **ESLint and Biome start only where configured.** ESLint runs for a file only when the project has an ESLint
   config (`eslint.config.*`, `.eslintrc*`, or an `eslintConfig` key in `package.json`) in the file's folder or above,
   up to the project root; Biome only with `biome.json` / `biome.jsonc`. This avoids "no config" noise and a Node
   process in projects that don't use them. Ruff and golangci-lint run with their defaults, as they work without a
   config.
5. **Linter status and failures** follow v1's per-server rules: at most 3 restarts in 5 minutes, then marked failed
   and not retried on each open (until Settings toggles it or the app restarts). The header shows `Ruff failed`.
   A linter still starting shows nothing until it is ready.
6. **Per-server configuration answers.** `ServerConfig` gains built-in `configurationAnswers` keyed by
   `workspace/configuration` section (one answer per requested item; unknown sections stay null). Not user-overridable
   in this version. golangci-lint ships one form only, for golangci-lint 2.x (current), with no version detection.
7. **Clippy setting** is stored in the rust-analyzer entry's override in `settings.json` as `"clippy": true`, merged
   into the initialization options as `check.command = "clippy"`; a user's own `initializationOptions` win on
   conflict. Toggling it restarts rust-analyzer.
8. **Pull diagnostics** follow v1's rule for linters too.

## Non-goals

- Lint fixes or code actions ("fix all", "organize imports"), formatting.
- Running linters without a server (approach 3), SARIF import.
- Showing only findings on changed lines. Possible later, but the diff view already puts changed lines in front.
- Sending lint findings to Claude sessions (the v1 "natural follow-up" stays a follow-up).
- Per-project linter settings beyond what each linter reads from its own config file (`ruff.toml`,
  `eslint.config.js` and so on, which the linters find themselves).

## Anti-goals

- **Slower typing or more memory when no linter is installed.** Nothing runs or is allocated for an absent linter.
- **Typing waits on a linter.** Document sync to linters goes through the same off-main-thread path as v1. The
  typing-latency benchmark and the ViewRerun steady-frame guard must not move.
- **One server's diagnostics clearing another's**, or a stale linter result painted over a newer edit (v1's version
  mapping applies per server).

## Constraints

All Alloy constraints apply: MetalUI only, read-only MetalUI (gaps go to the MetalUI session), accessibility ids on
interactive views, no writes to `~/.claude` or `.claude/`, zero warnings, `swift test --no-parallel`. Alloy never
installs servers.

## Left to the builder

- How `Tracked` changes to hold one main server and a set of linters, and how restarts and `reload(registry:)` handle
  them.
- Exact `role` decoding and override rules in `ServerConfigOverride` (lenient, like the rest of `languageServers`).
- Test strategy: fake servers for main plus linter, union and independent clearing, source labels, lazy start,
  disabled and not-found linters, ESLint's configuration answers, and Clippy's initialization option.

## Decision 2026-11-15: no trust gate

ESLint and Biome run the project's own config (and its local `node_modules` binaries) when a file opens, as
designed. The user chose to keep this ungated ("stay as they are"): Alloy is opened on the user's own projects.
