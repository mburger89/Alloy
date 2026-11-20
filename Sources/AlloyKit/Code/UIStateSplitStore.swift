import AlloyCore
import Foundation
import MetalUI

/// MetalUI's split-size store backed by the project's `ui-state.json` (through the workspace) instead of `UserDefaults`.
@MainActor
final class UIStateSplitStore: SplitViewAutosaveStore {
    private let workspace: Workspace
    /// Every name MetalUI asked for, in order (tests read it).
    private(set) var queriedNames: [String] = []

    init(workspace: Workspace) { self.workspace = workspace }

    func paneSizes(forName name: String) -> [Double]? {
        if !queriedNames.contains(name) { queriedNames.append(name) }
        return workspace.paneSizes(forName: name)
    }

    func setPaneSizes(_ sizes: [Double], forName name: String) {
        workspace.setPaneSizes(sizes, forName: name)
    }
}

extension Workspace {
    /// The "+" button, the title pill and ⌘N: a new session named after the count, selected.
    /// Without a backend (⌘N, the empty-state button) the default agent runs it, else Claude.
    func startNewSession(backend: SessionBackend? = nil) {
        let n = sessions.count + 1
        let backend = backend ?? defaultBackend
        if backend == .claude {
            Task { await newSessionFromUser(name: "Session \(n)") }
        } else {
            Task { await newSession(name: "Session \(n)", backend: backend) }
        }
    }
}
