import AlloyCore
import Foundation
import Observation

/// A descriptor with the closures that make it live. The closures are only called from actions (a key, a menu item, a
/// palette row), never from a view body.
public struct RegisteredCommand {
    public let descriptor: CommandDescriptor
    public let isEnabled: @MainActor () -> Bool
    public let run: @MainActor () -> Void
}

public enum RejectionReason: Hashable, Sendable {
    /// Another registered command has this id.
    case duplicateID
    /// Another registered command already holds this default chord.
    case chordTaken(by: String)
    /// A plugin command's shortcut is dropped (the command itself is added) until MetalUI can show plugin shortcuts.
    case pluginShortcutDropped
}

public enum RegistrationResult: Hashable, Sendable {
    case added
    case rejected(RejectionReason)
}

public struct Rejection: Hashable, Sendable {
    public let id: String
    public let source: CommandSource
    public let reason: RejectionReason
}

/// The one app-wide list of commands. Menus, global keys and the palette are all generated from it; see
/// docs/command-registry.md. Only `revision` is observed: it bumps when the set of commands changes, never per frame.
@MainActor @Observable
public final class CommandRegistry {
    public private(set) var revision = 0
    @ObservationIgnored public let keymap: Keymap
    @ObservationIgnored private let workspace: @MainActor () -> Workspace?
    @ObservationIgnored private var storage: [RegisteredCommand] = []
    @ObservationIgnored private var index: [String: Int] = [:]
    @ObservationIgnored public private(set) var rejections: [Rejection] = []
    /// The user's key overrides (`AlloySettings.keybindings`). Setting it re-resolves the keymap.
    @ObservationIgnored public var overrides: [String: String] = [:] { didSet { if overrides != oldValue { refreshKeymap() } } }

    public init(workspace: @escaping @MainActor () -> Workspace?) {
        self.workspace = workspace
        keymap = Keymap()
    }

    /// Every command in registration order (built-ins first, then plugins in the order they registered).
    public var commands: [RegisteredCommand] { storage }

    public func command(id: String) -> RegisteredCommand? { index[id].map { storage[$0] } }

    public func commands(in placement: MenuPlacement) -> [RegisteredCommand] {
        storage.filter { $0.descriptor.menu == placement }
    }

    public func hasCommands(in placement: MenuPlacement) -> Bool {
        storage.contains { $0.descriptor.menu == placement }
    }

    /// Adds a command. A repeated id is rejected. A built-in whose default chord another command holds is rejected
    /// (the first registered wins). A plugin command is added without its shortcut, and a rejection is noted.
    @discardableResult
    public func register(_ d: CommandDescriptor, isEnabled: @escaping @MainActor () -> Bool = { true },
                         run: @escaping @MainActor () -> Void) -> RegistrationResult {
        guard index[d.id] == nil else { return reject(d, .duplicateID) }
        var descriptor = d
        var droppedShortcut = false
        if case .plugin = d.source {
            if d.shortcut != nil { descriptor.shortcut = nil; droppedShortcut = true }
        } else if let chord = d.shortcut, let holder = storage.first(where: { $0.descriptor.shortcut == chord }) {
            return reject(d, .chordTaken(by: holder.descriptor.id))
        }
        index[d.id] = storage.count
        storage.append(RegisteredCommand(descriptor: descriptor, isEnabled: isEnabled, run: run))
        if droppedShortcut { rejections.append(Rejection(id: d.id, source: d.source, reason: .pluginShortcutDropped)) }
        changed()
        return .added
    }

    /// Adds several commands, each as `register` does, with one revision bump.
    public func register(contentsOf items: [(descriptor: CommandDescriptor, isEnabled: @MainActor () -> Bool, run: @MainActor () -> Void)]) {
        let before = revision
        for item in items { register(item.descriptor, isEnabled: item.isEnabled, run: item.run) }
        if revision - before > 1 { revision = before + 1 }
    }

    /// Removes every command a source registered. Safe from inside one of that source's own commands.
    public func unregister(source: CommandSource) {
        let kept = storage.filter { $0.descriptor.source != source }
        guard kept.count != storage.count else { return }
        storage = kept
        index = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1.descriptor.id, $0) })
        changed()
    }

    /// Runs the command unless it is missing or disabled; counts it as recent when it records recents. Returns whether it ran.
    @discardableResult
    public func run(id: String) -> Bool {
        guard let command = command(id: id), command.isEnabled() else { return false }
        let body = command.run
        body()
        if command.descriptor.recordsRecent, let ws = workspace() { ws.noteCommandRun(id: id) }
        return true
    }

    private func reject(_ d: CommandDescriptor, _ reason: RejectionReason) -> RegistrationResult {
        rejections.append(Rejection(id: d.id, source: d.source, reason: reason))
        return .rejected(reason)
    }

    private func changed() {
        refreshKeymap()
        revision += 1
    }

    private func refreshKeymap() {
        keymap.update(defaults: storage.map { ($0.descriptor.id, $0.descriptor.shortcut) }, overrides: overrides)
    }
}

/// AlloyCore's `Keymap`, under a name that cannot clash with MetalUI's own `Keymap` in files that import both.
typealias ResolvedKeymap = Keymap
