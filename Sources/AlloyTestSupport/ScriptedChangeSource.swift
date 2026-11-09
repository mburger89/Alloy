import AlloyCore
import Foundation

/// A `FileChangeSource` tests drive by hand: `send` delivers one batch of absolute paths.
public final class ScriptedChangeSource: FileChangeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<[String]>.Continuation?
    private var early: [[String]] = []

    public init() {}

    public func changes() -> AsyncStream<[String]> {
        AsyncStream { c in
            let backlog = lock.withLock { () -> [[String]] in
                continuation = c
                defer { early = [] }
                return early
            }
            for batch in backlog { c.yield(batch) }
        }
    }

    public func send(_ paths: [String]) {
        let c = lock.withLock { () -> AsyncStream<[String]>.Continuation? in
            if continuation == nil { early.append(paths) }
            return continuation
        }
        c?.yield(paths)
    }
}
