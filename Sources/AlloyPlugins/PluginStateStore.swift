import AlloyCore
import Foundation

public enum PluginStateError: Error, Sendable, Equatable {
    /// The plugin's whole state would exceed `PluginLimits.stateBytes` once encoded.
    case tooLarge
}

/// Per-project plugin state: `<directory>/<plugin id>.json`, one JSON object per plugin. Writes land `stateDebounce`
/// seconds after the last change and on `flush()` (shutdown); nothing here touches `ui-state.json`.
public actor PluginStateStore {
    private let directory: URL
    private let limits: PluginLimits
    private let clock: any AutosaveClock
    private var cache: [String: [String: JSONValue]] = [:]
    private var pending: [String: Task<Void, Never>] = [:]
    /// How many state files were written (tests read it to see the debounce).
    public private(set) var writeCount = 0

    public init(directory: URL, limits: PluginLimits, clock: any AutosaveClock) {
        self.directory = directory
        self.limits = limits
        self.clock = clock
    }

    private func url(_ id: String) -> URL {
        directory.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    private func state(_ id: String) -> [String: JSONValue] {
        if let cached = cache[id] { return cached }
        var loaded: [String: JSONValue] = [:]
        if let data = try? Data(contentsOf: url(id)), case .object(let o)? = JSONValue.parse(data) { loaded = o }
        cache[id] = loaded
        return loaded
    }

    public func get(_ id: String, key: String) -> JSONValue? { state(id)[key] }

    /// Sets `key` (nil or `.null` deletes). Throws `.tooLarge` and changes nothing when the encoded state would pass the limit.
    public func set(_ id: String, key: String, value: JSONValue?) throws(PluginStateError) {
        var next = state(id)
        if let value, value != .null { next[key] = value } else { next[key] = nil }
        guard Self.encode(next).count <= limits.stateBytes else { throw .tooLarge }
        cache[id] = next
        schedule(id)
    }

    private static func encode(_ object: [String: JSONValue]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(JSONValue.object(object))) ?? Data()
    }

    private func schedule(_ id: String) {
        pending[id]?.cancel()
        let deadline = clock.now + limits.stateDebounce, clock = clock
        pending[id] = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.write(id)
        }
    }

    private func write(_ id: String) {
        pending[id] = nil
        guard let object = cache[id] else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if (try? Self.encode(object).write(to: url(id), options: .atomic)) != nil { writeCount += 1 }
    }

    /// Writes every change still waiting for its debounce.
    public func flush() async {
        for (id, task) in pending {
            task.cancel()
            write(id)
        }
    }
}
