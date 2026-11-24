import AlloyCore
import AlloyHighlight
import AlloyPlugins
import AlloyRPC
import Foundation

/// Plugin commands in the shared command registry: registered when a scripted plugin is effectively enabled, removed when
/// it is disabled, removed or auto-disabled. Running one starts the plugin and sends `commands/execute`.
extension PluginCoordinator {
    /// Brings the registry in line with `specs` (the commands of every effectively enabled scripted plugin): plugins whose
    /// commands did not change are left alone, the rest are unregistered and registered again in one revision bump.
    func applyCommands(_ specs: [String: [PluginCommandSpec]]) {
        guard specs != registeredCommands else { return }
        var stale: [String] = []
        for (id, old) in registeredCommands where specs[id] != old { stale.append(id) }
        for id in stale {
            registry.unregister(source: .plugin(id: id))
            commandNotes[id] = nil
        }
        var items: [(descriptor: CommandDescriptor, isEnabled: @MainActor () -> Bool, run: @MainActor () -> Void)] = []
        var fresh: [String] = []
        for id in specs.keys.sorted() where registeredCommands[id] != specs[id] {
            fresh.append(id)
            let category = CommandCategory(name: pluginName(id))
            for spec in specs[id] ?? [] {
                let descriptor = CommandDescriptor(
                    id: "\(id).\(spec.id)", title: spec.title, category: category, shortcut: spec.shortcut,
                    binding: spec.inPluginsMenu ? .menu : .none, menu: spec.inPluginsMenu ? .plugins : nil,
                    source: .plugin(id: id))
                items.append((descriptor, { [weak self] in self?.isEnabled(spec.when) ?? false },
                              { [weak self] in self?.runCommand(plugin: id, command: spec.id) }))
            }
        }
        registeredCommands = specs
        guard !items.isEmpty else { return }
        let before = registry.rejections.count
        registry.register(contentsOf: items)
        for rejection in registry.rejections.dropFirst(before) {
            guard case .plugin(let id) = rejection.source, fresh.contains(id) else { continue }
            switch rejection.reason {
            case .duplicateID: commandNotes[id, default: []].append("Command \(rejection.id) clashes with an existing command")
            case .pluginShortcutDropped:
                let chord = items.first { $0.descriptor.id == rejection.id }?.descriptor.shortcut
                let text = chord.flatMap { CommandPaletteModel.shortcutText(for: $0) ?? $0.description } ?? ""
                commandNotes[id, default: []].append("Shortcut \(text) not bound")
            case .chordTaken: break
            }
        }
    }

    private func pluginName(_ id: String) -> String {
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
