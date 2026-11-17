#if !os(Windows)

import MetalUITerminal

/// Spawns real child processes on a `PseudoTerminal`.
public struct LivePtySpawner: PtySpawner {
    public init() {}

    public func spawn(_ request: PtySpawnRequest) throws(PseudoTerminalError) -> any PtyHandle {
        try PseudoTerminal.spawn(executable: request.executable, argv: request.argv, env: request.env,
                                 cwd: request.cwd, size: request.size)
    }
}

#endif
