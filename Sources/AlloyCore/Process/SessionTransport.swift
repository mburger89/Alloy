import Foundation

public enum ProcessEvent: Sendable, Equatable {
    case message(InboundMessage)
    case exited(status: Int32, stderrTail: String)
}

public protocol SessionTransport: Sendable {
    /// Starts the underlying session and returns its event stream. The stream ends after `.exited`.
    func start() async throws -> AsyncStream<ProcessEvent>
    func send(_ message: OutboundMessage) async throws
    /// SIGINT, then SIGTERM after 2 s if still running.
    func terminate() async
    /// SIGINT, then SIGTERM, then SIGKILL, all inside this awaited call; returns once the process has
    /// exited, or after about `timeout` at the latest. Safe to call on a process that is not running.
    func stopAndWait(timeout: Duration) async
}

extension SessionTransport {
    /// For transports with no process of their own.
    public func stopAndWait(timeout: Duration) async { await terminate() }
}
