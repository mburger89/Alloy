import AlloyCore
import Foundation

/// An `AutosaveClock` tests advance by hand. `sleep(until:)` suspends until `advance` reaches the deadline, and
/// a cancelled sleeper leaves at once, so `pendingSleepers` counts only live timers.
public final class ManualClock: AutosaveClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time = 0.0
    private var nextID = 0
    private var cancelled: Set<Int> = []
    private var waiters: [Int: (deadline: Double, continuation: CheckedContinuation<Void, Error>)] = [:]

    public init() {}

    public var now: Double { lock.withLock { time } }
    public var pendingSleepers: Int { lock.withLock { waiters.count } }

    public func sleep(until deadline: Double) async throws {
        let id = lock.withLock { () -> Int in nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                enum Action { case wait, resume, cancel }
                let action = lock.withLock { () -> Action in
                    if cancelled.remove(id) != nil { return .cancel }
                    if time >= deadline { return .resume }
                    waiters[id] = (deadline, c); return .wait
                }
                switch action {
                case .wait: break
                case .resume: c.resume()
                case .cancel: c.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                if let w = waiters.removeValue(forKey: id) { return w.continuation }
                cancelled.insert(id); return nil
            }
            c?.resume(throwing: CancellationError())
        }
    }

    public func advance(by seconds: Double) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            time += seconds
            let ready = waiters.filter { $0.value.deadline <= time }
            for key in ready.keys { waiters.removeValue(forKey: key) }
            return ready.values.map(\.continuation)
        }
        for c in due { c.resume() }
    }
}

/// Collects the transports a workspace's `makeTransport` creates, in order.
public final class ScriptedTransports: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScriptedTransport] = []
    public init() {}
    public func make() -> ScriptedTransport {
        let t = ScriptedTransport()
        lock.withLock { items.append(t) }
        return t
    }
    public var all: [ScriptedTransport] { lock.withLock { items } }
}
