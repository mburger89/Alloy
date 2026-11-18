import AlloyCore
import MetalUI

/// Alloy's additions to MetalUI's default menu bar, generated from the command registry: "Settings…" in the
/// application menu (MetalUI's `.appSettings` group, which sits in its own section after About), a Go menu, a Git menu and a View
/// menu. Items, titles, accessibility ids and shortcuts come from the registered `CommandDescriptor`s and the keymap
/// (so user overrides apply); see docs/command-registry.md. The content closures run when the bar is shown or a key
/// reaches the command stage, so enabled state and shortcuts are live.
@MainActor @CommandsBuilder
public func alloyCommands(center: CommandCenter, updates: UpdateModel? = nil, checkForUpdates: @escaping @MainActor () -> Void = {}) -> some Commands {
    let registry = center.registry
    if let updates {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") { checkForUpdates() }
                .disabled(updates.isBusy)
                .accessibilityIdentifier("menu-check-for-updates")
        }
    }
    CommandGroup(replacing: .appSettings) {
        for command in registry.commands(in: .appSettings) { registryMenuItem(command, registry: registry) }
    }
    CommandGroup(after: .pasteboard) {
        for command in registry.commands(in: .edit) { registryMenuItem(command, registry: registry) }
    }
    CommandMenu("Go") {
        for command in registry.commands(in: .go) { registryMenuItem(command, registry: registry) }
    }
    // Always present: the items are disabled with no repository, as the hand-built menu was.
    CommandMenu("Git") {
        for command in registry.commands(in: .git) { registryMenuItem(command, registry: registry) }
    }
    CommandMenu("View") {
        for command in registry.commands(in: .view) { registryMenuItem(command, registry: registry) }
        Menu("Folding") {
            for command in registry.commands(in: .folding) { registryMenuItem(command, registry: registry) }
        }
    }
    // Plugin commands that ask for a menu. Evaluated when the bar is shown (no observation), so a plugin that registers
    // after launch appears at the next evaluation, and the menu is absent while nothing is placed in it.
    if registry.hasCommands(in: .plugins) {
        CommandMenu("Plugins") {
            for command in registry.commands(in: .plugins) { registryMenuItem(command, registry: registry) }
        }
    }
}

/// One menu item for a registered command. Only a `.menu`-bound command carries its chord on the item; a command
/// whose chord the user unbound (or whose chord clashed) gets no shortcut but stays in the menu.
@MainActor
private func registryMenuItem(_ command: RegisteredCommand, registry: CommandRegistry) -> some MenuContent {
    let descriptor = command.descriptor
    let shortcut = descriptor.binding == .menu ? registry.keymap.chord(for: descriptor.id)?.shortcut : nil
    return Button(descriptor.title) { registry.run(id: descriptor.id) }
        .keyboardShortcut(shortcut)
        .disabled(!command.isEnabled())
        .accessibilityIdentifier(descriptor.menuID)
}
