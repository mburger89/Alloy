import Foundation

public enum ClaudeProcessError: Error, Equatable, CustomStringConvertible {
    case alreadyStarted
    case notRunning
    case launchFailed(String)

    public var description: String {
        switch self {
        case .alreadyStarted: "The claude process was already started."
        case .notRunning: "The claude process is not running."
        case .launchFailed(let why): "Could not launch claude: \(why)"
        }
    }
}

/// Splits a byte stream into lines on "\n". Lines of any length; partial chunks are buffered.
struct LineSplitter {
    private var buffer = Data()
    private var scanned = 0

    mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        var start = 0
        var i = scanned
        while let nl = buffer[(buffer.startIndex + i)...].firstIndex(of: 0x0A) {
            let end = nl - buffer.startIndex
            lines.append(Data(buffer[(buffer.startIndex + start)..<nl]))
            start = end + 1
            i = start
        }
        if start > 0 { buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + start)) }
        scanned = buffer.count
        return lines
    }

    /// The unterminated remainder at EOF, if any.
    mutating func finish() -> Data? {
        defer { buffer = Data(); scanned = 0 }
        return buffer.isEmpty ? nil : buffer
    }
}

/// Runs the user's `claude` and exposes its stream-json stdout as `ProcessEvent`s.
public actor ClaudeProcess: SessionTransport {
    /// Maximum time to wait for stdout/stderr EOF after the process has terminated
    /// (a grandchild may have inherited the pipes).
    private static let eofGrace: Duration = .seconds(2)

    private let configuration: LaunchConfiguration
    private let environment: [String: String]
    private let argumentsPrefix: [String]
    private var process: Process?
    private var stdin: FileHandle?
    private let writeQueue = DispatchQueue(label: "alloy.claude.stdin")
    private var started = false
    private var exited = false

    private static let stderrTailLimit = 4096

    /// - Parameter argumentsPrefix: Arguments placed before `configuration.arguments()`.
    ///   For tests and wrappers (e.g. executable `/bin/sh` with the script path as prefix).
    public init(configuration: LaunchConfiguration,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                argumentsPrefix: [String] = []) {
        self.configuration = configuration
        self.environment = environment
        self.argumentsPrefix = argumentsPrefix
    }

    /// Decodes a line unless it is empty or whitespace-only.
    private static func event(for line: Data) -> ProcessEvent? {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D && $0 != 0x0A }) else { return nil }
        return .message(InboundDecoder.decode(line))
    }

    /// The `.exited` status is the exit code, or `128 + signal` when the process died from a signal
    /// (the shell convention, e.g. 143 for SIGTERM).
    public func start() async throws -> AsyncStream<ProcessEvent> {
        guard !started else { throw ClaudeProcessError.alreadyStarted }
        started = true

        let p = Process()
        p.executableURL = configuration.executable
        p.arguments = argumentsPrefix + configuration.arguments()
        p.currentDirectoryURL = configuration.projectDirectory
        var env = environment
        if let merged = ClaudeLocator.mergePATH(login: configuration.loginPATH, existing: environment["PATH"]) {
            env["PATH"] = merged
        }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let outChunks = Self.chunks(from: outHandle)
        let errChunks = Self.chunks(from: errHandle)
        let (statusStream, statusCont) = AsyncStream<Int32>.makeStream()
        p.terminationHandler = { proc in
            let code = proc.terminationReason == .uncaughtSignal
                ? 128 + proc.terminationStatus : proc.terminationStatus
            statusCont.yield(code)
            statusCont.finish()
        }

        do { try p.run() } catch {
            started = false
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            for h in [inPipe.fileHandleForReading, inPipe.fileHandleForWriting, outHandle,
                      outPipe.fileHandleForWriting, errHandle, errPipe.fileHandleForWriting] {
                try? h.close()
            }
            throw ClaudeProcessError.launchFailed(error.localizedDescription)
        }
        process = p
        let writer = inPipe.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        stdin = writer
        // Close our copies of the child's ends.
        try? inPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        let (events, continuation) = AsyncStream<ProcessEvent>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.terminate() }
        }

        let outTask = Task {
            var splitter = LineSplitter()
            for await chunk in outChunks {
                for line in splitter.append(chunk) {
                    if let e = Self.event(for: line) { continuation.yield(e) }
                }
            }
            if let rest = splitter.finish(), let e = Self.event(for: rest) { continuation.yield(e) }
        }
        let errTask = Task { () -> Data in
            var tail = Data()
            for await chunk in errChunks {
                tail.append(chunk)
                if tail.count > Self.stderrTailLimit { tail = tail.suffix(Self.stderrTailLimit) }
            }
            return Data(tail)
        }
        Task {
            var status: Int32 = -1
            for await s in statusStream { status = s }
            // Wait for EOF, but only briefly: a grandchild may hold the pipes open.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = await outTask.value; _ = await errTask.value }
                group.addTask { try? await Task.sleep(for: Self.eofGrace) }
                await group.next()
                group.cancelAll() // also cancels the grace sleep when the readers finished first
                // Cancelling ends the AsyncStream iteration, flushing any partial line.
                outTask.cancel()
                errTask.cancel()
                await group.next()
            }
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            try? outHandle.close()
            try? errHandle.close()
            let tail = await errTask.value
            self.markExited()
            continuation.yield(.exited(status: status, stderrTail: String(decoding: tail, as: UTF8.self)))
            continuation.finish()
        }
        return events
    }

    private func markExited() {
        exited = true
        if let h = stdin {
            // Close on the write queue so it cannot race an in-flight write.
            writeQueue.async { try? h.close() }
        }
        stdin = nil
    }

    public func send(_ message: OutboundMessage) async throws {
        guard let handle = stdin, !exited, process?.isRunning == true else { throw ClaudeProcessError.notRunning }
        var line = message.line()
        if line.last != 0x0A { line.append(0x0A) }
        let payload = line
        let queue = writeQueue
        // The blocking write happens off the actor so terminate() and markExited() stay responsive.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            queue.async {
                do { try handle.write(contentsOf: payload); c.resume() }
                catch { c.resume(throwing: ClaudeProcessError.notRunning) }
            }
        }
    }

    /// SIGINT to the child this actor launched, then SIGTERM after 2 s if it is still running.
    public func terminate() async {
        guard let p = process, !exited, p.isRunning else { return }
        let pid = p.processIdentifier
        kill(pid, SIGINT)
        Task { [weak p] in
            try? await Task.sleep(for: .seconds(2))
            if let p, p.isRunning, p.processIdentifier == pid { kill(pid, SIGTERM) }
        }
    }

    /// Whether the launched child is still running.
    public var isRunning: Bool { process?.isRunning == true && !exited }

    /// SIGINT, then SIGTERM, then SIGKILL, each given a third of `timeout` to end the child. Unlike
    /// `terminate()` the escalation happens inside this call, so a quitting app can await it.
    public func stopAndWait(timeout: Duration = .seconds(3)) async {
        guard let p = process, p.isRunning else { return }
        let pid = p.processIdentifier
        let step = timeout / 3
        for signal in [SIGINT, SIGTERM, SIGKILL] {
            guard p.isRunning else { return }
            kill(pid, signal)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: step)
            while p.isRunning, clock.now < deadline { try? await Task.sleep(for: .milliseconds(15)) }
            if !p.isRunning { return }
        }
    }

    /// Non-empty chunks as they arrive; finishes at EOF.
    private static func chunks(from handle: FileHandle) -> AsyncStream<Data> {
        let (stream, cont) = AsyncStream<Data>.makeStream()
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                cont.finish()
            } else {
                cont.yield(data)
            }
        }
        return stream
    }
}
