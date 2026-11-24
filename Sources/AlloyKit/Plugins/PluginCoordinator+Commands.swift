import AlloyCore
import AlloyHighlight
import AlloyPlugins
import AlloyRPC
import Foundation
import MetalUI

/// Plugin commands in the shared command registry: registered when a scripted plugin is effectively enabled, removed when
/// it is disabled, removed or auto-disabled. Running one starts the plugin and sends `commands/execute`.
extension PluginCoordinator {
    /// Brings the registry in line with `specs` (the commands of every effectively enabled scripted plugin): plugins whose
    /// commands did not change are left alone, the rest are unregistered and registered again in one revision bump.
    func applyCommands(_ specs: [String: [PluginCommandSpec]], tasks: [String: [PluginTaskSpec]] = [:]) {
        guard specs != registeredCommands || tasks != registeredTasks else { return }
        var stale: [String] = []
        for id in Set(registeredCommands.keys).union(registeredTasks.keys)
        where specs[id] != registeredCommands[id] || tasks[id] != registeredTasks[id] { stale.append(id) }
        for id in stale {
            registry.unregister(source: .plugin(id: id))
            commandNotes[id] = nil
            for (commandID, owner) in shortcutOwners where owner == id {
                shortcutNotes[commandID] = nil
                shortcutOwners[commandID] = nil
            }
        }
        var items: [(descriptor: CommandDescriptor, isEnabled: @MainActor () -> Bool, run: @MainActor () -> Void)] = []
        var fresh: [String] = []
        let clashes = center.map { ShortcutClashes(center: $0) }
        let overrides = workspace?.settings.keybindings ?? [:]
        for id in Set(specs.keys).union(tasks.keys).sorted() where registeredCommands[id] != specs[id] || registeredTasks[id] != tasks[id] {
            fresh.append(id)
            let category = CommandCategory(name: pluginName(id))
            items += taskItems(plugin: id, tasks: tasks[id] ?? [], category: category)
            for spec in specs[id] ?? [] {
                let commandID = "\(id).\(spec.id)"
                var chord = spec.shortcut
                if let proposed = spec.shortcut, !Self.hasRequiredModifier(proposed) {
                    // A bare letter would fire while the user types.
                    chord = nil
                    let text = proposed.shortcut(for: .current).displayText
                    noteShortcut(commandID, owner: id, "Shortcut \(text) not bound: it needs Command, Control or Option, or is an F-key")
                } else if let proposed = spec.shortcut, let clashes {
                    // Any clash at all (soft code view keys included) drops the key; a free chord is bound.
                    if let first = clashes.clashes(for: proposed, excluding: commandID, overrides: overrides).first {
                        chord = nil
                        noteShortcut(commandID, owner: id, Self.shortcutNote(proposed, clash: first))
                    }
                }
                let descriptor = CommandDescriptor(
                    id: commandID, title: spec.title, category: category, shortcut: chord,
                    binding: spec.inPluginsMenu ? .menu : (chord != nil ? .global : .none), menu: spec.inPluginsMenu ? .plugins : nil,
                    source: .plugin(id: id))
                items.append((descriptor, { [weak self] in self?.isEnabled(spec.when) ?? false },
                              { [weak self] in self?.runCommand(plugin: id, command: spec.id) }))
            }
        }
        registeredCommands = specs
        registeredTasks = tasks
        guard !items.isEmpty else { return }
        let before = registry.rejections.count
        registry.register(contentsOf: items, keepsPluginShortcut: clashes != nil)
        for rejection in registry.rejections.dropFirst(before) {
            guard case .plugin(let id) = rejection.source, fresh.contains(id) else { continue }
            switch rejection.reason {
            case .duplicateID: commandNotes[id, default: []].append("Command \(rejection.id) clashes with an existing command")
            case .pluginShortcutDropped:
                let chord = items.first { $0.descriptor.id == rejection.id }?.descriptor.shortcut
                let text = chord.flatMap { CommandPaletteModel.shortcutText(for: $0) ?? $0.description } ?? ""
                commandNotes[id, default: []].append("Shortcut \(text) not bound")
            case .chordTaken(let holder):
                let chord = items.first { $0.descriptor.id == rejection.id }?.descriptor.shortcut
                let title = registry.command(id: holder)?.descriptor.title ?? holder
                let note = chord.map { "Shortcut \($0.shortcut(for: .current).displayText) not bound: used by \(title)" }
                if let note { noteShortcut(rejection.id, owner: id, note) }
            }
        }
    }

    /// Why the command's proposed shortcut is not bound, or nil when it is (or none was proposed).
    public func shortcutNote(for commandID: String) -> String? { shortcutNotes[commandID] }

    /// The user's keybindings changed: vets every plugin chord again, registering the commands anew with one revision bump.
    func keybindingsChanged() {
        guard registeredCommands.values.contains(where: { $0.contains { $0.shortcut != nil } }) || !shortcutNotes.isEmpty else { return }
        let specs = registeredCommands, tasks = registeredTasks
        for id in Set(specs.keys).union(tasks.keys) {
            registry.unregister(source: .plugin(id: id))
            commandNotes[id] = nil
        }
        shortcutNotes = [:]
        shortcutOwners = [:]
        registeredCommands = [:]
        registeredTasks = [:]
        applyCommands(specs, tasks: tasks)
    }

    private func noteShortcut(_ commandID: String, owner: String, _ note: String) {
        shortcutNotes[commandID] = note
        shortcutOwners[commandID] = owner
        commandNotes[owner, default: []].append(note)
    }

    /// A plugin shortcut needs Command, Control or Option (or the platform's primary key), or is an F-key.
    static func hasRequiredModifier(_ chord: KeyChord) -> Bool {
        if !chord.modifiers.isDisjoint(with: [.primary, .cmd, .ctrl, .alt]) { return true }
        if case .named(let key) = chord.key, key.rawValue.hasPrefix("f"), key.rawValue.dropFirst().allSatisfy(\.isNumber) { return true }
        return false
    }

    private static func shortcutNote(_ chord: KeyChord, clash: ShortcutClash) -> String {
        let text = chord.shortcut(for: .current).displayText
        let holder = clash.kind == .system ? "the system" : clash.title
        return "Shortcut \(text) not bound: used by \(holder)"
    }

    func pluginName(_ id: String) -> String {
        installedManifests[id]?.name ?? id
    }

    /// Whether a command with this `when` may run now. Called when a menu or the palette is evaluated, never per frame.
    private func isEnabled(_ when: CommandWhen) -> Bool {
        guard let workspace else { return false }
        switch when {
        case .always: return true
        case .codeMode: return workspace.mode == .code
        case .editorFocused: return workspace.canRunMultiCursor()
        case .language(let id):
            guard workspace.mode == .code, let path = workspace.activeTab(in: workspace.defaultPane) else { return false }
            return languageID(forPath: path) == id
        }
    }

    /// The language id of a file: the covering server's id, else the highlighter's. Cached until the servers change.
    func languageID(forPath path: String) -> String? {
        if let hit = languageCache[path] { return hit }
        let id = (workspace?.languageServices as? LSPCoordinator)?.languageID(forPath: path) ?? Language.detect(path: path)?.rawValue
        if languageCache.count > 512 { languageCache = [:] }
        languageCache[path] = .some(id)
        return id
    }

    /// Starts the plugin and asks it to run the command. Errors go to the plugin's log; a plugin stopped meanwhile ends quietly.
    private func runCommand(plugin: String, command: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.activate(plugin: plugin, .command), let host = self.host else {
                self.commandOutcomes.append((plugin, command, JSONRPCError.connectionClosed.code))
                return
            }
            do {
                _ = try await host.request(plugin, "commands/execute", .object(["command": .string(command)]), ui: true)
                self.commandOutcomes.append((plugin, command, nil))
            } catch let error as JSONRPCError {
                self.commandOutcomes.append((plugin, command, error.code))
                if error.code != JSONRPCError.requestCancelled, error.code != JSONRPCError.connectionClosed.code {
                    self.appendLog(plugin: plugin, "Command \(command) failed: \(error.message)")
                }
            } catch {}
        }
    }
}
