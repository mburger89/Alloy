import AlloyPlugins
import Foundation

/// The latest decorations each plugin set for each open document. Not observable: nothing in a view body reads it; the code
/// panel applies a snapshot to its views imperatively through `applyHandler`.
@MainActor
final class PluginDecorationStore {
    private var sets: [String: [String: PluginDecorationSet]] = [:]
    /// Called with a path whose snapshots changed (also when they were removed), so its views can paint again.
    var applyHandler: ((String) -> Void)?
    /// How many changed sets reached the views so far (test observability for the frame guards).
    private(set) var applyCount = 0

    func snapshots(for path: String) -> [(pluginID: String, set: PluginDecorationSet)] {
        (sets[path] ?? [:]).sorted { $0.key < $1.key }.map { (pluginID: $0.key, set: $0.value) }
    }

    /// Stores `set` for the plugin and document. An identical set changes nothing and applies nothing.
    func set(_ id: String, path: String, _ set: PluginDecorationSet) {
        if sets[path]?[id] == set || (set.isEmpty && sets[path]?[id] == nil) { return }
        if set.isEmpty {
            sets[path]?[id] = nil
            if sets[path]?.isEmpty == true { sets[path] = nil }
        } else {
            sets[path, default: [:]][id] = set
        }
        applyCount += 1
        applyHandler?(path)
    }

    /// Drops everything the plugin set (it stopped or was switched off).
    func remove(pluginID: String) {
        for path in sets.keys.sorted() where sets[path]?[pluginID] != nil {
            sets[path]?[pluginID] = nil
            if sets[path]?.isEmpty == true { sets[path] = nil }
            applyCount += 1
            applyHandler?(path)
        }
    }

    /// Drops everything set for a document (it closed).
    func remove(path: String) {
        guard sets.removeValue(forKey: path) != nil else { return }
        applyCount += 1
        applyHandler?(path)
    }

    func removeAll() {
        for path in sets.keys.sorted() { remove(path: path) }
    }

    func hasSets(for id: String) -> Bool { sets.values.contains { $0[id] != nil } }
}
