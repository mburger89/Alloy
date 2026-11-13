# Alloy: Language Server Protocol support

Date: 2026-11-12. User request: "I want to add support for LSP's language server protocol so we can support more
programming languages easily". The user skipped the design questions, so every decision below not quoted from them
is **my call**. Standing goal (user, 2026-11-12): MetalUI and Alloy "as lite and fast as possible with out giving up
quality".

## Intent

Today a file whose language has no bundled tree-sitter grammar (15 languages, `Language.detect`) opens as plain
uncoloured text with no language intelligence. LSP lets Alloy support any language that has a language server, without
Alloy shipping per-language code: the user installs the server, Alloy finds and runs it.

## Goals (v1)

1. **A small, fast LSP client** in a new UI-free target `AlloyLSP` (depends on AlloyCore / MetalUICodeBuffer only):
   stdio transport with `Content-Length` framing, JSON-RPC 2.0 requests / responses / notifications, `$/cancelRequest`,
   server-to-client requests answered (at least `workspace/configuration` with nulls, `window/workDoneProgress/create`,
   `client/registerCapability` accepted), `initialize` / `initialized` / `shutdown` / `exit`.
2. **Server registry.** A built-in table of well-known servers (language id, file extensions / file names, command and
   args), e.g. rust-analyzer, sourcekit-lsp (via `xcrun`), typescript-language-server `--stdio`, pyright-langserver
   `--stdio`, gopls, clangd, lua-language-server, zls, elixir-ls, ruby-lsp, bash-language-server, yaml-language-server,
   vscode-json/css/html servers, marksman, taplo (TOML), kotlin-language-server, jdtls. Users add or override entries
   in `settings.json` under `languageServers` (lenient decoding, same file `AlloySettings` already uses) and can turn a
   server off. A server is found on the login-shell PATH (`ClaudeLocator.loginShell()` style). Alloy never downloads or
   installs servers. **(my call: no network installs; security and "lite")**
3. **Lifecycle.** One server process per (server, workspace root), started lazily when the first matching document is
   shown, stopped when the workspace closes or Alloy quits (shutdown, exit, then SIGTERM/SIGKILL like `ClaudeProcess`).
   A crashed server is restarted at most 3 times per 5 minutes, then marked failed. Files over 1 MiB (already windowed)
   are not sent to servers.
4. **Document sync** from the existing `CodeEdit` stream (`OpenDocumentView.observeBuffer`/`drain`): didOpen,
   incremental didChange when the server supports it (else full), didSave from `performSave`, didClose. A `.resync`
   batch sends full text. Positions: offer `positionEncoding` `utf-8` first, fall back to UTF-16 via
   `CodeSnapshot.utf16Offset(ofUTF8:)` / `utf8Offset(ofUTF16:)` using the snapshot each edit was made against.
   Session edits and disk reloads flow through the same stream, so servers see what Claude sessions change.
5. **Diagnostics** (`textDocument/publishDiagnostics`, plus pull diagnostics if that is all the server offers): range
   tints on MetalUI's `.diagnostics` highlight layer (error / warning / info colours from new theme keys), the message
   as a read-only virtual row under the line (merged with the diff decorations Alloy already owns in
   `DiffDecorations`), an error/warning count in the file panel header, and keyboard next/previous problem.
6. **Go to definition** on the caret by keyboard (F12, and the menu) — opens the target file in the code panel and
   selects the range (`buffer.select(range, reveal: true)`); a location outside the workspace opens read-only.
7. **Colour for languages without a grammar** from semantic tokens (`textDocument/semanticTokens/full`, delta when
   offered) on the `.semantic` layer, token types mapped to the existing `SyntaxToken` kinds so themes colour them with
   no new keys. Files with a tree-sitter grammar keep tree-sitter only (cheaper, no flicker). Requests are debounced
   (about 150 ms after the last edit) and cancelled when superseded.
8. **Status.** The file panel header shows the server state for the shown file (starting / ready / not installed /
   failed) with the server's name; "not installed" says which command was looked for. Settings lists the registry with
   found / not found and an on/off switch per server.

## Phase 2 (after MetalUI gap G35)

Hover (popover anchored to a text range), completion (caret-anchored list with ↑↓ / Return / Tab / Esc), squiggle
underlines instead of tints, cmd-click go-to-definition, signature help. Each needs MetalUI API (below); Alloy does
not build workarounds for MetalUI gaps (Alloy design non-goal). Phase 2 is planned once G35 lands.

## Non-goals (v1)

Rename, code actions, formatting, references list, workspace symbols, inlay hints, debugging (DAP), installing
servers, sending diagnostics to Claude sessions (a natural follow-up: tell the editing session about errors its edit
introduced, via the existing hook channel), multi-root workspaces, notebooks.

## Anti-goals

- Typing latency, scroll, idle CPU or memory regress measurably (benchmark and `tools/microbench.sh` gates). LSP I/O,
  JSON encoding / decoding and position conversion never run on the main actor; the main actor only applies
  finished decorations. No view body reads LSP state that changes per message (panes are `.equatable()`; keep LSP
  stores `@ObservationIgnored` except the narrow header status).
- A missing, slow, chatty or crashing server affects anything but its own features (no hangs, no beach balls, no
  unbounded memory: bounded queues, request timeouts, stderr captured to a capped log).
- Alloy writes outside its own data directory (never `~/.claude` or the project's `.claude/`) or sends anything
  over the network.

## Constraints

- Swift 6 language mode; package layout as today; tests with Swift Testing, using a fake LSP server executable
  target (scripted responses) so CI needs no real servers; an optional integration test runs against `sourcekit-lsp`
  when present (skipped otherwise).
- Privacy gate for the public repo applies to new docs and fixtures.
- MetalUI is read-only from Alloy; gaps go to the MetalUI session and `docs/metalui-gaps.md`.

## MetalUI gap G35 (filed with this design)

1. Public `CodeView` point → byte offset and byte range → rects (for hover and anchoring).
2. Hover callback with offset and a popover anchored to a text range.
3. Caret-anchored suggestion overlay whose keys (↑↓ Return Tab Esc) are routed to the app before CodeView consumes them.
4. Underline / squiggle `CodeStyle` (colour + style) on a highlight layer.
5. Line decorations and virtual rows from more than one owner (keyed sets merged by CodeView), plus gutter markers on
   real rows.
6. Cmd-click (modifier click) hook with the byte offset.
Phase 1 needs none of these.

## Left to the builder

Exact registry entries and arguments, JSON types (reuse `JSONValue` or small Codable structs), debounce values within
the bounds above, theme key names for diagnostic colours, header and settings layout within the existing style.
