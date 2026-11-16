import AlloyCore
import MetalUI

/// The shortcut of the app menu's Settings… item.
@MainActor public let settingsShortcut = KeyboardShortcut(",", modifiers: [.command])

/// Alloy's additions to MetalUI's default menu bar: "Settings…" (⌘,) in the application menu and a Go menu.
/// Settings… fills MetalUI's `.appSettings` group, which sits in its own section after About.
@MainActor @CommandsBuilder
public func alloyCommands(model: LauncherModel, settings: SettingsWindowController, themes: ThemeController?) -> some Commands {
    CommandGroup(replacing: .appSettings) {
        // Settings edit the open project's workspace, so it needs a project; the chooser has none.
        Button("Settings…") { if let workspace = model.workspace { settings.open(workspace: workspace, themes: themes) } }
            .keyboardShortcut(settingsShortcut)
            .disabled(model.workspace == nil)
            .accessibilityIdentifier("app-settings")
    }
    // Go to Definition (plain F12). A focused handler claims the key first, so the panel's own F12 handling and this
    // item never both fire.
    CommandMenu("Go") {
        Button("Go to Definition") { model.workspace?.goToDefinition?() }
            .keyboardShortcut(goToDefinitionShortcut)
    }
    CommandMenu("View") {
        Button("Chat Mode") { model.workspace?.setMode(.chat) }
            .keyboardShortcut("1", modifiers: [.control, .command])
            .disabled(model.workspace == nil)
            .accessibilityIdentifier("view-mode-chat")
        Button("Code Mode") { model.workspace?.setMode(.code) }
            .keyboardShortcut("2", modifiers: [.control, .command])
            .disabled(model.workspace == nil)
            .accessibilityIdentifier("view-mode-code")
        Button("Split Right") { model.workspace?.splitFocused(.horizontal) }
            .keyboardShortcut("\\", modifiers: [.command])
            .disabled(model.workspace?.mode != .code)
            .accessibilityIdentifier("view-split-right")
        Button("Split Down") { model.workspace?.splitFocused(.vertical) }
            .keyboardShortcut("\\", modifiers: [.option, .command])
            .disabled(model.workspace?.mode != .code)
            .accessibilityIdentifier("view-split-down")
        Button("Focus Left Group") { model.workspace?.focusGroup(.left) }
            .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
            .disabled(model.workspace?.mode != .code)
            .accessibilityIdentifier("view-focus-left")
        Button("Focus Right Group") { model.workspace?.focusGroup(.right) }
            .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
            .disabled(model.workspace?.mode != .code)
            .accessibilityIdentifier("view-focus-right")
        Button("Focus Up Group") { model.workspace?.focusGroup(.up) }
            .keyboardShortcut(.upArrow, modifiers: [.control, .command])
            .disabled(model.workspace?.mode != .code)
            .accessibilityIdentifier("view-focus-up")
        Button("Focus Down Group") { model.workspace?.focusGroup(.down) }
            .keyboardShortcut(.downArrow, modifiers: [.control, .command])
            .disabled(model.workspace?.mode != .code)
            .accessibilityIdentifier("view-focus-down")
        Button("Reveal in Tree") { model.workspace?.revealInTree() }
            .keyboardShortcut("l", modifiers: [.option, .command])
            .disabled(model.workspace?.mode != .code)
            .accessibilityIdentifier("view-reveal-in-tree")
        Button("Toggle Chat Column") { model.workspace?.codeLayout.chatCollapsed.toggle() }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.workspace?.mode != .code)
            .accessibilityIdentifier("view-toggle-chat-column")
    }
}
