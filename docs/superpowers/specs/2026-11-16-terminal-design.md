# Alloy: Integrated terminal

Date: 2026-11-15. Status: draft for the user's review, revised after a code check. Builds on Code mode
(`2026-11-15-alloy-code-mode-design.md`), which reserves the bottom panel for this project, and on the LSP lifecycle
(`2026-11-12-alloy-lsp-design.md`).

## Intent and why

The user planned "a terminal pane eventually" when Code mode was designed, and agreed to the order (1) Code mode,
(2) search, (3) git, (4) terminal. Today, running a build, a test or `git log` means leaving Alloy for another app,
which breaks the Code-mode loop of "make a minor edit myself, check it, hand back to Claude". This project is a
terminal panel in Code mode: the user's login shell in the project folder, good enough to run vim, less and htop,
with `file:line` output that opens in the editor.

Standing goal: "MetalUI and Alloy run as lite and fast as possible without giving up quality". A terminal is the
easiest feature to make expensive (output floods, blinking cursors, idle redraw), so the performance plan is part of
the design, not an afterthought.

## Approaches

1. **MetalUI owns the emulator, the GPU grid view and a portable pty API; Alloy owns the panel, tabs, splits,
   project wiring and lifecycle (recommended).** A terminal grid is a general UI component like `CodeView`, needs
   per-backend GPU encoding that only MetalUI can do cleanly, and the Linux/Windows builds must mirror the macOS
   design, which means the pty (forkpty / ConPTY) belongs in MetalUI's platform layer next to the other platform
   seams. Cost: a large MetalUI gap, and Alloy's view work waits on it.
2. **Alloy does everything, drawing cells through `GPUSurface`.** Ships without waiting on MetalUI, but
   `GPUSurfaceContext` offers only one portable operation (`clear`); everything else means downcasting to
   `MetalDrawContext` / `SDLGPUDrawContext` and carrying Alloy's own glyph and quad encoders per backend. That is a
   workaround of MetalUI and a platform-specific substitute on Linux/Windows. Rejected.
3. **Embed an existing terminal (an AppKit terminal view, or a C library such as libvterm) through a native
   view.** Mature emulation for free, but MetalUI has no native-view hosting by design, an AppKit view breaks the
   GPU frame and the Linux/Windows mirror, and a C dependency adds build weight. Rejected as a host. Reusing a
   permissively licensed **pure-Swift parser** inside MetalUI's emulator is still open (Decision 2).

## Goals

1. **Bottom panel in Code mode.** Today `CodeIslandRow.editorIsland()` is a `VStack(spacing: 0)` holding
   `EditorAreaView` and a reserved `if codeBottomPanelVisible { Color.clear }` behind a compile-time `false`. That
   constant is replaced by the panel store's observed `visible` flag. Visible, the `VStack` becomes a `VSplitView`
   (editor area above, `TerminalPanel` below, `.splitViewAutosaveName("code-terminal", store: splitStore)`, so the
   height lands in `Workspace.paneSizes` like the other dividers). Hidden, the `if` keeps the panel and the split
   out of the element tree entirely: no zero-height pane, no element, exactly today's tree. `EditorAreaView` is
   untouched; `CodeIslandRow` gains one input (`terminal: TerminalPanelStore`, compared by identity in its `==`).
   Default height 30 % of the island **(our call)**; minimum 4 rows.
   ```
   ┌──────────┬──────────────────────────────────┬────────────┐
   │ sidebar  │ a.swift  b.swift │ c.swift        │ chat       │
   │          │  editor group    │  editor group  │            │
   │          ├══════════════════╧════════════════┤ (drag)     │
   │          │ [zsh ×] [swift test ×] [+] [⫿] [⌄]│            │
   │          │ ~/proj % swift build              │            │
   │          │ Sources/A/B.swift:12:3: error: …  │            │
   │          │ ~/proj % ▌                        │            │
   └──────────┴───────────────────────────────────┴────────────┘
   ```
2. **Toggle.** ⌃\` toggles the panel (View menu "Toggle Terminal", id `view-toggle-terminal`), on every platform
   (Ctrl is Ctrl everywhere). Opening it with no terminal spawns one; opening focuses the active terminal; toggling
   while a terminal is focused hides the panel and returns focus to the last editor group **(our call)**. Hiding
   never kills shells.
3. **Tabs.** A tab strip at the panel top (`terminal-tab-<n>`). Title: the last OSC 0/2 title, else the shell's
   name (`zsh`) **(our call: no foreground-process lookup, which would need polling or a platform-specific process
   query)**. `+` (`terminal-new`, ⌃⇧\`) opens a new tab in the project root. Close (`terminal-close`) asks first
   only when the pane is busy (see "Busy"). A tab whose shell exits shows "[process exited N]" and an inline
   "Close" / "Restart" pair (`terminal-exited-close`, `terminal-exited-restart`); keys are ignored there
   **(our call: no "closes on next key", which raced with typed-ahead keys and closed tabs unseen)**.
4. **Splits.** `⫿` (`terminal-split`) splits the active tab side by side. While a terminal is focused, the
   existing View menu item "Split Editor" (⌘\\) is retargeted to split the terminal and its title reads
   "Split Terminal"; there is no second menu item with the same shortcut **(our call)**. ⌥⌘\\ (split down) likewise
   splits the terminal stacked. ⌘⇧C stays "Toggle Chat Column" and is not used by the terminal.
5. **The shell.** The user's login shell (`$SHELL`, else the passwd entry, else `/bin/zsh`) as a login shell
   (argv[0] `-zsh`), cwd = project root, `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Alloy`, `LANG`
   inherited if it names UTF-8, else `en_US.UTF-8`. PATH is merged with the same `loginPATH` closure that
   `main.swift` already passes to `LSPCoordinator.installLive` (`ClaudeLocator.loginShell().path`); the terminal
   manager receives that closure through its own `installLive(on:loginPATH:)` **(our call: one source of truth)**.
   Alloy's own `ALLOY_*` and Claude session variables are removed from the child's environment.
6. **Emulation.** xterm-compatible: 16/256/truecolor SGR, bold/dim/italic/underline/strike/inverse, cursor shapes,
   scroll regions, alternate screen (47/1047/1049), DECSET modes (app cursor keys, autowrap, origin, DECTCEM),
   mouse reporting 1000/1002/1003/1006, bracketed paste 2004, focus events 1004, OSC 0/2 title, OSC 7 cwd, OSC 8
   hyperlinks, wide and combining characters, resize with reflow of the primary screen. vim, less, htop, git's pager
   and `swift test` colour output must look right.
7. **Scrollback.** 10 000 lines default (setting); wheel and trackpad scroll it; while scrolled back, new output
   leaves the view where it is and a key press snaps it to the bottom **(our call)**. In the alternate screen or
   with mouse reporting on, the wheel goes to the program.
8. **Copy, paste, find.** Drag selects (double-click word, triple-click line, ⌥-drag block); copy gives plain
   text with trailing blanks trimmed; paste is bracketed when the program asked, and any `ESC[201~` (and other C0
   ESC) inside pasted text is stripped first. Select-all selects all scrollback. Find (`terminal-find`) opens a find
   bar in the focused terminal searching scrollback, ↩/⇧↩ next/previous. A paste of more than one line into a
   program that has not enabled bracketed paste shows a one-time confirm ("Paste 5 lines? They may run as
   commands"), with "Don't ask again" in Settings **(our call)**.
9. **Clickable links.** ⌘-click (with ⌘-hover underline and `PointerStyle.pointingHand`) on `path:line`,
   `path:line:col`, `path(line,col)` and `path, line N` opens the file at that line in the focused editor group via
   `Workspace.requestOpen`. Paths resolve against the pane's OSC 7 cwd if the shell reported one, else the spawn
   cwd, then the project root as a second base (compiler output is usually root-relative) **(our call)**. The file
   must exist inside the project; others are not links **(our call: no surprise opens outside the project)**.
   `http(s)` and OSC 8 links open in the browser.
10. **Persistence.** Panel visibility, height (via `paneSizes`), tab order, active tab, split shape and each
    pane's last known cwd (OSC 7 if ever reported, else the spawn cwd) go into `ui-state.json` as an optional
    `terminal` field decoded with `decodeIfPresent`. `UIState.currentVersion` stays 1: older builds ignore the
    unknown key, and when an older build rewrites the file the terminal layout is lost, which is acceptable; bumping
    the version would make older builds refuse to save at all **(our call)**. Scrollback and processes are not
    restored. On relaunch only the active tab's focused pane spawns, and only once the panel is shown; other panes
    spawn when first shown **(our call: no N shells at launch)**.
11. **Settings** (a "Terminal" section in Settings, the `LanguageServersSection` pattern): shell path (blank =
    login shell), font size (default: editor size), scrollback lines, option-as-meta (default on), cursor style and
    blink (default block, blink on), multi-line paste confirm (default on).
12. **Theme.** ANSI 16 colours, foreground, background, cursor and selection come from new optional `terminal.*`
    tokens in the theme file, next to the existing editor tokens, with fallbacks derived from the editor palette for
    themes that lack them; contrast checked like the built-in theme contrast tests. The theme skill
    (`ThemeSkill`) documents the new tokens, and its docs copy is regenerated
    (`ALLOY_WRITE_SKILL_DOCS=1 swift test --filter docsCopyMatchesGeneratedSkill`) in the same change so
    `docsCopyMatchesGeneratedSkill` stays green.

## Calls settled up front (our calls)

1. Code mode only. Chat mode hides the panel and keeps the shells (Decision 4 asks the user). Chat mode's tree does
   not contain `CodeIslandRow`, so no `TerminalView` or surface exists there; a guard asserts it.
2. **Focus rule.** A focused terminal gets every key first through MetalUI's key-capture interaction (gap 3), with
   an allow-list that still reaches menus: ⌃\`, ⌃⇧\`, ⌘\\, ⌥⌘\\, ⌘W (closes the terminal tab), ⌘T (new terminal
   tab), ⌃Tab/⌃⇧Tab (next/previous terminal tab), copy/paste/find/select-all, ⌘K (clear scrollback), ⌘P, ⌃⌘1/2,
   ⌘, and ⌘Q. ⌘1-9 select terminal tabs. Everything else (⌃C, ⌃R, ⌃[, ⌃Space, ⌥ keys, function keys) goes to the
   program. How commands know: `TerminalPanelStore.hasFocus` (one observed `Bool`, set by the focus change, not by
   keys). Commands that change meaning (`⌘W`, `⌘T`, `⌃Tab`, `⌘\\`, `⌘K`, `⌘1-9`) read it inside their action and
   title; the menu rebuilds on focus change only, never per keystroke.
3. **Primary modifier on Linux/Windows.** Shortcuts use MetalUI's `.primary` (⌘ on Apple, Ctrl elsewhere), as the
   rest of Alloy does. Because Ctrl-letter belongs to the program in a terminal, on non-Apple platforms the
   terminal's allow-list uses primary+Shift for copy, paste, find, select-all, new tab and close tab (Ctrl+Shift+C/V
   etc., the Linux terminal convention); ⌃\` stays Ctrl+\`. Same design, platform modifier table only.
4. **Lifecycle.** `Workspace.onStop` today is a single closure set by `LSPCoordinator.installLive`. It becomes
   `onStopHooks: [@MainActor () async -> Void]`, run concurrently in a task group by `stopAll()`; the LSP
   coordinator and the terminal manager each append one. The terminal hook sends SIGHUP to each pane's process
   group, waits up to 1 s for exit, then SIGKILLs the group and reaps. Processes that called `setsid` (detached
   daemons such as a backgrounded dev server) leave the group and are orphaned by design, as in any terminal.
5. **Quit with a busy terminal.** The quit path already exists: `app.onTerminateRequest` →
   `LauncherModel.shutdownRequested`, which returns `.later`. Before `saveAll()`, it asks the terminal manager for
   busy panes; if any, one alert ("2 terminals are running a process. Quit anyway?") decides, and Cancel replies
   `false`. Window close uses the same check.
6. **Busy.** A pane is busy when the pty's foreground process group differs from the shell's
   (`tcgetpgrp` on the master, via gap 4). It is computed only on demand (close, quit), never polled. Where the
   platform cannot answer (ConPTY), the pane is treated as busy if any output arrived in the last 5 s.
7. Nothing is spawned until the user opens the panel (lazy, like LSP).
8. No shell integration scripts are injected into the user's shell (no rc file edits, no OSC 133 prompt marks).
9. **Signing.** Alloy already spawns child processes (the Claude CLI, language servers) under its current signing
   and is not App Sandboxed; a pty spawn needs no extra entitlement or notarization exception. If Alloy ever
   adopts the App Sandbox, this feature must be revisited (a sandboxed child cannot run the user's tools).

## Non-goals

Restoring scrollback or processes across launches; remote/SSH profiles; tmux-style detach; sending terminal output
to Claude sessions; task runners or a "Run" button; shell integration (prompt marks, command decorations);
foreground-command tab titles; ligatures; images (sixel, kitty graphics); a terminal in Chat mode or in its own
window; terminal tabs mixed into editor groups.

## Anti-goals

- No raised keystroke-frame guards: Chat 88, Code 91/107/117 element requests per frame with the panel hidden, and
  the Code numbers unchanged with an idle terminal visible.
- No work on idle frames: a visible, idle, unfocused terminal costs zero reruns and zero GPU redraws; a focused
  one costs only bounded blink redraws (below), never reruns.
- No timers when idle; no polling of the pty or of processes.
- No dropped or reordered output, ever; slowing the child (backpressure) is allowed, losing bytes is not.
- Output floods (`yes`, `cat` of a large log, `swift build -v`) must not raise editor typing latency.
- A hidden panel never blocks a running build.
- No orphaned shells after window close, crash or force quit of the panel (detached `setsid` daemons excepted).

## Constraints

- MetalUI only, read-only from Alloy's side: anything missing is a MetalUI gap, never an Alloy workaround.
- Linux/Windows mirror the macOS design through MetalUI's portable APIs; no platform-specific substitutes in Alloy.
- Theme tokens only; accessibility ids on every control; zero warnings; `swift test --no-parallel` green.
- Alloy never writes `~/.claude` or a project's `.claude`, and never edits the user's shell rc files.
- **Known MetalUI gap:** MetalUI has no terminal emulator, grid view, pty or key-capture interaction. Alloy's model,
  manager and panel shell can be built and tested against fakes, but the feature cannot ship until the gaps land.

## Design

### Architecture

```
MetalUI (new module MetalUITerminal)         Alloy
  PseudoTerminal (pty, readiness, resize)  ← AlloyTerminal (UI-free target)
  TerminalEmulator (parser, grid, damage)        TerminalSession  (one pane: pty + emulator)
  TerminalView (GPU cell grid, input)            TerminalManager  (lazy spawn, shutdown, env, busy)
                                                 LinkDetector     (file:line parsing, pure)
                                               AlloyCore
                                                 TerminalLayout   (tabs + split tree, Codable)
                                               AlloyKit
                                                 TerminalPanelStore, TerminalPanel,
                                                 TerminalTabStrip, TerminalPaneView
```

- **AlloyCore `TerminalLayout`**: pure Codable value: `tabs: [TerminalTab]`, `activeTab`, each tab a
  `TerminalSplitTree` plus `focusedPane`, each pane a `TerminalPaneID` with `lastCwd`. It lives on `Workspace`
  (like `codeLayout`) because it is persisted through `UIState`. `SplitTree` today is a concrete
  `indirect enum` whose leaves are editor group `UUID`s (`case group(UUID)`), so it cannot be reused as is. **Our
  call:** a parallel `TerminalSplitTree` (same shape, `case pane(UUID)`) with its own split/remove/neighbour/prune,
  rather than generalising `SplitTree` and touching every editor-group call site. If a later feature needs a third
  tree, generalise then.
- **AlloyTerminal** (new UI-free target, depends on AlloyCore and MetalUITerminal):
  - `TerminalSession`: one pane. Owns one `PseudoTerminal` and one `TerminalEmulator`. Reads are event-driven:
    the pty's readiness source fires on a **single shared serial reader queue** for all panes (no thread or task
    per pane). Each wakeup reads up to 64 KiB, feeds the emulator on that queue, and sets the session's dirty flag;
    it never hops to the main actor per read.
  - `TerminalManager`: `@MainActor`, `LSPCoordinator` shape: ordered command stream (spawn, write, resize,
    close, restart), lazy spawn, `shutdown() async` appended to `Workspace.onStopHooks`, `busyPanes()`, injectable
    `PtySpawner` for tests.
  - `PtySpawner`: an Alloy protocol (spawn → a pty handle with write/resize/signal/exit/foreground-group). Its live
    conformance wraps MetalUI's `PseudoTerminal`; tests use a scripted fake in AlloyTestSupport. This is Alloy's
    test seam, not a substitute: no Alloy code touches a pty syscall.
  - `LinkDetector`: pure function from a row's text and base directories to link ranges; existence and in-project
    checks go through an injected file-exists closure, called only when the ⌘-hovered cell changes or on click.
- **AlloyKit**: `TerminalPanelStore` (`@Observable`, owned per window next to `CodePanelStore`): `visible`,
  `hasFocus`, `tabSummaries: [TerminalTabSummary]` (value type: id, title, exited, busy-unknown), and the manager.
  `TerminalPanel` (tab strip + the active tab's split tree of `TerminalPaneView`s), each pane wrapping MetalUI's
  `TerminalView`. All are `.equatable()` Components with hand-written `==` over value inputs, so editor state never
  reruns them and output never reruns them.

### Thread ownership (our call)

The emulator is confined to the shared reader queue: `feed`, `resize` and reflow run there only. After each feed it
publishes, under a lock, an immutable `TerminalSnapshot` (`Sendable`) holding only the **damaged rows** since the
last publish plus cursor and modes; rows are copy-on-write so unchanged rows are shared, not copied. The main actor
takes the latest snapshot once per frame (swap under the lock, O(damaged rows)), so a flood of 10 MB costs one
swap per frame, not per read. Selection, find and `rowText` for links are requests posted to the queue that answer
asynchronously; at human speed that is invisible.

### API freeze point (our call)

The gap list below is the API contract. Before task 5 starts, the MetalUI session confirms or amends the
signatures of gaps 1, 3 and 4; Alloy then codes against them (with the fake `PtySpawner` and a fake emulator
conforming to the confirmed shape). Tasks 2-4 and 6 do not depend on MetalUI and start immediately.

### Data flow

Keys: `TerminalView` (focused, key capture) → MetalUI `encodeKey` with the emulator's modes → bytes →
`TerminalManager.write` → pty. Output: pty readiness → reader queue → emulator → snapshot publish + dirty → at most
one `TerminalView` redraw request per frame → it redraws damaged rows only. Resize: `TerminalView` derives
`(cols, rows)` from its laid-out frame and the cell size during layout, and calls `onResize` only when the cell
count changes, at most once per layout pass (that is the debounce); values are clamped to at least 2 × 1 (a split
collapsed to 0). Alloy forwards it to the reader queue (reflow) and the pty (`TIOCSWINSZ` / ConPTY resize); a newer
resize replaces a pending one. **Initial size:** the first spawn waits for the first `onResize`, so the shell starts
at its real size; headless tests use 80 × 24. Title/cwd: OSC events → session → main actor, coalesced to at most
once per frame and published to `tabSummaries` only when the value changed.

### Failure modes

- Shell path missing or not executable: fall back to `/bin/zsh`, then `/bin/sh`, with a one-line notice in the pane.
- Spawn fails (out of ptys, fd limit): the pane shows the error and "Retry" (`terminal-retry`).
- Shell exits immediately (bad rc file): the pane shows "[process exited N]" with Close/Restart; Alloy never
  restarts on its own, so there is no retry storm. Restart is user-driven only.
- Child exit: the session reaps the child (`exitStatus` from gap 4, waited once), then drops its pid and process
  group; signals are never sent after reaping, so pid reuse cannot hit an unrelated process.
- fd leaks: every fd Alloy opens (session sockets, LSP pipes, files) is already or becomes `O_CLOEXEC`; gap 4
  spawns with a closed-fd set so the child inherits only the pty slave. A test asserts the child sees fds 0-2 only.
- Project folder deleted or renamed: spawn cwd missing → spawn in `$HOME` with a one-line notice in the pane.
- Invalid UTF-8 or a non-UTF-8 locale: replacement character, parser state kept; `LANG` is forced to a UTF-8
  locale when the inherited one is not.
- Malicious or broken escape sequences: OSC 52 clipboard write off (v1), title capped at 256 characters, **any**
  OSC/DCS/APC payload capped at 4 KiB (the rest is discarded until its terminator or the next ESC), very long lines
  wrap normally; no sequence can make Alloy open a file without a ⌘-click.
- Project closed while output flows: readiness source cancelled, process group signalled, no main-actor work after
  shutdown.
- Fonts: the terminal uses the editor font; box-drawing and block elements are drawn to the cell by `TerminalView`
  (gap 2); other glyphs the font lacks, including powerline symbols, go through MetalUI's font fallback (gap 2).
- IME: marked text is drawn at the cursor cell, and for wide (CJK) characters the caret advances two cells (gap 2).

## Performance plan

- **Hidden panel:** no element, no surface, no timer. Shells keep running and **the reader keeps reading and
  feeding the emulator** (bounded scrollback ring), so a hidden `swift build` never blocks on a full pty buffer;
  only redraws stop **(our call: correctness over the CPU of parsing hidden output)**. Parsing stays bounded by the
  per-wakeup budget below.
- **Idle visible terminal:** `TerminalView` is a `.onDemand` surface keyed to the snapshot version and the cursor
  phase. Unfocused, or the window not key: steady cursor, nothing scheduled, zero redraws. Focused: blink is a
  surface-scoped timed redraw (gap 5) at 2 Hz that stops after 30 s without input or output, so at most 60 surface
  redraws and **0 element requests** per window after the last key; the 30 s stop is our call.
- **Output bursts:** parsing on the reader queue; the main actor swaps one snapshot per frame. `TerminalView`
  redraws damaged rows only (per-row cache limited to the visible rows), and coalesces any number of feeds into one
  frame. Bursts never rerun Alloy Components; tab titles rerun the tab strip only when a title value changes, at
  most once per frame.
- **Typing in the editor during a flood:** the terminal redraw is a GPU-only cost on its own surface; editor element
  requests are unchanged. Each reader wakeup is bounded (1 MiB parsed, then it yields the queue to other panes);
  backpressure comes from the kernel pty buffer only when the reader is behind, never by stopping reads.
- **Typing in the terminal:** keys go straight to the pty; echo arrives as output. Cost: surface redraws only,
  0 element requests (guard 4).
- **Pointer:** selection drag redraws the surface only. ⌘-hover link detection runs only when the hovered **cell**
  changes while ⌘ is held; plain pointer moves over the terminal cost nothing.
- **Resize during a flood:** reflow runs on the reader queue (primary screen only, the alternate screen just
  clips); the view keeps the previous snapshot until reflow publishes; coalesced resizes run only the latest.
- **GPU memory:** all panes share the window's existing `GlyphAtlas` (no per-pane atlas); row caches cover visible
  rows only and are released when a pane leaves the tree.
- **Idle CPU:** N panes cost N readiness sources on one queue, no threads, no wakeups without output.
- **Memory:** scrollback is a ring of compact rows (UTF-8 text + run-length attribute spans), not per-cell structs;
  10 000 lines of 120 columns target under 4 MB per pane.

New guards:
1. `terminalHiddenHoldsCodeGuards`: Code 91/107/117 and Chat 88 unchanged after a terminal was opened and hidden;
   the hidden tree contains no `code-terminal` split and no terminal surface.
2. `chatModeHasNoTerminalSurface`: after switching to Chat with a terminal open, no `TerminalView` surface is
   registered.
3. `idleVisibleTerminalCostsNothing`: panel visible, terminal unfocused and idle: 0 reruns, 0 element requests,
   0 surface redraws over 20 ticks.
4. `focusedIdleTerminalBlinkBudget`: focused and idle for 35 s of simulated clock: ≤ 60 surface redraws,
   0 element requests, then 0.
5. `terminalTypingFrameCost`: typing in the terminal costs 0 element requests per key (surface redraws only); the
   measured number becomes the guard.
6. `outputFloodDoesNotTouchTheEditor`: the fake session streams 10 MB while `typeText` runs in an editor group:
   editor frame requests equal the guard, `BodyProbe` counts unchanged, terminal redraws ≤ one per frame.
7. `titleSpamRerunsTabStripOnce`: 1 000 OSC 2 sequences in one burst rerun the tab strip at most once per frame,
   and 0 times when the title value repeats.
8. `hiddenPanelDoesNotBlockChild`: with the panel hidden, the fake pty producing 50 MB completes (no stall).
9. `MemoryProbeTests`: a full scrollback stays under budget.
10. Bench: new scenarios "terminal output flood vs editor typing latency" and "idle CPU with three terminals
    open".

## MetalUI gaps (to forward)

1. **`MetalUITerminal` module, `TerminalEmulator`** (no SwiftUI equivalent): `init(cols:rows:scrollback:)`,
   `feed(_ bytes: UnsafeRawBufferPointer)` and `resize(cols:rows:)` with primary-screen reflow, both confined to a
   caller-chosen serial queue; `publishSnapshot() -> TerminalSnapshot` (`Sendable`, damaged rows only,
   copy-on-write rows, cursor, modes, version); `modes` (app cursor, mouse mode and encoding, bracketed paste, focus
   events, alt screen); `events` (title, cwd, bell, hyperlink); OSC/DCS payload cap (default 4 KiB); `selection`,
   `selectedText()`, `search(_:from:backwards:) -> Range?`, `rowText(_:)`. Encoders: `encodeKey(KeyPress, modes:,
   optionAsMeta:) -> [UInt8]`, `encodeMouse(_:at:modes:)`, `encodePaste(_:modes:)` (strips ESC including
   `ESC[201~` from the payload), `encodeFocus(_:)`.
2. **`TerminalView(snapshotSource:, theme: TerminalPalette, onInput:, onResize:, onLink:)`** (closest SwiftUI:
   none; `Canvas`/`TextEditor`): GPU cell-grid renderer on Metal and SDL using the window's shared `GlyphAtlas`
   (bg quads, cursor block/bar/underline, selection, underline/strike/dim/bold/italic, box-drawing and block
   elements drawn to the cell, other missing glyphs, including powerline, through MetalUI's font fallback, which this gap extends if it does not cover them), `.onDemand` redraw from
   the snapshot version, visible-row cache, `onResize(cols, rows)` from layout (clamped ≥ 2 × 1, called only on
   change), `hitTest(point) -> (col,row)`, ⌘-hover link callback only on cell change with
   `PointerStyle.pointingHand`, IME marked text through `textInput` positioned on wide-cell boundaries, wheel to
   scrollback or program, selection gestures. Missing today: everything except `PointerStyle.pointingHand` and the
   `.onDemand` `RedrawPolicy`, which it reuses.
3. **Key capture:** a focusable interaction that delivers every key (⌃-combos incl. ⌃\` and ⌃Space, ⌥ as meta,
   function/nav keys with modifiers) to `onKeyPress` before menu key equivalents and `Button` shortcuts, plus an
   allow-list so chosen shortcuts still win, e.g. `.focusable(interactions: .captureAllKeys(except:
   [KeyboardShortcut]))`. No SwiftUI equivalent (closest: `onKeyPress`, which never sees menu key equivalents).
4. **`PseudoTerminal`** in MetalUI's platform layer: `spawn(executable:, argv:, env:, cwd:, size:) throws` (new
   session, controlling tty, only fds 0-2 inherited, all others closed/CLOEXEC); event-driven readability
   (`onReadable(queue:_:)` backed by a dispatch read source / epoll / ConPTY overlapped read, no thread per pty)
   with a non-blocking `read(into:) -> Int`; `write(_:)` (non-blocking, queued); `resize(cols:rows:)`;
   `signalGroup(_:)`; `exitStatus` async with reaping; `foregroundProcessGroup() -> Int32?` (nil where the
   platform cannot answer). macOS and Linux via `posix_spawn` + `setsid` + `TIOCSCTTY` (or `forkpty`), Windows via
   ConPTY. No SwiftUI equivalent.
5. **Surface-scoped timed redraw:** `requestRedraw(after: Duration)` on a `GPUSurface` / `TerminalView` that wakes
   the frame clock once and redraws only that surface, without rerunning any Component. `TimelineView` does not
   cover this: each schedule tick reruns its content (element requests), and `RedrawPolicy.continuous` keeps the
   display link awake every frame. SwiftUI equivalent: none (closest `TimelineView(.periodic)`).

## Testing strategy

- MetalUI (theirs): byte-stream fixtures for the emulator (vttest/esctest subset), key/mouse/paste encoder tables,
  a real `/bin/sh -c` pty test gated to macOS/Linux (inherited fds, group signal, reaping), render snapshot tests.
- AlloyCoreTests: `TerminalLayoutTests` (`TerminalSplitTree` split/close/focus/prune, Codable round trip),
  `UIStateTests` (files without `terminal` decode; version stays 1), `Workspace` stop hooks run all hooks once,
  settings decode defaults.
- AlloyTerminal tests: `LinkDetectorTests` (forms, OSC 7 cwd vs spawn cwd vs project root, outside-project
  rejection, `path(line,col)`), `TerminalSessionTests` with the fake `PtySpawner` (ordering, no output lost while
  hidden, per-wakeup budget, resize coalescing and clamping, env scrubbing of `ALLOY_*`, UTF-8 `LANG`, missing cwd
  falls back to `$HOME`, immediate exit shows Restart and never respawns), shutdown signals the group then kills,
  no signal after reap, busy detection.
- AlloyKitTests: toggle/focus/tab/split by accessibility id, key routing (⌘W closes the terminal tab when focused,
  the editor tab otherwise; ⌘\\ splits the terminal when focused; ⌃C reaches the program), multi-line paste
  confirm, ⌘-click opens the editor at the line, quit with a busy pane asks once, relaunch spawns only the active
  pane, `ThemeSkill` docs copy, theme fallbacks and contrast, plus the perf guards above.

## Suggested task breakdown

1. Forward MetalUI gaps 1-5 to the MetalUI session; agree the API shapes (freeze point). Blocks tasks 5 (live
   conformance only) and 7-8.
2. `TerminalLayout` + `TerminalSplitTree` + `UIState` optional field + `Workspace.onStopHooks` migration (LSP moves
   to it) + tests (AlloyCore).
3. Terminal settings + Settings section + `terminal.*` theme tokens with fallbacks, contrast tests, `ThemeSkill`
   docs regenerated.
4. `LinkDetector` + tests (pure).
5. `AlloyTerminal` target: `PtySpawner` protocol and fake, `TerminalSession`, `TerminalManager` (env, lazy spawn,
   shutdown hook, busy), against a fake emulator of the frozen shape; live conformance once gap 4 lands.
6. Panel shell: `TerminalPanelStore`, `CodeIslandRow` input and `VSplitView`, toggle and View menu items, tab
   strip, splits, exited-pane Close/Restart, quit/close confirm (placeholder pane view).
7. Wire `TerminalView`: input with key capture, focus rule and command retargeting, resize, selection,
   copy/paste/confirm, find, links.
8. Perf guards, memory probe and Bench scenarios; then the end-to-end check with vim, less, htop.

## Decisions for the user

1. **Where the pty lives.** (a) MetalUI's platform layer, portable to Linux/Windows; (b) Alloy's `AlloyTerminal`
   target, macOS only first. Recommended: (a), because Linux/Windows must mirror the design and Alloy never works
   around MetalUI.
2. **Emulator source.** (a) MetalUI writes its own parser; (b) MetalUI adopts a permissively licensed pure-Swift
   parser as a dependency or vendored code. Recommended: (a) for size and control, accepting a longer build; (b) if
   time to ship matters more.
3. **⌘W, ⌘T and ⌃Tab while a terminal is focused.** (a) act on terminal tabs (our call 2); (b) always act on editor
   tabs, terminal tabs only through ⌃⇧\` and the menu. Recommended: (a), as VS Code and Zed do.
4. **Mode switch.** (a) Chat mode hides the terminal, shells keep running; (b) the panel also appears in Chat mode
   under the conversation. Recommended: (a).
5. **Relaunch.** (a) remembered tabs and cwds come back, the active pane's shell spawns when the panel is shown,
   others on first view; (b) panel hidden and empty on every launch. Recommended: (a).


## Approved decisions (2026-11-16)

The user approved every recommendation above ("Approved build it"). Binding:
- 1(a) pty in MetalUI's platform layer. 2(a) MetalUI writes its own parser. 3(a) ⌘W/⌘T/⌃Tab act on terminal tabs while a terminal is focused.
- 4(a) Chat mode hides the terminal; shells keep running. 5(a) lazy restore of tabs and cwds.

## MetalUI plan answers (2026-11-16)

Accepted:
- A UI-free `MetalUITerminal` plus `MetalUITerminalUI`.
- `drainEvents()`/`onEvents`, a `.reply` event that Alloy's session must write to the pty (DA/DSR/CPR), and `TerminalSnapshotSource`.
- `.keyCapture(except:optionAsMeta:)`. ⌘-combos that encode to nothing fall through to menus.

Option-as-meta, rendering and accessibility:
- Option-as-meta uses both ⌥ keys and bypasses dead keys.
- The v1 background is opaque.
- v1 accessibility covers the visible rows' text.
- Emoji are monochrome. Bold uses the bold face, with an optional `boldIsBright` flag (default off).
- Blink stops after 30 s, owned by a MetalUI view flag.

Windows and Linux:
- The Windows shell is pwsh, falling back to powershell, on Windows 10 1809+.
- Linux needs kernel 5.3+.

The gap 1, 3 and 4 API freezes in MetalUI's Phase 0 (before task 5). Gaps 2 and 5 freeze at Phase 5 (before task 7).
