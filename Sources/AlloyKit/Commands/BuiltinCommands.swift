import AlloyCore
import Foundation
import MetalUI

/// Alloy's own commands: the single table that the menus, the hidden global keys and (later) the palette are generated
/// from. See docs/command-registry.md.
public enum BuiltinCommands {
    /// Registers every built-in command into `center.registry`. `settings` and `themes` are closures because the test
    /// helpers create the Settings controller after the window; production passes `{ settingsWindow }`.
    @MainActor
    public static func register(into center: CommandCenter, launcher: LauncherModel,
                         settings: @escaping @MainActor () -> SettingsWindowController?,
                         themes: @escaping @MainActor () -> ThemeController?) {
        let registry = center.registry
        let quickOpen = center.quickOpen
        let palette = center.palette
        // The workspace commands act on, resolved when a command runs, so the registry outlives workspace switches.
        let current: @MainActor () -> Workspace? = { [weak center] in center?.workspace }
        let hasWorkspace: @MainActor () -> Bool = { current() != nil }
        let inCode: @MainActor () -> Bool = { current()?.mode == .code }

        func add(_ id: String, _ title: String, _ category: CommandCategory, _ shortcut: KeyChord?, _ binding: CommandBinding,
                 menu: MenuPlacement? = nil, recents: Bool = false, menuID: String? = nil, keyID: String? = nil,
                 enabled: @escaping @MainActor () -> Bool, run: @escaping @MainActor () -> Void) {
            registry.register(CommandDescriptor(id: id, title: title, category: category, shortcut: shortcut, binding: binding,
                                                menu: menu, recordsRecent: recents, menuAccessibilityID: menuID,
                                                keyAccessibilityID: keyID), isEnabled: enabled, run: run)
        }
        func chord(_ mods: ChordModifiers, _ key: ChordKey) -> KeyChord { KeyChord(modifiers: mods, key: key) }
        func ch(_ c: Character) -> ChordKey { .character(c) }

        add("app.settings", "Settings…", .app, chord(.cmd, ch(",")), .menu, menu: .appSettings, recents: true,
            menuID: "app-settings", enabled: hasWorkspace) {
            // Settings edit the open project's workspace, so it needs a project; the chooser has none.
            if let workspace = current(), let controller = settings() { controller.open(workspace: workspace, themes: themes(), center: center) }
        }
        // F12: a focused handler claims the key first (MetalUI runs menu shortcuts only after the focused view declines),
        // so the code panel's own F12 handling and this item never both fire.
        add("go.definition", "Go to Definition", .go, chord([], .named(.f12)), .menu, menu: .go, recents: true,
            enabled: hasWorkspace) { current()?.goToDefinition?() }
        // Code intelligence. Each runs the focused editor's hook and is enabled only when the hook says it can run
        // (writable document, a server with the capability, a selection, not the old-text pane).
        func addIntel(_ id: String, _ title: String, _ category: CommandCategory, _ shortcut: KeyChord?, menu: MenuPlacement,
                      menuID: String, _ command: IntelCommand) {
            add(id, title, category, shortcut, .menu, menu: menu, recents: true, menuID: menuID,
                enabled: { current()?.intelHooks.isEnabled(command) ?? false }) { current()?.intelHooks.run[command]?() }
        }
        addIntel("go.symbol", "Go to Symbol…", .go, chord([.cmd, .shift], ch("o")), menu: .go, menuID: "menu-go-symbol", .goToSymbol)
        // Shift-F12: the code panel's own key handler claims the key first, so this item and the handler never both fire.
        addIntel("go.references", "Find References", .go, chord(.shift, .named(.f12)), menu: .go,
                 menuID: "menu-find-references", .findReferences)
        // F2: the code view's own key handler does not claim it, so the menu shortcut runs after the focused view declines.
        addIntel("edit.rename", "Rename Symbol", .edit, chord([], .named(.f2)), menu: .edit, menuID: "menu-rename", .rename)
        addIntel("edit.formatDocument", "Format Document", .edit, chord([.alt, .shift], ch("f")), menu: .edit,
                 menuID: "menu-format", .formatDocument)
        addIntel("edit.formatSelection", "Format Selection", .edit, nil, menu: .edit,
                 menuID: "menu-format-selection", .formatSelection)
        addIntel("edit.showHover", "Show Hover", .edit, chord(.cmd, ch("i")), menu: .edit, menuID: "menu-show-hover", .showHover)
        addIntel("edit.triggerCompletion", "Trigger Completion", .edit, chord(.ctrl, .named(.space)), menu: .edit,
                 menuID: "menu-trigger-completion", .triggerCompletion)
        addIntel("edit.signatureHelp", "Signature Help", .edit, chord([.ctrl, .shift], .named(.space)), menu: .edit,
                 menuID: "menu-signature-help", .triggerSignature)
        addIntel("edit.quickFix", "Quick Fix", .edit, chord(.cmd, ch(".")), menu: .edit,
                 menuID: "menu-quick-fix", .quickFix)
        // Multi-cursor: MetalUI's selection helpers do the work on the focused view's state. Disabled when no code view
        // is focused. The chords are claimed by the menu items, so the code view never sees them.
        func addMulti(_ id: String, _ title: String, _ shortcut: KeyChord?, _ command: MultiCursorCommand) {
            add("editor.\(id)", title, .selection, shortcut, .menu, menu: .edit, menuID: "cmd-editor.\(id)",
                enabled: { current()?.canRunMultiCursor() ?? false }) { current()?.runMultiCursor(command) }
        }
        addMulti("addNextOccurrence", "Add Next Occurrence", chord(.cmd, ch("d")), .addNextOccurrence)
        addMulti("selectAllOccurrences", "Select All Occurrences", chord([.cmd, .shift], ch("l")), .selectAllOccurrences)
        // macOS reserves alt+cmd+d (Show or Hide the Dock), so a default there could never fire: menu and palette only.
        #if os(macOS)
        let skipChord: KeyChord? = nil
        #else
        let skipChord: KeyChord? = chord([.alt, .cmd], ch("d"))
        #endif
        addMulti("skipNextOccurrence", "Skip to Next Occurrence", skipChord, .skipToNextOccurrence)
        addMulti("addCaretAbove", "Add Caret Above", chord([.ctrl, .shift], .named(.up)), .addCaretAbove)
        addMulti("addCaretBelow", "Add Caret Below", chord([.ctrl, .shift], .named(.down)), .addCaretBelow)
        // Folding: acts on the focused view's fold state; the chords are claimed by the menu items in View > Folding.
        func addFold(_ id: String, _ title: String, _ shortcut: KeyChord, _ command: FoldCommand) {
            add("editor.\(id)", title, .folding, shortcut, .menu, menu: .folding, menuID: "cmd-editor.\(id)",
                enabled: { current()?.canRunFold() ?? false }) { current()?.runFold(command) }
        }
        addFold("fold", "Fold", chord([.alt, .cmd], .named(.left)), .fold)
        addFold("unfold", "Unfold", chord([.alt, .cmd], .named(.right)), .unfold)
        addFold("foldAll", "Fold All", chord([.alt, .shift, .cmd], .named(.left)), .foldAll)
        addFold("unfoldAll", "Unfold All", chord([.alt, .shift, .cmd], .named(.right)), .unfoldAll)
        // File menu, in menu order.
        // ⌘N is delivered by the File menu item: an empty Untitled tab in the focused code group.
        add("file.new", "New File", .file, chord(.cmd, ch("n")), .menu, menu: .file, recents: true,
            menuID: "file-new", enabled: hasWorkspace) { [weak center] in
            if let workspace = current() { center?.newFile(in: workspace) }
        }
        // ⇧⌘N (the sidebar's + button has no shortcut of its own).
        add("session.new", "New Session", .session, chord([.cmd, .shift], ch("n")), .menu, menu: .file, recents: true,
            menuID: "file-new-session", enabled: hasWorkspace) { current()?.startNewSession() }
        // ⌘T does nothing outside a focused terminal, so the key never shadows anything.
        add("tab.new", "New Terminal Tab", .tab, chord(.primary, ch("t")), .menu, menu: .file,
            menuID: "file-new-terminal-tab", enabled: { current()?.terminalHasFocus ?? false }) {
            current()?.terminalFocusActions?.newTab()
        }
        // Every picked file opens in a tab; one outside the project opens as `alloy <file>` would (see `CommandCenter`).
        add("file.open", "Open\u{2026}", .file, chord(.primary, ch("o")), .menu, menu: .file, menuID: "file-open",
            enabled: hasWorkspace) { [weak center] in
            guard let center else { return }
            Task { @MainActor in
                let urls = await center.chooseFiles(center.workspace?.projectRoot)
                guard let workspace = center.workspace else { return }
                let root = workspace.projectRoot.resolvingSymlinksInPath().standardizedFileURL.path
                for url in urls {
                    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                    if path.hasPrefix(root + "/") { await workspace.open(String(path.dropFirst(root.count + 1))) } else { center.openOutsideProject(url) }
                }
            }
        }
        add("go.quickOpen", "Quick Open", .go, chord(.primary, ch("p")), .menu, menu: .file, recents: true,
            menuID: "file-quick-open", enabled: hasWorkspace) {
            guard let workspace = current() else { return }
            palette.hide()
            if quickOpen.isShowing { quickOpen.hide() } else { quickOpen.show(workspace: workspace) }
        }
        // Close Tab ... Save All: MetalUI's `.saveItem` group, which replaces its standard Close. Esc closes quick-open first; a
        // tab never closes under it. With no project (the chooser) ⌘W closes the window, as the standard Close did.
        add("tab.close", "Close Tab", .tab, chord(.primary, ch("w")), .menu, menu: .fileSave, menuID: "file-close-tab",
            enabled: { [weak center] in
                !hasWorkspace() || !(center?.isProjectWindowKey() ?? true) || (!quickOpen.isShowing && !palette.isShowing)
            }) { [weak center] in
            // No project, or another window (Settings…) is key: ⌘W closes that window, never an editor tab behind it.
            guard current() != nil, center?.isProjectWindowKey() ?? true else { center?.closeKeyWindow(); return }
            if let t = current()?.terminalFocusActions, t.isFocused() { t.closeTab(); return }
            current()?.closeActiveTab()
        }
        add("window.close", "Close Window", .app, chord([.primary, .shift], ch("w")), .menu, menu: .fileSave,
            menuID: "window-close", enabled: { true }) { [weak center] in center?.closeKeyWindow() }
        // ⌘S is delivered by this item alone (the code panel has no key handler for it).
        add("file.save", "Save", .file, chord(.cmd, ch("s")), .menu, menu: .fileSave, recents: true, menuID: "file-save",
            enabled: { current().flatMap { $0.activeTab(in: $0.defaultPane) } != nil }) { [weak center] in
            guard let workspace = current() else { return }
            // An Untitled tab has no file yet: the first save asks where.
            if let key = workspace.activeTab(in: workspace.defaultPane), workspace.isUntitled(key), let center {
                Task { @MainActor in await center.saveUntitledTab(key, in: workspace) }
                return
            }
            workspace.requestSaveActive()
        }
        add("file.saveAs", "Save As\u{2026}", .file, chord([.cmd, .shift], ch("s")), .menu, menu: .fileSave, menuID: "file-save-as",
            enabled: { current().flatMap { $0.activeTab(in: $0.defaultPane).flatMap($0.document) } != nil }) { [weak center] in
            guard let center, let workspace = current(), case let pane = workspace.defaultPane,
                  let path = workspace.activeTab(in: pane), workspace.document(path) != nil else { return }
            if workspace.isUntitled(path) { Task { @MainActor in await center.saveUntitledTab(path, in: workspace) }; return }
            Task { @MainActor in
                let name = (path as NSString).lastPathComponent
                let folder = workspace.projectRoot.appendingPathComponent((path as NSString).deletingLastPathComponent)
                guard let target = await center.chooseSaveURL(name, folder) else { return }
                try? await workspace.saveAs(path, to: target, in: pane)
            }
        }
        add("file.saveAll", "Save All", .file, chord([.alt, .cmd], ch("s")), .menu, menu: .fileSave, menuID: "file-save-all",
            enabled: hasWorkspace) { [weak center] in
            guard let workspace = center?.workspace else { return }
            Task { @MainActor in await workspace.saveAll() }
        }

        add("search.nextResult", "Next Result", .go, chord([], .named(.f4)), .menu, menu: .go,
            menuID: "go-next-result", enabled: hasWorkspace) { current()?.search.step(1) }
        add("search.previousResult", "Previous Result", .go, chord(.shift, .named(.f4)), .menu, menu: .go,
            menuID: "go-previous-result", enabled: hasWorkspace) { current()?.search.step(-1) }

        // Git. Every item is disabled with no coordinator, outside a repository and without a usable git; the editor items
        // also need Code mode with a file open. The closures resolve the coordinator when they run.
        let coordinator: @MainActor () -> GitCoordinator? = { current()?.gitServices as? GitCoordinator }
        let repoReady: @MainActor () -> Bool = { coordinator()?.repoReady ?? false }
        let editorReady: @MainActor () -> Bool = { coordinator()?.editorItemsReady ?? false }
        func addGit(_ id: String, _ title: String, menuID: String, editor: Bool, run: @escaping @MainActor (GitCoordinator) -> Void) {
            add(id, title, .git, nil, .none, menu: .git, menuID: menuID, enabled: editor ? editorReady : repoReady) {
                if let coordinator = coordinator() { run(coordinator) }
            }
        }
        addGit("git.compareHead", "Compare with HEAD", menuID: "git-compare-head", editor: true) { $0.compareActiveWithHead() }
        addGit("git.stageFile", "Stage File", menuID: "git-stage-file", editor: true) { $0.stageActiveFile() }
        addGit("git.unstageFile", "Unstage File", menuID: "git-unstage-file", editor: true) { $0.unstageActiveFile() }
        addGit("git.commit", "Commit…", menuID: "git-commit-menu", editor: false) { $0.showCommit() }
        addGit("git.switchBranch", "Switch Branch…", menuID: "git-branch-picker-menu", editor: false) { $0.showBranchPicker() }
        addGit("git.blameLine", "Blame Line", menuID: "git-blame-line", editor: true) { $0.blameActiveLine() }
        addGit("git.toggleFileBlame", "Toggle File Blame", menuID: "git-blame-file", editor: true) { $0.toggleActiveFileBlame() }
        addGit("git.nextChange", "Next Change", menuID: "git-next-change", editor: true) { $0.stepActiveChange(1) }
        addGit("git.previousChange", "Previous Change", menuID: "git-prev-change", editor: true) { $0.stepActiveChange(-1) }
        addGit("git.refresh", "Refresh", menuID: "git-refresh-menu", editor: false) { $0.refresh() }

        add("view.chatMode", "Chat Mode", .view, chord([.ctrl, .cmd], ch("1")), .menu, menu: .view, recents: true,
            menuID: "view-mode-chat", enabled: hasWorkspace) { current()?.setMode(.chat) }
        add("view.codeMode", "Code Mode", .view, chord([.ctrl, .cmd], ch("2")), .menu, menu: .view, recents: true,
            menuID: "view-mode-code", enabled: hasWorkspace) { current()?.setMode(.code) }
        add("view.splitRight", "Split Right", .view, chord(.cmd, ch("\\")), .menu, menu: .view, recents: true,
            menuID: "view-split-right", enabled: inCode) { current()?.splitFocused(.horizontal) }
        add("view.splitDown", "Split Down", .view, chord([.alt, .cmd], ch("\\")), .menu, menu: .view, recents: true,
            menuID: "view-split-down", enabled: inCode) { current()?.splitFocused(.vertical) }
        let focusMoves: [(String, String, NamedKey, String, FocusDirection)] = [
            ("view.focusLeft", "Focus Left Group", .left, "view-focus-left", .left),
            ("view.focusRight", "Focus Right Group", .right, "view-focus-right", .right),
            ("view.focusUp", "Focus Up Group", .up, "view-focus-up", .up),
            ("view.focusDown", "Focus Down Group", .down, "view-focus-down", .down),
        ]
        for (id, title, key, a11y, direction) in focusMoves {
            add(id, title, .view, chord([.ctrl, .cmd], .named(key)), .menu, menu: .view, menuID: a11y, enabled: inCode) {
                current()?.focusGroup(direction)
            }
        }
        add("view.revealInTree", "Reveal in Tree", .view, chord([.alt, .cmd], ch("l")), .menu, menu: .view, recents: true,
            menuID: "view-reveal-in-tree", enabled: inCode) { current()?.revealInTree() }
        add("view.toggleChatColumn", "Toggle Chat Column", .view, chord([.cmd, .shift], ch("c")), .menu, menu: .view, recents: true,
            menuID: "view-toggle-chat-column", enabled: inCode) { current()?.codeLayout.chatCollapsed.toggle() }
        // Edit > Find. ⌘F with a terminal focused is the terminal's find (this item is its only owner on a Mac); ⌘G and
        // ⇧⌘G reach the items only when the code view declined them (it claims them while it has matches).
        add("editor.find", "Find\u{2026}", .edit, chord(.primary, ch("f")), .menu, menu: .find, menuID: "edit-find",
            enabled: { (current()?.terminalHasFocus ?? false) || (current()?.intelHooks.isEnabled(.find) ?? false) }) {
            if let t = current()?.terminalFocusActions, t.isFocused() { t.openFind(); return }
            current()?.intelHooks.run[.find]?()
        }
        add("editor.findNext", "Find Next", .edit, chord(.primary, ch("g")), .menu, menu: .find, menuID: "edit-find-next",
            enabled: { !(current()?.terminalHasFocus ?? false) && (current()?.intelHooks.isEnabled(.findNext) ?? false) }) {
            current()?.intelHooks.run[.findNext]?()
        }
        add("editor.findPrevious", "Find Previous", .edit, chord([.primary, .shift], ch("g")), .menu, menu: .find,
            menuID: "edit-find-previous",
            enabled: { !(current()?.terminalHasFocus ?? false) && (current()?.intelHooks.isEnabled(.findPrevious) ?? false) }) {
            current()?.intelHooks.run[.findPrevious]?()
        }
        add("search.findInFiles", "Find in Files", .view, chord([.cmd, .shift], ch("f")), .menu, menu: .find, recents: true,
            menuID: "view-find-in-files", enabled: hasWorkspace) { current()?.showSearch(replace: false) }
        add("search.replaceInFiles", "Replace in Files", .view, chord([.cmd, .shift], ch("h")), .menu, menu: .find, recents: true,
            menuID: "view-replace-in-files", enabled: hasWorkspace) { current()?.showSearch(replace: true) }

        // The terminal panel lives in Code mode only; Chat mode has none, so both commands are disabled there.
        add("terminal.toggle", "Toggle Terminal", .view, chord(.ctrl, ch("`")), .menu, menu: .view, recents: true,
            menuID: "view-toggle-terminal", enabled: inCode) { current()?.toggleTerminal() }
        add("terminal.new", "New Terminal", .view, chord([.ctrl, .shift], ch("`")), .menu, menu: .view, recents: true,
            menuID: "view-new-terminal", enabled: inCode) { current()?.newTerminalTab() }

        add("view.commandPalette", "Command Palette…", .view, chord([.primary, .shift], ch("p")), .menu, menu: .view,
            menuID: "view-command-palette", enabled: hasWorkspace) { [weak center] in
            guard let center, let workspace = current() else { return }
            center.bringProjectWindowForward()
            quickOpen.hide()
            palette.toggle(registry: registry, workspace: workspace)
        }
        // Window menu: tab cycling and selection. Each acts on the focused terminal's tabs while a terminal has focus.
        add("tab.next", "Next Tab", .tab, chord(.ctrl, .named(.tab)), .menu, menu: .window,
            menuID: "window-next-tab", enabled: hasWorkspace) {
            if let t = current()?.terminalFocusActions, t.isFocused() { t.cycleTab(1); return }
            current()?.cycleTab(1)
        }
        add("tab.previous", "Previous Tab", .tab, chord([.ctrl, .shift], .named(.tab)), .menu, menu: .window,
            menuID: "window-previous-tab", enabled: hasWorkspace) {
            if let t = current()?.terminalFocusActions, t.isFocused() { t.cycleTab(-1); return }
            current()?.cycleTab(-1)
        }
        for n in 1...9 {
            add("tab.select\(n)", "Go to Tab \(n)", .tab, chord(.primary, ch(Character(String(n)))), .menu, menu: .window,
                menuID: "window-tab-\(n)", enabled: hasWorkspace) { current()?.selectTab(number: n) }
        }
        // Terminal commands: each acts only while a terminal pane is focused, so its chord never shadows the editor's
        // copy, find or select-all. Elsewhere Ctrl belongs to the program, so they take primary+Shift.
        #if os(macOS)
        let terminalMods: ChordModifiers = .primary
        #else
        let terminalMods: ChordModifiers = [.primary, .shift]
        #endif
        let terminalFocused: @MainActor () -> Bool = { current()?.terminalHasFocus ?? false }
        func addTerminal(_ id: String, _ title: String, _ key: Character, keyID: String, defaultChord: Bool = true,
                         _ run: @escaping @MainActor (TerminalFocusActions) -> Void) {
            add(id, title, .terminal, defaultChord ? chord(terminalMods, ch(key)) : nil, .global, keyID: keyID, enabled: terminalFocused) {
                if let actions = current()?.terminalFocusActions, actions.isFocused() { run(actions) }
            }
        }
        addTerminal("terminal.copy", "Copy", "c", keyID: "global-key-terminal-copy") { $0.copy() }
        addTerminal("terminal.selectAll", "Select All", "a", keyID: "global-key-terminal-select-all") { $0.selectAll() }
        // On a Mac ⌘F belongs to Edit > Find…, which opens this find while a terminal has focus; elsewhere the terminal's
        // chord (primary+Shift+F) differs from the editor's, so it keeps its own key.
        #if os(macOS)
        let terminalFindChord = false
        #else
        let terminalFindChord = true
        #endif
        addTerminal("terminal.find", "Find in Terminal", "f", keyID: "global-key-terminal-find",
                    defaultChord: terminalFindChord) { $0.openFind() }
        addTerminal("terminal.clearScrollback", "Clear Terminal Scrollback", "k",
                    keyID: "global-key-terminal-clear") { $0.clearScrollback() }
    }
}
