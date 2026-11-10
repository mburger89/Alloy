# MetalUI gaps

Gaps G1-G7 come from spec section 5. Each was sent to the MetalUI session. Stopgaps in Alloy stay minimal and are logged here.

## G1 Code view
- Status: adopted (Plan 4 Task 6)
- Use case: show large files with per-range styling, line numbers and gutter decorations (author colors).
- Adopted as: `CodeView` in `Sources/AlloyKit/Code/CodePanel.swift`, editable, with tree-sitter highlighting (`CodeViewHighlighter`), author gutter bars and tints (`CodeLineDecoration`), removed lines as `CodeVirtualRow`s, sub-line author backgrounds (`.annotations` layer), find (`findMatches`) and gutter bar click / context menu. The stopgap `LazyVStack` rows are removed.
- Open: after `applyExternalReplacement` / `applyExternalEdits` the caret may land in the wrong place until MetalUI PR #241 is merged into the held checkout; no stopgap is built. (#241 is now in the checkout; no Alloy change was needed.)

## G2 Block markdown
- Status: adopted (Plan 3 Task 9)
- Use case: render chat replies with code fences, lists and headings.
- Adopted as: `Sources/AlloyKit/MarkdownText.swift` renders `MarkdownBlockView`s per block inside the transcript's lazy rows, with `alloyMarkdownTheme` (`codeWraps: false`, `tableScrolls: true`). Assistant text, plan cards and command-output notices use it. `.codeHighlighter` is left to Plan 4.
- Copy stopgap (removed, see G2b): an `AlloyClipboard.write` hook plus Alloy's own Copy button on top-level code blocks.
- Limit (gone with G2b): fences nested in lists or quotes had no Copy button.

## G2b Clipboard write from a view and a built-in code Copy button
- Status: adopted (MetalUI #238; the stopgap swap)
- Adopted as: `MarkdownTheme.showsCodeCopyButton = true` in `alloyMarkdownTheme`. MetalUI's own button (an icon labelled "Copy code") replaces Alloy's, so it also covers fences nested in lists and quotes. `@Environment(\.clipboard)` is used by the composer's paste validator (G10).
- Stopgaps removed: `AlloyClipboard.write` (and `readImage`/`hasText`, see G10), their setup in `Sources/Alloy/main.swift`, and Alloy's own Copy button.
- Changed ids: the old `copy-code-<blockID>-<n>` is now `copy-code-<blockID>-<top-level block id>-<n>` (G15, MetalUI #247). Bench does not use these ids.

## G3 Icons
- Status: adopted (Plan 3 Task 6)
- Use case: an icon per chat block type and in the sidebar.
- Adopted as: `Image(systemName:)` for the block chrome (`Sources/AlloyKit/BlockStyle.swift`). Six names are outside MetalUI's bundled set and draw on macOS only: the first five from Plan 3 (`checklist`, `questionmark.bubble`, `list.bullet.clipboard`, `puzzlepiece.extension`, `info.circle`) and `envelope` (the session-message row, Plan 5b Task 5). The six draw on macOS only; on Linux and Windows the row would show no icon until MetalUI bundles them, and the row's text and ids are unaffected. Not yet filed upstream: send the six names to the MetalUI session.
- Upstream: the five icons are merged in MetalUI (7ac6e929, together with paperclip, photo and gearshape). Alloy picks them up when `../MetalUI` is fast-forwarded after Plan 3.

## G4 Tabs
- Status: adopted (Plan 4 Task 8), no stopgap: `FileTabStrip` in `FilePanelView.swift` wraps MetalUI `TabStrip` with `.onCloseTab` and `.onMoveTab`. No `TabBar` stopgap.
- Use case: tabbed file panel on the right.
- Notes: `TabStrip` binds no keys (Alloy's `GlobalKeys` does, as button shortcuts). Tabs carry the ids `tab-<path>` and `tab-close-<path>` (G13).

## G5 Two-axis scrolling
- Status: not needed. `CodeView` scrolls on both axes itself, so no `ScrollView` with two axes is used.
- Use case: horizontal and vertical scrolling for wide code.
- Stopgap: none.

## G6 Variable-height virtualized list
- Status: adopted (Plan 3 Task 6)
- Use case: long chat transcripts with variable-height rows, pinned to the bottom.
- Adopted as: `TranscriptView` puts `.defaultScrollAnchor(.bottom)` on its `ScrollView`; the `ScrollViewReader`/`TailKey` stopgap is removed.

## G7 Perf instrumentation
- Status: landed in MetalUI PR #219 (4d4c59db); wiring into Alloy deferred until the local checkout includes it
- Use case: signposts and frame-time hooks for the benchmark harness (Plan 2).
- Stopgap: wall-clock measurement from outside the process; no per-frame attribution.
- Wanted API: signposts / frame-time hooks.

## G8 Suggestion overlay
- Status: adopted, no stopgap
- Use case: the composer's `/` and `@file` suggestion lists floating over the chat.
- Adopted as: MetalUI's suggestion overlay.

## G9 Open a Menu from code
- Status: adopted (MetalUI #239; the stopgap swap; logged by Plan 3 Task 10 as "G8")
- Use case: `/model` with no argument must open the composer's model menu (`Session.requestModelPicker`).
- Adopted as: `.menuPresented(Binding<Bool>)` on the `model-menu` `Menu`, bound to `Session.requestModelPicker` (dismissal writes false). The inline choice row and its ids `model-choice-<alias>` / `model-choice-cancel` are removed, as is the Esc reset in `ComposerModel.handleKey`.
- Note: on macOS the `NSMenu` is modal, so writing false from code cannot close an open menu; it closes when the user picks or dismisses.

## G10 Image paste into a focused TextEditor
- Status: adopted (MetalUI #241; the stopgap swap; logged by Plan 3 Task 11 as "G9")
- Use case: the composer's TextEditor must take an image on the clipboard as an attachment on Cmd-V.
- Adopted as: `.pasteDestination(for: ImageData.self, ...)` on the editor (MetalUI has no `onPasteCommand`; `pasteDestination` is the API). A focused field now offers its paste to the destination first, so the validator returns `[]` whenever the clipboard also holds text (`@Environment(\.clipboard).hasContent(of: .text)`): text, and a text+image clipboard, still reach the field (Plan 3 ruling: text wins).
- Stopgaps removed: the Cmd-V branch in `ComposerModel.handleKey` and `AlloyClipboard.readImage` / `hasText`.

## G11 Caret position of a TextEditor on macOS 14
- Status: adopted (MetalUI #241; the stopgap swap; logged by Plan 3 Task 11 as "G10"; caret note from Task 12)
- Adopted as: `TextEditor(_:text:selectedOffsets:)` bound to `ComposerModel.caret` (`Range<Int>?`, `Character` offsets). Dropped-file mentions and `/` and `@file` completions now insert at the caret, and a token is the one that ends at the caret; text after it stays. `ComposerModel.replaceDraft(_:caret:)` writes the draft and the caret together, because an external text change otherwise moves the caret to the end (the new MetalUI rule applies only without a selection binding).
- Stopgaps removed: append-to-end mentions and the end-of-draft-only token rule.

## Unfiled: clicking a non-focusable control does not blur a focused TextField
- Status: possible new gap, not yet filed with MetalUI
- Example: with the session rename field focused, clicking a button does not blur it, so the rename is not committed by the click.
- Stopgap: the rename commits on focus loss via `onChange` (`fix(ui): commit rename on focus loss via onChange`).

## Known hazard for Plan 6 (not a MetalUI gap): I8 main-actor diff and ledger re-encoding
- Where: `Workspace.handle` runs on the main actor for every tool result. It calls `ledger.record`, recomputes
  the file's full `diffLines()` (memoised only per ledger version) and slices it for each new edit, then
  `persistLedger()` re-encodes and writes the entire project ledger as JSON.
- Why it matters: with large files or many edits, every tool result costs work proportional to the file's history
  and to the whole ledger on the main actor, so a burst of tool results can stall the UI.
- Deferred by ruling to Plan 6: move diffing and persistence off the main actor (incremental or debounced saves,
  per-file persistence). Do not fix before then.

## G12 CodeView gutter context menu ignores the view's position
- Status: adopted (MetalUI #243; found in Plan 4 Task 6)
- Fixed upstream: `gutterBarContextMenu` opens at any view offset. `CodePanelTests.contextMenuOffersTheFourActions` runs plainly (the `withKnownIssue` wrapper is removed) and Keep, Revert, Show in chat and Side by side are each tested through the menu.
- There was no stopgap.

## G13 Per-tab accessibility identifiers on TabStrip
- Status: adopted (MetalUI #244; found in Plan 4 Task 8)
- Adopted as: `FileTabStrip` passes `accessibilityIdentifier: "tab-\(path)"` and `closeAccessibilityIdentifier: "tab-close-\(path)"` on each `TabStripItem`; the container keeps `file-tabs`. The tab tests find tabs by these ids, and `TabsTests.tabIdentifiersSurviveReorderAndClose` checks they follow the path after a reorder and a close.
- There was no stopgap beyond role-and-label filtering in tests, now removed.

## G14 Input-method composition state is not readable from `onKeyPress`
- Status: merged (MetalUI #245), SDL-only; no Alloy change needed. MetalUI found that on macOS keys already go to the input context first, so a composing input method sees ↑ ↓ Esc before quick-open's `onKeyPress` does. The fix MetalUI is making is SDL-only (Linux and Windows).
- Original symptom (found in Plan 4 Task 8): it looked as if quick-open's ↑ ↓ Esc could act on keys meant for the candidate window.
- Wanted API: none from Alloy for macOS.
- Notes: the global shortcuts (⌘P, ⌘W, ⌃Tab, ⌘1-9) remain `Button.keyboardShortcut`s and Return uses `onSubmit`.

## G15 Code-block Copy button identifier and "Copied" feedback
- Status: adopted (MetalUI #247)
- Adopted as: `theme.codeCopyButtonIdentifierPrefix` set per top-level block in `MarkdownTopBlock` (see the note below). The tests find the button by id, and `MarkdownChatTests.copyButtonShowsCopiedThenReverts` presses it and checks the "Copied" label and its return after 1.5 s on the window's clock.
- Alloy-side note: MetalUI numbers the buttons from 0 inside each `MarkdownBlockView` and Alloy renders one per top-level block, so `MarkdownTopBlock` gives each its own prefix, `copy-code-<blockID>-<top-level block id>-<n>`. The ids are unique in the transcript and stable while a reply streams.

## G16 Bundled symbol table lacks `eye.circle` and `eye.slash.circle`
- Status: open (filed in polish batch A)
- Used by: the chat code block's expand/collapse eye (`ChatCodeBlock`). On macOS `Image(systemName:)` draws the real SF Symbols, so the eye renders there.
- Gap: `BundledSymbols` (the Linux and Windows route) has no entry for either name. Lucide has `eye` and `eye-off`; the circled variants would need a circle drawn around them or the closest icons mapped.
- Wanted API: map `eye.circle` and `eye.slash.circle` to bundled icons. Alloy uses the SF names unchanged and has no stopgap.

## G17 CodeView: first line number
- Status: open (filed in polish batch A, fix round 1)
- Used by: the chat code blocks show a Read of lines 40-80 with the file's real numbers. `CodeView` always numbers from 1, so Alloy draws its own per-line rows instead of a read-only `CodeView`.
- Wanted API: `CodeView.firstLineNumber(_ n: Int)` (or a `lineNumberOffset`) so the gutter starts at `n`, plus a way to blank the number of a row (shell `tail` output has an unknown start).

## G18 TextEditor: size to content up to a cap, then scroll
- Status: adopted (MetalUI 2f0b43c5). The composer is `TextField(text:selectedOffsets:axis: .vertical).lineLimit(1...8)`: 24 pt at one line, 16 pt per line including wrapped lines, 136 pt cap, then it scrolls. The field submits on ⇧Return (divergence 232..234), so `ComposerModel.handleKey` now inserts the ⇧Return line break itself (`insertNewline`) before the field sees the key; every key does what it did before. Original report follows.
- Filed in polish batch B.
- Used by: the composer, which should start at one line, grow to about 8 lines and then scroll.
- Gap: `TextEditor` is greedy; `.fixedSize(vertical: true)` makes it take its ideal (content) height, so it starts at one line and grows. But the grow cannot be bounded. `.frame(maxHeight:)` around the fixed-size editor clamps the box while the editor is still laid out at its full ideal height (measured 672 pt for 40 lines under a 128 pt frame), so it neither scrolls nor follows the caret. Putting `frame(maxHeight:)` inside `fixedSize` or around a `VStack`/`ProposalScrollView` made the frame take its maximum even for an empty editor. `TextEditor` ignores `.lineLimit(1...8)`.
- Wanted API: `TextEditor` honouring `.lineLimit(_ range)` (SwiftUI's growing editor), or an ideal height clamped to the proposal so `frame(maxHeight:)` plus the editor's own scrolling works.
- Stopgap (removed on adoption; polish B fix round 1): `ComposerView.editorHeight(draft:)` sets an explicit `.frame(height:)` of `min(8, max(1, logical lines)) * 16` pt. The editor scrolls and follows the caret inside that frame by itself. Wrapped lines do not count, so one long line stays one row and scrolls. Replace it with `TextField(axis: .vertical).lineLimit(1...8)` (or the TextEditor equivalent) once MetalUI ships it; the 16 pt row height is the default 13 pt font and is wrong for other font sizes.

## G19 TextEditor placeholder contrast
- Status: requested (forwarded to the MetalUI session by the coordinator)
- Used by: the composer's "Message Claude" placeholder.
- Gap: `TextEditor` draws the placeholder at the text colour times 0.45. Measured against the composer's `surface` fill (ContrastAuditTests, `composer.placeholder`): 2.92:1 light, 3.95:1 dark; WCAG AA wants 4.5:1. The factor is fixed, so no Alloy-side text colour can reach it (pure black at 0.45 on white is about 3.4:1).
- Wanted API: a higher factor (about 0.6 light) or a `placeholderColor`/`placeholderStyle` override.

## G20 TabStrip hover contrast
- Status: requested (forwarded to the MetalUI session by the coordinator)
- Used by: the code panel's file tabs.
- Gap: an unselected tab's ink is textPrimary at 0.62 over `surfaceSecondary` plus a textPrimary 0.06 hover wash. Measured (`tabs.hover`): 4.40:1 light (needs 4.5:1); dark passes. The unhovered pair passes.
- Wanted API: raise the unselected ink alpha slightly (about 0.68), or expose it.

## G21 `Color.secondary` is too faint on tinted fills
- Status: open (filed in polish batch B)
- Used by: every secondary label in Alloy (status line, summaries, gutter numbers).
- Gap: `Color.secondary` is textPrimary at 0.588 (light) / 0.648 (dark). Measured light ratios before Alloy replaced it with `MutedInk`: sidebar 4.29, empty chat state 4.42, block summaries 4.19 to 4.36 (thinking 4.22, web 4.21, error 4.11), code-block gutter 4.18 to 4.27, session mode badge 3.98 to 4.04. Dark passes everywhere.
- Wanted: a light-scheme alpha near 0.68, or a theme key for secondary ink. Alloy sidesteps it with its own token; an app using `.secondary` directly hits the faint value.

## G22 List selection defaults to the accent under unchanged text
- Status: open (filed in polish batch B)
- Used by: the sessions list.
- Gap: a selected `List` row is filled with the environment tint, else the theme accent (2563EB light, 60A5FA dark), and its text keeps the normal colours. Measured: primary text 3.44:1 light / 2.17:1 dark; secondary text 2.21:1 / 1.67:1; session dots 1.0 to 1.4:1. Unreadable unless the app overrides it.
- Alloy workaround: `.tint(.sessionSelection)` on the List and `.tint(accent)` inside each row so controls in the row (the rename field's focus ring) keep the accent; both are asserted in `SidebarTests`.
- Wanted API: a list-selection style or key (selection fill plus the text colours that go with it), instead of reusing the tint.

## G23 Segmented picker: selected pill barely differs from the track
- Status: open (filed in polish batch B)
- Used by: the code panel's Inline | Side by side picker.
- Gap: the selected segment's fill against the track measured 1.24:1 light (white on E4E7EC) and 1.68:1 dark; WCAG 1.4.11 asks 3:1 for a state indicator. Labels themselves pass (selected 17.8 light / 6.6 dark, unselected 14.4 / 11.1).
- Wanted: a stronger selected-segment treatment (border or accent), or a theme key.

## G24 Menu items cannot carry an identifier or a tooltip
- Status: adopted (MetalUI #253, "Menu items carry a Button's accessibilityIdentifier and help"; Alloy at MetalUI 8de0b5b4)
- Used by: the session menu in the sidebar (Fork, Rename).
- Gap: a `Menu` item is a `MenuNode` (title, enabled, shortcut); `.accessibilityIdentifier` and `.help` on a `Button` inside a `Menu` are dropped. The plan asks for `fork-<uuid>` on the Fork item and a "Nothing to fork yet" tooltip on it when disabled.
- Adopted as: the Fork item has `fork-<session uuid>` and `.help` ("Fork this session", or "Nothing to fork yet" while disabled); Rename has `session-rename-<session uuid>` (`rename-<uuid>` is the inline text field). The gutter-bar menu items carry `keep-`, `revert-`, `show-in-chat-`, `side-by-side-`/`inline-` plus the edit uuid, and the model menu items `model-choice-<alias>`. The disabled "Nothing to fork yet" text item is gone; tests look items up with `menu.item(accessibilityIdentifier:)`.
- Remaining gap: `TestWindow.chooseMenuItem` still chooses by title only (no choose-by-identifier).

## G26: choose a menu item by accessibility identifier in tests (forwarded)
`TestWindow.chooseMenuItem(_:)` takes only a title. With G24, tests find items by id but must still choose by title. Also asked (low priority): `.help(String?)`, where nil means no tooltip.

## G27: independent secondary and tertiary text levels (forwarded)
MetalUI derives its secondary and tertiary text from one source, so a theme cannot set them separately. Forwarded; in progress upstream as PR #259.

## G28: the segmented Picker thumb needs an edge (forwarded)
The thumb is painted in `surface`, so on a theme whose page equals `surface` (Solarized Light) the selected segment vanishes and the control reads inverted. Asked for a hairline stroke or shadow, as on AppKit.

## Note: MetalUI-internal colours with no token
These are hard-coded white inside MetalUI and cannot follow a theme: the `Toggle` `.switch` knob, the `Toggle` `.button` on-label, and `borderedProminent` button labels. Alloy uses none of them today, but they would break on a theme with a light accent.
