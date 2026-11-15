import Observation

/// The only observable LSP state: which server serves which open file and what it is doing. Updated only when a
/// server's state actually changes, never per message.
@MainActor @Observable
public final class LSPStatusModel {
    public private(set) var byPath: [String: (name: String, state: ServerState)] = [:]

    /// The linters running for each path, in arrival order.
    public private(set) var linters: [String: [(id: String, name: String, state: ServerState)]] = [:]

    public init() {}

    /// Records a linter's `state` for `path`. Does nothing when it is already recorded.
    public func setLinter(path: String, id: String, name: String, state: ServerState) {
        var list = linters[path] ?? []
        if let i = list.firstIndex(where: { $0.id == id }) {
            if list[i].name == name, list[i].state == state { return }
            list[i] = (id, name, state)
        } else {
            list.append((id, name, state))
        }
        linters[path] = list
    }

    public func removeLinter(path: String, id: String) {
        guard var list = linters[path], let i = list.firstIndex(where: { $0.id == id }) else { return }
        list.remove(at: i)
        linters[path] = list.isEmpty ? nil : list
    }

    /// Records `state` for `path`. Does nothing (and so notifies no observer) when it is already recorded.
    public func set(path: String, name: String, state: ServerState) {
        if let old = byPath[path], old.name == name, old.state == state { return }
        byPath[path] = (name, state)
    }

    /// Drops the main server's entry only (the linters stay).
    public func removeMain(path: String) {
        if byPath[path] != nil { byPath[path] = nil }
    }

    public func remove(path: String) {
        if byPath[path] != nil { byPath[path] = nil }
        if linters[path] != nil { linters[path] = nil }
    }

    public func removeAll() {
        if !byPath.isEmpty { byPath = [:] }
        if !linters.isEmpty { linters = [:] }
    }
}
