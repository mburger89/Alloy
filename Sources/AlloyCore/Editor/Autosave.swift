import Foundation
import Observation

/// Time source for the autosave debounce, injectable so tests never sleep. Times are seconds on an arbitrary
/// monotonic scale; `sleep(until:)` returns once `now >= deadline`.
public protocol AutosaveClock: Sendable {
    var now: Double { get }
    func sleep(until deadline: Double) async throws
}

public struct SystemAutosaveClock: AutosaveClock {
    public init() {}
    public var now: Double { ProcessInfo.processInfo.systemUptime }
    public func sleep(until deadline: Double) async throws {
        let wait = deadline - now
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
    }
}

/// Saves a document a fixed time after its last edit. Each watched buffer is observed; every version change
/// restarts that path's timer, and a timer that fires calls `save`. The deadline is taken from the clock at
/// the moment of the change (not when the timer task first runs), so a test clock is deterministic.
@MainActor
final class Autosave {
    static let delay = 1.0

    private let clock: any AutosaveClock
    private let save: @MainActor (String) async -> Void
    private var timers: [String: (generation: Int, task: Task<Void, Never>)] = [:]
    private var generation = 0
    private var watched: [String: Int] = [:]
    private var watchTokens = 0

    init(clock: any AutosaveClock, save: @escaping @MainActor (String) async -> Void) {
        self.clock = clock; self.save = save
    }

    /// Starts observing `doc`'s buffer. `isCurrent` says whether the document is still the open one for its path.
    func watch(_ doc: EditorDocument, isCurrent: @escaping @MainActor (EditorDocument) -> Bool) {
        watchTokens += 1
        let token = watchTokens
        watched[doc.path] = token
        arm(doc, token: token, isCurrent: isCurrent)
    }

    func unwatch(_ path: String) {
        watched.removeValue(forKey: path)
        cancel(path)
    }

    func cancel(_ path: String) {
        timers.removeValue(forKey: path)?.task.cancel()
    }

    private func arm(_ doc: EditorDocument, token: Int, isCurrent: @escaping @MainActor (EditorDocument) -> Bool) {
        let buffer = doc.buffer
        withObservationTracking {
            _ = buffer.version
        } onChange: { [weak self, weak doc] in
            // Fires synchronously inside the mutation, which is always on the main actor.
            MainActor.assumeIsolated {
                guard let self, let doc, self.watched[doc.path] == token, isCurrent(doc) else { return }
                self.schedule(doc.path)
                // Re-arm once the mutation has finished (this callback runs before the new value is stored).
                Task { @MainActor [weak self, weak doc] in
                    guard let self, let doc, self.watched[doc.path] == token, isCurrent(doc) else { return }
                    doc.refreshTabDirty()
                    self.arm(doc, token: token, isCurrent: isCurrent)
                }
            }
        }
    }

    /// (Re)starts the timer for `path`.
    func schedule(_ path: String) {
        cancel(path)
        generation += 1
        let mine = generation
        let deadline = clock.now + Self.delay
        let clock = clock
        let task = Task { @MainActor [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let self, self.timers[path]?.generation == mine else { return }
            await self.save(path)
            if self.timers[path]?.generation == mine { self.timers.removeValue(forKey: path) }
        }
        timers[path] = (mine, task)
    }

    /// Waits for the timers that exist now (for tests: advance the clock first, or this waits for real time).
    func idle() async {
        let tasks = timers.values.map(\.task)
        for t in tasks { await t.value }
    }
}
