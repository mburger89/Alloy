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
        let current: @MainActor () -> Workspace? = { [unowned center] in center.workspace }
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
            if let workspace = current(), let controller = settings() { controller.open(workspace: workspace, themes: themes()) }
        }
        // F12: a focused handler claims the key first (MetalUI runs menu shortcuts only after the focused view declines),
        // so the code panel's own F12 handling and this item never both fire.
        add("go.definition", "Go to Definition", .go, chord([], .named(.f12)), .menu, menu: .go, recents: true,
            enabled: hasWorkspace) { current()?.goToDefinition?() }
        add("search.nextResult", "Next Result", .go, chord([], .named(.f4)), .menu, menu: .go,
            menuID: "go-next-result", enabled: hasWorkspace) { current()?.search.step(1) }
        add("search.previousResult", "Previous Result", .go, chord(.shift, .named(.f4)), .menu, menu: .go,
            menuID: "go-previous-result", enabled: hasWorkspace) { current()?.search.step(-1) }

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
        add("search.findInFiles", "Find in Files", .view, chord([.cmd, .shift], ch("f")), .menu, menu: .view, recents: true,
            menuID: "view-find-in-files", enabled: hasWorkspace) { current()?.showSearch(replace: false) }
        add("search.replaceInFiles", "Replace in Files", .view, chord([.cmd, .shift], ch("h")), .menu, menu: .view, recents: true,
            menuID: "view-replace-in-files", enabled: hasWorkspace) { current()?.showSearch(replace: true) }

        add("view.commandPalette", "Command Palette…", .view, chord([.primary, .shift], ch("p")), .menu, menu: .view,
            menuID: "view-command-palette", enabled: hasWorkspace) { [unowned center] in
            guard let workspace = current() else { return }
            center.bringProjectWindowForward()
            quickOpen.hide()
            palette.toggle(registry: registry, workspace: workspace)
        }
        add("go.quickOpen", "Quick Open", .go, chord(.primary, ch("p")), .global, recents: true,
            keyID: "global-key-quick-open", enabled: hasWorkspace) {
            guard let workspace = current() else { return }
            palette.hide()
            if quickOpen.isShowing { quickOpen.hide() } else { quickOpen.show(workspace: workspace) }
        }
        // Esc closes quick-open first; a tab never closes under it.
        add("tab.close", "Close Tab", .tab, chord(.primary, ch("w")), .global,
            keyID: "global-key-close-tab", enabled: { hasWorkspace() && !quickOpen.isShowing && !palette.isShowing }) { current()?.closeActiveTab() }
        add("tab.next", "Next Tab", .tab, chord(.ctrl, .named(.tab)), .global,
            keyID: "global-key-next-tab", enabled: hasWorkspace) { current()?.cycleTab(1) }
        add("tab.previous", "Previous Tab", .tab, chord([.ctrl, .shift], .named(.tab)), .global,
            keyID: "global-key-previous-tab", enabled: hasWorkspace) { current()?.cycleTab(-1) }
        for n in 1...9 {
            add("tab.select\(n)", "Go to Tab \(n)", .tab, chord(.primary, ch(Character(String(n)))), .global,
                keyID: "global-key-tab-\(n)", enabled: hasWorkspace) { current()?.selectTab(number: n) }
        }
        // Chat mode's sidebar button owns ⌘N; Code mode has no sidebar sessions list, so the key lives in GlobalKeys.
        add("session.new", "New Session", .session, chord(.cmd, ch("n")), .globalInCode, recents: true,
            keyID: "global-key-new-session", enabled: hasWorkspace) { current()?.startNewSession() }
    }
}
