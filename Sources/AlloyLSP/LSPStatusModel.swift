import Observation

/// The only observable LSP state: which server serves which open file and what it is doing. Updated only when a
/// server's state actually changes, never per message.
@MainActor @Observable
public final class LSPStatusModel {
    public private(set) var byPath: [String: (name: String, state: ServerState)] = [:]

    public init() {}

    /// Records `state` for `path`. Does nothing (and so notifies no observer) when it is already recorded.
    public func set(path: String, name: String, state: ServerState) {
        if let old = byPath[path], old.name == name, old.state == state { return }
        byPath[path] = (name, state)
    }

    public func remove(path: String) {
        guard byPath[path] != nil else { return }
        byPath[path] = nil
    }

    public func removeAll() {
        guard !byPath.isEmpty else { return }
        byPath = [:]
    }
}
