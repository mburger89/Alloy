import AlloyCore
import Foundation

/// In-memory `SessionTransport` driven by tests.
public actor ScriptedTransport: SessionTransport {
    private let stream: AsyncStream<ProcessEvent>
    private let continuation: AsyncStream<ProcessEvent>.Continuation
    private var log: [OutboundMessage] = []
    public private(set) var terminated = false

    public init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    public func start() async throws -> AsyncStream<ProcessEvent> { stream }

    public func send(_ message: OutboundMessage) async throws { log.append(message) }

    public private(set) var stopAndWaitCalls = 0

    public func terminate() async {
        terminated = true
    }

    public func stopAndWait(timeout: Duration) async {
        stopAndWaitCalls += 1
        terminated = true
    }

    public func emit(_ message: InboundMessage) { continuation.yield(.message(message)) }

    public func emit(fixture lines: [Data]) {
        for line in lines { continuation.yield(.message(InboundDecoder.decode(line))) }
    }

    public func exit(status: Int32, stderr: String) {
        continuation.yield(.exited(status: status, stderrTail: stderr))
        continuation.finish()
    }

    public var sent: [OutboundMessage] { log }

    /// Everything sent except the `initialize` handshake that follows every start.
    public var sentAfterInitialize: [OutboundMessage] {
        log.filter { if case .control(_, .initialize) = $0 { return false } else { return true } }
    }
}
