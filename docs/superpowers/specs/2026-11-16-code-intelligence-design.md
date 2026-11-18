# Alloy: Code intelligence from language servers

Date: 2026-11-15. Status: draft for the user's review, revised after a builder cross-check against the code. Builds on
LSP v1 (`2026-11-12-alloy-lsp-design.md`), Code mode (`2026-11-15-alloy-code-mode-design.md`) and linters
(`2026-11-15-alloy-linters-design.md`).

## Intent and why

Alloy's language servers give go to definition, diagnostics and linter squiggles today. The user wants the rest of
what an editor gets from a server, as one list of features built in parallel:

- completion as you type
- signature help
- hover
- find references
- rename
- format, and format on save
- go to symbol
- code actions and quick fixes, including the Ruff, ESLint and Biome fixes, from a lightbulb at the caret

All of it has to stay inside the standing goal, "MetalUI and Alloy run as lite and fast as possible without giving
up quality". A missing, slow or silent server must cost nothing per keystroke.

## Where this stands in the code (verified)

These facts shape the design. Items marked "new" do not exist yet.

- **Ledger authors.** `Author` (AlloyCore, `Ledger/FileLedger.swift`) is `session(UUID) | user | outside`.
  It is `Codable` and persisted. Many switches use it: `PanelEditBar`, `CoordinationWarnings`, `TugOfWar`,
  `OverlapIndex` and the sidebar colours. User typing reaches the ledger only on save: `performSave` appends a
  `.user` record of the whole saved text. User records do show in the diff review as "You" gutter bars with Keep and
  Revert, because `DiffDecorationModel` takes every live record. But a user record holds everything typed since the
  last save, not one operation. See Decision 1.
- **Request target.** Only the singular `requestTarget(path:)` exists (`LSPManager.swift`). It returns the main
  server only. `syncTargets` is private and covers document sync only. **New:** a fan-out
  `requestTargets(path:roles:)` that returns the main server and the live linter entries of `doc.linterIDs`.
- **Diagnostics.** `LSPDiagnostic` keeps range (byte), severity, message, source and code. Parsing drops `data` and
  the raw LSP range. **New (model change):** the raw diagnostic object is kept per item (below).
- **Server requests.** `LanguageServer.answer(method:...)` handles only `workspace/configuration`, `workspaceFolders`,
  progress, register/unregister and the semantic tokens refresh. **New:** `workspace/applyEdit` handling, the
  `workspace/executeCommand` request, and the client capabilities `workspace.applyEdit` and `executeCommand`.
- **Opening files.** `Workspace.open(_:selecting:in:)` exists. Every `Workspace.open` **adds and activates a tab**,
  and a document exists only while some tab holds it. There is no "background buffer". Closed files are edited on
  disk instead (see Edits).
- **Undo.** `CodeSelectionState.transaction(_:)` already makes one undo step out of several range replacements, so
  format, fix and rename need no new MetalUI API for one undo step per file. **New:** `Workspace.undoGroups`, needed
  only if Decision 3 picks (a).
- **Menus.** `AppCommands.swift` has a "Go" menu with Go to Definition (plain F12) and a "View" menu. MetalUI's Edit
  menu takes additions through `CommandGroup(after: .pasteboard)`. `editMenu(edit:...)` in `CodePanel.swift` is the
  **gutter-bar menu of one session edit** (Keep, Revert and so on), not a text context menu. There is **no text
  context menu** on the `CodeView` today. MetalUI's located `contextMenu { point in ... }` can add one.
- **Problem list.** There is **no problems panel**. Diagnostics show as squiggles and as message virtual rows under
  the line (`DiagnosticDecorations`; virtual rows are decorations and cannot hold buttons), and F8 and ⇧F8 step
  through them (`codeKeyHandlers`).
- **Keystroke path.** `DocumentServices` (one per document, shared by its views) gets buffer changes through an
  observation `Task`. `drainEdits()` sends each batch to the highlight engine, `forwardToLSP` and every attached
  `OpenDocumentView`. Each pane has its own `OpenDocumentView` and its own `CodeSelectionState`.
- **Chat mode has code too.** Chat mode's `FilePanelView` shows the active tab in a `CodeView` (pane `.chat`), with
  F12 go to definition. Every feature here works there as well, so the Chat 88 guard applies.
- **Saving.** Alloy has **no explicit Save command**. Saves come from a 1 s autosave after the last edit
  (`Autosave`), from focus leaving the code view, from closing a tab and from `saveAll`. All of them go through
  `save(_:)` → `performSave` (a 4-pass write/merge loop that takes `doc.buffer.snapshot()` each pass).
- **Fake server.** `AlloyFakeLSP` is one `main.swift` scripted through the `FAKE_LSP_SCRIPT` JSON (`definition`,
  `semanticTokens`, delays, holds, `serverRequests`, crashes). The tests already run it as a linter with
  `role: .linter`, with a script per server id.
- **MetalUI, verified present:**
  - `CodeView.suggestionOverlay(isPresented:attachmentAnchor:...)`: keys go to the app's `onKeyPress` first, and
    nothing is offered while an input method has marked text (`CodeTextAnchor.swift`, CV-AQ/CV-AR).
  - `CodeView.popover(isPresented:attachmentAnchor:)` and `popover(item:attachmentAnchor:)`.
  - `onTextHover(delay:)`; it ends on any key, edit, press or scroll.
  - `gutterMarkerLane(_:)`.
  - `CodeGutterHit.Source.gutterMarker`.
  - Decoration owners: each owner is set on its own, at the cost of one merge per set.
  - MetalUIMarkdown.
  - Marked text lives in view state, never in the buffer, so the edit stream never sees a composition.
- **MetalUI, verified absent:**
  - **Only one text-anchored presentation per `CodeView`.** There is one `textAnchorBox` per view, and the modifier
    returns a `PopoverModifier`, not a `CodeView`, so a second one cannot be chained. This blocks completion and hover
    together (gap 4).
  - A snippet session (gap 1; shipped 2026-11-16).
  - A cross-buffer undo group (gap 2).
  - Named function keys (gap 5). Alloy uses the private-use characters `\u{f70b}` and `\u{f70f}` for F8 and F12.

## Approaches

1. **One request pipeline per feature, each hand-written like `definitionOutcome`.** This is simple to read. But it
   means eight copies of the version check, barrier, encoding and cancel logic, and eight places to get staleness
   wrong.
2. **A shared request kernel in `LSPManager` with thin parsers per feature, plus a keystroke-side scheduler per
   document view in AlloyKit (recommended, our call).**
   - The kernel, `send(_ feature:path:version:timeout:params:parse:)`, does target lookup, capability check,
     `waitUntilSent`, version compare, position encoding, cancellation and error mapping once. Each feature adds only
     its params and a parser.
   - The scheduler owns debounce and cancel for completion, signature help and the lightbulb, so each view has one
     timer, not three.
3. **Pull everything through a generic "LSP passthrough" (raw JSON to the UI).** This is the fastest to wire. But it
   puts JSON decoding on the main actor and leaks protocol shapes into views. Rejected.

## Goals

1. **Completion as you type.**
   - **Triggers.** An identifier character, after a 60 ms trailing debounce. A server trigger character, at once.
     ⌃Space.
   - **Popup.** It sits under the caret (`suggestionOverlay`, anchor `.caret`) and shows up to 50 rows: a kind glyph,
     the label, and the detail dimmed.
   - **Keys.** ↑↓ move. Return or Tab accepts. Esc closes. A server commit character accepts the item, then inserts
     itself.
   - **Filtering.** The list is filtered locally (`FuzzyMatch` on `filterText ?? label`) while the user keeps typing
     inside the same word, with no new request. A new request goes out only when the word start changes or the server
     marked the list `isIncomplete`.
   - **Order.** Fuzzy score first, then `sortText ?? label`, then label (our call).
   - **Resolve.** The selected item is resolved (`completionItem/resolve`) for docs and `additionalTextEdits`
     (auto-imports). The docs show in a side pane only while the popup is open.
   - **Snippets.** Items with `insertTextFormat` 2 are parsed with MetalUI's `CodeSnippet` LSP parser and inserted at the
     primary caret through `CodeSelectionState.insertSnippet`, with the view's indent unit. Tab and ⇧Tab step the
     placeholders, mirrors stay linked, Esc ends the session, and a new snippet ends the outer session. While the popup
     is open Tab accepts it; otherwise Tab goes to the session. Additional edits still apply. The plain-text path
     (`SnippetText`) remains the fallback for unusable snippets and non-editable views. Placeholders use the
     `snippetPlaceholderFill` theme token.
   - **Ids.** `completion-popup`, `completion-row-<i>`, `completion-doc`.
2. **Signature help.**
   - It opens on the server's trigger characters (typically `(` and `,`), or on ⌃⇧Space (our call).
   - It shows as a one-line strip **in the same suggestion overlay as completion**: above the list when both show,
     alone otherwise. The active parameter is in the accent colour.
   - ⌥↑ and ⌥↓ cycle overloads. It closes on the server's retrigger rules, on Esc, or when the caret leaves the call.
   - Id `signature-help`.
3. **Hover.**
   - `onTextHover(delay: 500 ms)` asks `textDocument/hover`. The answer renders as Markdown in the view's popover
     slot, anchored to the hovered range.
   - Diagnostics whose range contains the hovered offset show above the hover text: the main server's and every
     linter's, as already merged by the coordinator (our call).
   - ⌘I shows hover at the caret (our call). Chords such as ⌘K ⌘I are out of scope until a keymap supports them.
   - Id `hover-popover`.
4. **Find references (⇧F12).**
   - Results open in a list palette over the editor, reusing Quick Open's field and list, with a new
     `ListPaletteModel` for rows.
   - Rows are "path:line  preview", grouped by file and fuzzy-filterable. Return jumps through
     `Workspace.open(path, selecting:in:)`.
   - References outside the root never get a row. They show as a count line only ("3 more outside the project").
   - Ids `references-palette`, `references-row-<i>`.
5. **Rename symbol (F2).**
   - `prepareRename`, when offered, selects the range. Otherwise the word at the primary caret is used.
   - A field in the view's popover slot, anchored to the symbol, takes the new name. Gap 3: verify that it takes focus.
   - The returned `WorkspaceEdit` is applied all or nothing, as described under Edits.
   - Ids `rename-field`, `rename-summary`.
6. **Format document (⌥⇧F) and format selection.** Format selection has no default shortcut (our call: there are no
   chords, so ⌘K ⌘F is out). It is reached from the menu item, the context menu and, once it lands, the command
   palette. ⌥⇧F is also used by the plugins spec for its formatter, so both register one "Format Document" command,
   and the formatter choice picks the provider.
   - One `TextEdit[]` applied as one transaction gives one undo step.
   - Format selection uses the primary selection only.
   - **Format on save** works per language server, is off by default, and is bounded at 750 ms. When it runs is
     Decision 4. If the server is slow, absent or errors, the file saves unformatted and the status pill says why
     once per file per session (our call).
7. **Go to symbol (⌘⇧O).**
   - `documentSymbol` (hierarchical) opens in the same list palette, with rows indented by depth and a kind glyph.
     Typing filters, and Return jumps.
   - `@` in ⌘P switches Quick Open to this mode for the focused pane's active document (our call). If that document
     has no server or no `documentSymbolProvider`, the palette shows one inert row "No symbols for this file".
   - Ids `symbols-palette`, `symbols-row-<i>`.
8. **Code actions and quick fixes (⌘.).**
   - **Lightbulb.** A gutter marker on the caret line when any server reports actions for that line. It uses
     `gutterMarkerLane(true)` and its own decoration owner `lightbulb`, and is clicked through `onGutterBarClick` with
     source `.gutterMarker`.
   - **Menu.** ⌘. or a click on the lightbulb opens the action list **in the suggestion overlay** (our call): a keyed
     list like completion, whose keys stay with the view.
   - **Fan-out.** Requests go to the main server and every linter attached to the document. Results are merged with
     `isPreferred` fixes first, then quick fixes, then everything else, each labelled with its source ("Ruff: Remove
     unused import").
   - **Quick fixes for problems.** There is no problems panel (Decision 6). F8 moves the caret onto a problem, the
     lightbulb appears, and ⌘. lists the fixes for that diagnostic first.
   - **Ids.** `lightbulb`, `code-action-menu`, `code-action-<i>`.
9. **Menus and context menu.**
   - **Go menu:** Go to Symbol, Find References.
   - **Edit menu**, added after `.pasteboard`: Rename Symbol, Format Document, Format Selection, Quick Fix, Show Hover.
   - Each item is disabled unless the focused pane's active document has `lspOpen` and its server advertises the
     capability. When the command registry from the command-palette feature lands, these items register there instead
     of being hand-written in `AppCommands`.
   - **New text context menu** on the `CodeView`, through MetalUI's located `contextMenu`. It holds the same items and
     acts on the current selection, not on the press point (our call). It also adds Go to Definition.
   - **Ids.** `menu-go-symbol`, `menu-find-references`, `menu-rename`, `menu-format`, `menu-format-selection`,
     `menu-quick-fix`, `menu-show-hover`, and `ctx-` plus the same suffix for the context menu.

```
 ┌ editor ─────────────────────────────────────────────┐
 │ 12 │   let total = items.reduce(0, { $0 + $1.pri│ ) │
 │ 13 💡│              ┌──────────────────────────────┐  │
 │    │              │ ƒ price       Double  │ docs… │  │  completion-popup + completion-doc
 │    │              │ ƒ priority    Int     │       │  │
 │    │              └──────────────────────────────┘  │
 └─────────────────────────────────────────────────────┘
```

## Defaults (our calls)

- **Timing.**
  - Completion debounce: 60 ms trailing.
  - Signature help: immediate on trigger characters.
  - Hover: 500 ms.
  - Lightbulb probe: 250 ms after a caret move that is not typing, and 750 ms after typing stops.
- **Request timeouts.**
  - Completion: 2 s.
  - Resolve: 1 s.
  - Hover and signature: 2 s.
  - References, rename and symbols: 10 s.
  - Code actions: 2 s.
  - `executeCommand`: 5 s.
  - Format on save: 750 ms.
- **Caps.**
  - Popup: 50 rows.
  - Doc pane: 12 lines.
  - Decoded completion items: 5,000 per response. A longer list is cut and treated as `isIncomplete`.
  - References: 10,000 rows.
  - Rename: 1,000 files.
- **Format on save** is off for every server until turned on, with one switch per server.
- **Formatter choice** when several servers attached to a document advertise formatting:
  - A linter that formats (Ruff, Biome) wins over the main server. It is attached only when the project's config file
    exists, which signals the project's chosen formatter.
  - A per-language `formatter: <server id>` setting overrides this.
- **Multiple carets.**
  - Completion and signature help open only with a single selection. With more, ⌃Space does nothing.
  - Rename, code actions and hover-at-caret use the primary caret.
  - Format selection uses the primary selection.
- **Same file in two panes.** Each `OpenDocumentView` has its own scheduler, popup state and caret. Only the
  **focused** pane's view schedules or shows anything. The other view's scheduler stays idle, though both share the
  document's server sync.

## Non-goals

- Inlay hints, code lens, call and type hierarchy, semantic selection, folding ranges, and workspace-wide symbol
  search.
- An Outline sidebar tab (palette only, unless Decision 5 says otherwise).
- File create, rename and delete operations from a `WorkspaceEdit`. They are refused with a message.
- A problems panel (unless Decision 6 says otherwise).
- AI completions (Claude sessions already cover that).
- Multi-key chords.

## Anti-goals

- **No cost per keystroke without a server.** No timer, Task, observable write or request when `lspOpen` is false or
  the capability is missing.
- **No lost edits.** Rename, format and fix edits never apply to a buffer whose version moved since the request.
  Format on save never blocks or drops a save.
- **No frame cost when idle.** Popup, signature, hover and lightbulb state never touch observables that sibling views
  read.

## Constraints

- MetalUI only; it is never worked around. Gaps are forwarded.
- Theme values only.
- An accessibility id on every interactive view.
- Zero warnings.
- `swift test --no-parallel`.
- Shared Swift code goes only in AlloyLSP and AlloyKit. Linux and Windows get the same design with no platform
  substitutes. Function keys use the same mechanism as today's F8 and F12 until gap 5 lands.
- Never write `~/.claude` or a project's `.claude`.

## Design

### AlloyLSP

**Capabilities.** `ServerCapabilities` grows to cover:
- completion: trigger characters, resolve, commit characters
- signatureHelp: trigger and retrigger characters
- hover
- references
- rename, with prepare
- documentFormatting and rangeFormatting
- documentSymbol
- codeAction: resolve and kinds
- executeCommand: command list

**Client capabilities.** `clientCapabilities` adds:
- `workspace.applyEdit: true`
- `workspace.workspaceEdit.documentChanges: true`, with `resourceOperations: []` and
  `failureHandling: "abort"`
- `workspace.executeCommand`
- completion: snippetSupport, resolveSupport (documentation, detail,
  additionalTextEdits), `insertReplaceSupport`, markdown documentation
- hover: markdown
- signatureHelp: parameter labels as offsets
- rename: prepareSupport
- documentSymbol: hierarchical support
- codeAction: literal support, `isPreferredSupport`, `dataSupport`, resolveSupport for `edit`

The initialize payload grows by a few hundred bytes, which is negligible.

**Kernel.**
- **Signature.** `func send<R: Sendable>(_ feature: Feature, path: String, version: UInt64, timeout: Duration,
  params: (Position) -> JSONValue, parse: @Sendable (JSONValue, PositionEncoding, CodeSnapshot) -> R?) async ->
  LSPOutcome<R>`.
- **Outcomes.** `LSPOutcome` is `.answered(R) | .unavailable | .stale | .timedOut | .failed(String)`.
- **Errors.** `RequestCancelled (-32800)` and `ContentModified (-32801)` map to `.stale`, never `.failed`. Callers
  treat `.stale` silently: scheduled features re-request once if still relevant, and explicit commands retry once,
  then say "Server busy, try again".
- **Definition.** `definitionOutcome` is refactored onto the kernel.
- **Parsers.** There is one file per feature. Each decodes off the actor (`Task.detached`, as semantic tokens do) and
  returns byte-range Swift types: `CompletionList`, `SignatureInfo`, `HoverInfo`, `[ReferenceHit]`, `FileEdits`,
  `[DocSymbol]`, `[CodeActionItem]`.
- **Completion decode.** Completion parsing stops at 5,000 items. A rust-analyzer-sized list never reaches the main
  actor whole.

**Targets.**
- `requestTargets(path:roles:)` is new. It returns `[RequestTarget]` for the main server, linters or both, skipping
  dead entries, and each target carries its server's capabilities.
- `requestTarget(path:)` stays as the main-only shorthand.
- Code actions and formatter choice use the plural form.

**Diagnostics retention (model change).**
- `LSPDiagnostic` gains `raw: JSONValue?`: the server's diagnostic object as received, including range, code, source
  and `data`. It is `Equatable` by value.
- The raw value travels with the item and is replaced on the next publish, so it costs nothing beyond what the
  publish already allocated.
- Code-action context sends the raw diagnostics of that server whose byte range overlaps the request range.
- An action is matched to a diagnostic by **identity**: its `diagnostics` array contains an object equal to that raw
  value. If the server rewrote the object, matching falls back to equal (raw range, code, message) (our call).

**Edits from servers.**
- `workspace/applyEdit` is answered in `LanguageServer.answer`. It is not synchronous there: it forwards
  `(serverID, label, edit)` to the manager's event stream, and the reply waits on the coordinator's result,
  `{applied, failureReason}`.
- `workspace/executeCommand` is a kernel request, used by code actions that carry a `command`.

### Linter servers and their action shapes

The registry already runs `ruff server`, `vscode-eslint-language-server --stdio` and `biome lsp-proxy` as real
language servers. The design accepts every shape an action can take, and the fake covers each one:

| Shape | Who (per their docs) | Handling |
| --- | --- | --- |
| `edit` inline | Biome | apply |
| `data` only, `edit` after `codeAction/resolve` | Ruff | resolve on choose (1 s), then apply |
| `command` only | ESLint (`eslint.applySingleFix` and others) | `workspace/executeCommand`; the server then sends `workspace/applyEdit`, which goes to the same applier |
| `edit` and `command` | any | apply the edit, then execute the command |

A server without `codeActionProvider` is never asked. A `command` the server did not list in
`executeCommandProvider.commands` is not shown.

### AlloyKit

**Coordinator.** `LSPCoordinator` gets a main-actor wrapper per request. Each wrapper is preceded by `.barrier`, as
definition is.

**Scheduler.**
- `OpenDocumentView` (per pane) gets `scheduler: IntelligenceScheduler?`. It exists only while the document has
  `lspOpen` and some attached server advertises completion, signature help or code actions. It is made when
  capabilities arrive and dropped on close.
- **Where it hooks.** `DocumentServices.drainEdits()` already hands each batch to every attached view. The view passes
  the batch to its scheduler only if it is the focused pane's view.
- **Decision is synchronous and allocates nothing.** The scheduler looks at the batch's last `CodeEdit`. Its origin
  must be `.typing`, its insertion must end at this view's primary caret, and it reads the byte before the caret from
  the snapshot already built. Each byte check is against **stored** sets: `triggerBytes: Set<UInt8>` (ASCII trigger
  characters) and `identifierBytes` (a 256-bit bitmask). Non-ASCII trigger characters, which are rare, go in a
  `Set<Unicode.Scalar>`. There are no closures and no captures.
- **Then.** If nothing applies, it returns. Otherwise it cancels its previous Task and starts one that sleeps for the
  debounce.
- **Stale answers.** Answers are dropped when the tab, buffer version or caret line moved, like `startDefinition`.
- **When there is no scheduler.** A view with no scheduler does exactly what it does today.

**Presentation state.**
- **`IntelligenceOverlayModel`** (`@Observable`) holds completion, signature and action-list state. It is owned by the
  `OpenDocumentView` as an `@ObservationIgnored let`. **No view body reads it except the overlay's content closure.**
  `OpenDocumentView`'s own body never touches it, so siblings never rerun. This is guard (d).
- **`PopoverSlotModel`** (`@Observable`) holds hover and rename state, under the same rule.
- **Writes.** The model is written only when the visible rows or the selection change, never when a request starts.
- **Filtering.** Local filtering runs off-main on a copy of at most 5,000 items. It carries a generation counter and
  `Task` cancellation, like `QuickOpenModel`, and only the top 50 come back.
- **Docs cache.** Resolved docs render to Markdown once per item. They are cached in the model by item index and
  dropped when the popup closes, so moving the selection back and forth re-renders nothing.

**Two text-anchored slots per `CodeView`** (needs MetalUI gap 4):
- Slot A: a `suggestionOverlay` for completion, signature help and the code-action list. These are keyed lists, and
  keys stay with the view.
- Slot B: a `popover(item:)` for hover and the rename field, which can take focus.

Until gap 4 lands, a view can chain only one, so the task order puts slot B features (hover, rename) and slot A
features in separate tasks, and the second slot's task waits for the gap. Hover ends on any key, so the two never
fight for the pointer.

**Disabled contexts.** No scheduler and no edit commands for:
- a read-only document (`state != .editable`; such documents never reach a server, so `lspOpen` is false)
- the old-text pane of side by side
- a document with no server

Menu and context-menu items are disabled there rather than failing.

### Edits (`WorkspaceEditApplier`, AlloyKit)

1. **Normalise.** Convert `changes` and `documentChanges` (text edits only) to `FileEdits = [(path, version: Int?,
   [ByteEdit])]`. Positions use the negotiated encoding (`Positions`, UTF-8 or UTF-16):
   - A line past EOF clamps to EOF.
   - A character past the line end clamps to the line end, as LSP specifies.
   - A position inside a UTF-16 surrogate pair or a UTF-8 sequence **rejects the whole edit**: "server sent an invalid
     edit".
   - Paths outside the root reject the whole edit.
   - Resource operations reject the whole edit.
   - `changeAnnotations` are ignored, because every applied edit is reviewable afterwards (our call).
2. **Validate per file.**
   - Edits are sorted by start, stably. Two edits at the same offset insert in array order.
   - **Overlapping ranges reject the whole edit.**
   - `additionalTextEdits` that overlap the main completion edit are dropped. The item applies without them and a
     debug log line is written.
3. **Version check, all files before any write.**
   - An open document with a numeric `version` must equal the version Alloy last synced for it.
   - An open document with `null` (or with `changes`) must have the same buffer version as when the request was sent.
   - A closed file must have the same disk stamp as when it was read for validation.
   - Any mismatch applies nothing and reports "File changed, rename not applied".
4. **Apply.**
   - **Open document:** one `CodeSelectionState.transaction` per document, edits applied highest first, which gives
     one undo step. The document is then saved through `Workspace.save(path)`, so the ledger gets a record and the
     server sees the text.
   - **Closed file:** no tab is opened. The text is read off-main, the edits are applied, the file is written
     atomically with `Workspace.writeKeepingMode`, and `appendToLedger(path, ..., edits: [(author, text)])` records
     it so the file watcher does not attribute it as `.outside`. This is the project-search path.
   - **Group.** Every record of one apply carries one `editGroup` id (Decision 1). The rename summary
     (`rename-summary`) lists the files with Keep All and Revert All. Revert All loops `revertInEditor` or the ledger
     revert over the group.
5. **Partial failure.**
   - Files are written in order. A write that fails after earlier ones succeeded stops there and reports "Rename
     applied to 7 of 9 files; 2 failed: ...". The applied ones stay reviewable and revertable as a group.
   - A server crash mid-rename never applies anything, because edits apply only after the full response.
   - Undo after a file was closed or changed outside goes through the existing ledger revert and its
     `revertConflicts` path.
6. **Completion item edits.**
   - `textEdit` and `insertReplaceEdit`: Return and Tab use the **insert** range (our call).
   - The range must be on the caret line and contain the caret. Otherwise the item falls back to replacing the word
     before the caret with `insertText ?? label`.

### Save (format on save)

`Workspace` is in AlloyCore and cannot call AlloyLSP, so formatting is an injected hook, like `closeGate` and
`onSaved`: `Workspace.formatBeforeSave: (@MainActor (EditorDocument) async -> Void)?`, set by AlloyKit.

`save(_ path:, format: Bool = false)` runs the hook inside the serialised save task, in this order:

1. `autosave.cancel(path)`
2. When `format` is true and the language's switch is on, await the hook. It has a 750 ms deadline and applies its
   edits only if `doc.buffer.version` still equals the version it asked about, as one transaction.
3. `performSave(doc)`, unchanged.

The formatting transaction is an ordinary buffer edit. LSP sync sees it. Autosave re-arms, then finds a clean
document and does nothing.

Concurrent changes during the await:
- An outside edit or a `mergeDisk` changes the buffer version, so the format is dropped and the file saves
  unformatted.
- A session edit that reaches the ledger meanwhile is handled by `performSave`'s existing merge loop.

Which save points pass `format: true` is Decision 4.

### Settings and persistence

- `AlloySettings.languageServers` gains two fields per entry, with lossy decode so old files stay valid:
  - `formatOnSave: Bool?` per server
  - `formatter: String?` per language
- Settings rows: `settings-lsp-format-on-save-<id>`, `settings-lsp-formatter-<language>`.
- The ledger record gains `editGroup: UUID?`, decoded leniently. Decision 1 decides whether that or a new author is
  used.
- Nothing else persists. Popups, references and symbol lists are session state.

### Failure modes

- **Server absent or capability missing.** Items are disabled and there is no scheduler.
- **Server slow.** The debounced request is cancelled by the next edit (`$/cancelRequest`). A timeout drops silently
  for popups and the lightbulb, and shows a transient message for explicit commands ("Rename timed out").
- **Cancelled or ContentModified.** Treated as stale: silent, with one retry (kernel).
- **Server crash.** The existing restart policy applies. Open popups and the lightbulb clear, and pending
  `applyEdit` replies are abandoned.
- **Edit conflict.** All or nothing (Edits, step 3).
- **Invalid edits.** Encoding, overlap, outside the root or resource operations reject the whole edit (Edits, step
  1).

## Performance plan

The guards are elements requested per frame: Chat 88, Code 91, 107 and 117. Idle frames cost 0. None may rise.

- **Idle.**
  - No timers.
  - No observation reads beyond today's.
  - Lightbulb probes run only after a caret move or after typing stops, never on a frame.
  - The probe sends one request per attached server (at most main plus the configured linters). The previous probe
    is cancelled on the next move.
  - Results are cached per (buffer version, caret line), so moving within a line asks nothing.
  - The marker is set through its own decoration owner, which costs one owner merge, and only when the marker line
    changes, never per frame.
- **Typing without capability.** The scheduler does not exist, and `drainEdits` does exactly what it does today.
- **Typing with capability.**
  - One byte lookup against a stored set, one Task replacement after a hit, and no observable write.
  - The overlay model is written only when the visible rows change.
  - Decoding and filtering run off-main, are capped, and can be cancelled.
- **Hidden presentations.** Guards (c) and (e) assert that a closed overlay or popover adds 0 elements and costs 0
  on idle frames. If the anchor box resolves while hidden and that shows up, it is reported as a MetalUI gap, not
  worked around.
- **New guard cases** in `CodeModePerformanceTests` (91/107/117) and the Chat file-panel equivalent in
  `ViewRerunTests` (88):
  - (a) server present and idle
  - (b) server present, typing, no completion capability
  - (c) completion capability, popup closed, typing whitespace
  - (d) popup open, typing within the word: only the overlay content re-runs, and sibling bodies stay at 0
  - (e) lightbulb shown, idle frame cost 0
  - (f) same file in two panes, typing in one: the other pane's view does no scheduler work
- **Benchmark.** Keystroke-to-frame time with a fake server answering in 0 ms and in 500 ms, and with a
  5,000-item completion reply, before and after. Results go in the task report.

## MetalUI gaps (to forward)

1. **Snippet session in CodeView.** (Shipped 2026-11-16: `CodeSnippet`, `insertSnippet(_:replacing:indentUnit:)`, `CodeTheme.snippetPlaceholder`.)
   - Wanted: `CodeSelectionState.insertSnippet(_ snippet: CodeSnippet, replacing: Range<Int>) -> CodeTransactionID`.
     `CodeSnippet` holds the text plus tab stops (`$1`, `${2:default}`, `$0`, and linked placeholders with the same
     index).
   - The view runs the session: Tab and ⇧Tab move between stops, linked placeholders edit together, and Esc or
     leaving the range ends it. `isSnippetActive` is readable.
   - There is no SwiftUI equivalent. The reference is VS Code's SnippetSession.
2. **Cross-buffer undo group.**
   - Wanted: `CodeBuffer.undo(transaction:)` plus `onUndo(perform: (CodeTransactionID) -> Void)`, so that ⌘Z in one
     buffer can undo the matching transactions in others.
   - The SwiftUI equivalent is `UndoManager` grouping.
   - Needed only if Decision 3 picks (a).
3. **Focused text field in a text-anchored popover.**
   - Confirm that `CodeView.popover(item:attachmentAnchor:)` content can hold a `TextField` that takes focus and keys
     away from the `CodeView`, with `onSubmit` and Esc, and gives focus back on dismiss. If it cannot, add that.
   - SwiftUI equivalent: `.popover` with `@FocusState`.
4. **Several text-anchored presentations on one `CodeView` (blocking).**
   - Today a view holds one `textAnchorBox`, and the modifier returns `PopoverModifier<CodeView, P>`, so a second
     presentation cannot be chained.
   - Wanted: at least one `suggestionOverlay` and one `popover` on the same view at once. Either
     `PopoverModifier<CodeView, P>` forwards the text-anchor modifiers to its content, or there is one box per
     presentation.
   - The SwiftUI equivalent is chaining `.popover` modifiers.
5. **Named function keys (non-blocking).**
   - Wanted: `KeyEquivalent.f1` … `.f12`, with the same meaning on every backend, so that F2, F8, F12 and ⇧F12 do not
     depend on AppKit's private-use code points on Linux and Windows.
   - SwiftUI has none either. The closest is AppKit's `NSF1FunctionKey`.

## Testing strategy

**Fake server (AlloyLSP).** `AlloyFakeLSP` gains two script keys:
- `replies`: `{ "<method>": [ {result?, error?: {code, message}, delayMs?, hold?} ] }`. Replies are consumed in order,
  and the last one repeats.
- `afterRequest`: `{ "<method>": [ {method, params} ] }`. These are server→client requests sent after the reply, such
  as an `executeCommand` followed by `workspace/applyEdit`. The client's answer goes to the log.

Linter-role fakes use the existing `role: .linter` configs with a script per server id.

**AlloyLSP suites:**
- `CompletionTests`: isIncomplete, resolve, the 5,000-item cap, insertReplaceEdit.
- `HoverSignatureTests`.
- `ReferencesTests`.
- `RenameTests`: prepare, `documentChanges` with numeric and null versions, a version mismatch, an overlapping or
  unsorted edit, a range inside a surrogate pair, a range past EOF, a resource op refused.
- `FormattingTests`: formatter choice between main and linter.
- `SymbolsTests`.
- `CodeActionTests`: main plus linter fan-out; the edit, resolve, command and `applyEdit` shapes; the raw diagnostic
  round trip; matching by identity.
- Cancellation, `-32800` and `-32801` as stale, and stale-version tests for the kernel.

**AlloyKit tests** mirror `DefinitionPanelTests`:
- Popup: open, accept, commit character, Esc. A stale answer is dropped. There is no popup with multiple carets, and
  only the focused pane shows one.
- Rename: all or nothing across open and closed files; a closed file is written without opening a tab and recorded
  as not outside; partial failure reported; one undo per file; Revert All of the group.
- Format on save: the timeout path, the version-moved path, and autosave per Decision 4.
- The lightbulb and ⌘. after F8.
- Menu and context-menu enablement for read-only documents, documents with no server, and side by side.

**Other.** The performance guards above, and `SettingsViewTests` for the new rows.

## Suggested task breakdown

1. Capabilities, client capabilities and the request kernel, with error mapping. Refactor definition onto it. This
   blocks the rest.
2. Raw diagnostic retention, `requestTargets(path:roles:)`, fake server `replies` and `afterRequest`. Runs in parallel
   with 1.
3. Hover (popover slot B). The smallest end-to-end task: it proves the kernel and the popover.
4. `ListPaletteModel`, go to symbol, references and `@` in ⌘P.
5. `WorkspaceEditApplier` (validation, all or nothing, closed-file path, `editGroup`), format document and selection,
   formatter choice, the format-on-save hook and settings.
6. Rename, on 3, 5 and gap 3, with the rename summary and Keep All / Revert All.
7. `executeCommand`, `workspace/applyEdit`, code actions, lightbulb and ⌘. (slot A), on 2 and 5.
8. Scheduler and completion popup with plain-text inserts, then signature help (slot A).
9. Snippets, on gap 1 and Decision 2. (Done 2026-11-16, branch feat/snippets.)
10. Menus, the new text context menu and shortcuts, registered in the command registry if it has landed. Performance
    guards land with each UI task, not at the end.

Tasks 3, 4, 5 and 8 run in parallel after 1, and 2 runs in parallel with 1.

Whichever of slot A (7, 8) and slot B (3, 6) merges second needs MetalUI gap 4. Forward gap 4 first.

## Decisions for the user

1. **How rename, format and fix edits are attributed in the ledger.** This is the same question as project search's
   replace attribution and should be decided once for both.
   - (a) `Author.user`, plus an `editGroup` id on the record (lenient decode, no migration). The diff review shows
     them as "You", with Keep All / Revert All per group.
   - (b) New `Author` cases (`.rename`, `.format`, `.fix`). Clear in the UI, but it needs a persisted-ledger migration
     and touches every switch over `Author`.
   - (c) Plain `.user` with no group. The edits merge into the next save's record, and there is no group revert.
   - **Recommended: (a).**
2. **Snippet completions before MetalUI gap 1 ships?** (Superseded 2026-11-16: the session shipped; 2(a) no longer applies.)
   - (a) Insert snippets as plain text with the placeholders stripped and the caret at `$0`, and upgrade later.
   - (b) Hold snippet items back (do not advertise `snippetSupport`) until the session API lands.
   - **Recommended: (a).**
3. **Rename undo.**
   - (a) One ⌘Z undoes the rename in every file. This needs MetalUI gap 2 and a new `Workspace.undoGroups`.
   - (b) ⌘Z undoes per file, and Revert All in the rename summary or the diff review undoes every file at once.
   - **Recommended: (b) now, (a) when the gap lands.**
4. **When format on save runs.** Alloy has no Save command, and autosave fires 1 s after typing stops.
   - (a) Only at deliberate save points. Add a ⌘S Save command (Ctrl+S elsewhere), and treat focus leaving the
     editor and tab close as deliberate too. Autosave never formats.
   - (b) On every save, autosave included. The text reformats under the caret about a second after each pause.
   - (c) No format on save, only ⌥⇧F.
   - **Recommended: (a).**
5. **Symbols: palette only, or also an Outline sidebar tab?**
   - (a) The ⌘⇧O palette only. Lighter, with no sidebar cost.
   - (b) The palette plus an Outline tab beside the reserved Search and Git slots.
   - **Recommended: (a).**
6. **A problems panel?** There is none today, so quick fixes are reached from the lightbulb and ⌘. after F8.
   - (a) No panel in this feature.
   - (b) Build a Problems panel listing the main server's and the linters' diagnostics across open files, with a Fix
     button per row (`problem-fix-<i>`) that uses the same matching by identity.
   - **Recommended: (a).** The panel is its own feature and can reuse the matching later.


## Approved decisions (2026-11-16)

The user approved every recommendation above ("Approved build it"). Binding:
- 1(a) ledger: `Author.user` plus an edit-group id on `EditRecord` (lenient decode), shared with project search.
- 2(a) snippets inserted as plain text until the MetalUI snippet session lands. (Superseded 2026-11-16: the session shipped; 2(a) no longer applies.)
- 3(b) rename undo per file plus Revert All; (a) once MetalUI cross-buffer undo lands.
- 4(a) format on save only at deliberate saves: a new ⌘S Save command, focus leaving the editor, tab close. Autosave never formats.
- 5(a) symbols in the ⇧⌘O palette only. 6(a) no Problems panel.
- Shared command registry: commands this feature adds register in the one shared `CommandRegistry` (see command-palette.md).
