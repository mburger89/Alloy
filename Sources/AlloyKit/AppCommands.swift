import AlloyCore
import MetalUI

/// The shortcut of the app menu's Settings… item.
@MainActor public let settingsShortcut = KeyboardShortcut(",", modifiers: [.command])

/// Alloy's additions to MetalUI's default menu bar: "Settings…" (⌘,) in the application menu and a Go menu.
/// Settings… fills MetalUI's `.appSettings` group, which sits in its own section after About.
@MainActor @CommandsBuilder
public func alloyCommands(model: LauncherModel) -> some Commands {
    CommandGroup(replacing: .appSettings) {
        // Settings is a view over the workspace's chat column, so it needs a project; the chooser has none.
        Button("Settings…") { model.workspace?.openSettings?() }
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
}
