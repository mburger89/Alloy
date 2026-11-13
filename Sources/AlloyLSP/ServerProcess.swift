import Foundation

public enum ServerProcessError: Error, Equatable, CustomStringConvertible {
    case notInstalled(command: String)
    case launchFailed(String)
    case notRunning

    public var description: String {
        switch self {
        case .notInstalled(let c): "Language server not found: \(c)"
        case .launchFailed(let why): "Could not launch language server: \(why)"
        case .notRunning: "The language server is not running."
        }
    }
}

/// What `LanguageServer` needs from a launched server besides its byte channel.
public protocol ServerExitObserving: Sendable {
    /// Yields the exit status once the process has ended (128 + signal when killed by a signal), then finishes.
    /// Every access returns an independent stream; a late subscriber still receives the status.
    var exited: AsyncStream<Int32> { get }
    /// The tail of the server's stderr (last 64 KiB).
    var stderrTail: String { get }
    /// SIGTERM, then SIGKILL after `grace`. Returns once the process has ended (or could not be ended).
    func stop(grace: Duration) async
}

extension ServerExitObserving {
    public var stderrTail: String { "" }
    public func stop(grace: Duration) async {}
}

/// A language server child process speaking over stdin/stdout.
public final class ServerProcess: LSPByteChannel, ServerExitObserving, @unchecked Sendable {
    public static let stderrLimit = 64 * 1024
    /// How long to wait for stdout/stderr EOF after the process ended (a grandchild may hold the pipes).
    private static let eofGrace: Duration = .seconds(2)

    public let incoming: AsyncStream<Data>

    private let process: Process
    private let stdin: FileHandle
    private let writeQueue = DispatchQueue(label: "alloy.lsp.stdin")
    private let lock = NSLock()
    private var stderrBuffer = Data()
    private var exitCode: Int32?
    private var subscribers: [UUID: AsyncStream<Int32>.Continuation] = [:]
    private var stdinClosed = false  // touched only on writeQueue

    /// - Parameters:
    ///   - executable: a path, or a bare command name searched on `environment["PATH"]`.
    ///   - environment: the child's environment (the caller merges the login-shell PATH in).
    ///   - currentDirectory: the workspace root.
    public init(executable: String, arguments: [String], environment: [String: String], currentDirectory: URL) throws {
        guard let resolved = Self.resolve(executable, path: environment["PATH"]) else {
            throw ServerProcessError.notInstalled(command: executable)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: resolved)
        p.arguments = arguments
        p.environment = environment
        p.currentDirectoryURL = currentDirectory
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        let (incoming, incomingCont) = AsyncStream<Data>.makeStream()
        self.incoming = incoming
        self.process = p
        self.stdin = inPipe.fileHandleForWriting

        let eof = DispatchGroup()
        eof.enter(); eof.enter()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        outHandle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                incomingCont.finish()
                eof.leave()
            } else {
                incomingCont.yield(data)
            }
        }
        errHandle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                eof.leave()
            } else {
                self?.appendStderr(data)
            }
        }
        p.terminationHandler = { [weak self] proc in
            guard let owner = self else { return }
            let code = proc.terminationReason == .uncaughtSignal ? 128 + proc.terminationStatus : proc.terminationStatus
            // Publish only after the pipes drained (or the grace passed), so the last output is not lost.
            DispatchQueue.global().async {
                _ = eof.wait(timeout: .now() + 2)
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil
                incomingCont.finish()
                try? outHandle.close()
                try? errHandle.close()
                owner.publishExit(code)
            }
        }
        do { try p.run() } catch {
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            for h in [inPipe.fileHandleForReading, inPipe.fileHandleForWriting, outHandle,
                      outPipe.fileHandleForWriting, errHandle, errPipe.fileHandleForWriting] {
                try? h.close()
            }
            throw ServerProcessError.launchFailed(error.localizedDescription)
        }
        _ = fcntl(stdin.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? inPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
    }

    private static func resolve(_ command: String, path: String?) -> String? {
        let fm = FileManager.default
        if command.contains("/") { return fm.isExecutableFile(atPath: command) ? command : nil }
        for dir in (path ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(command)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func appendStderr(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        stderrBuffer.append(data)
        if stderrBuffer.count > Self.stderrLimit { stderrBuffer = Data(stderrBuffer.suffix(Self.stderrLimit)) }
    }

    private func publishExit(_ code: Int32) {
        lock.lock()
        exitCode = code
        let subs = subscribers
        subscribers = [:]
        lock.unlock()
        for (_, c) in subs { c.yield(code); c.finish() }
    }

    public var stderrTail: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrBuffer, as: UTF8.self)
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public var exited: AsyncStream<Int32> {
        let (stream, cont) = AsyncStream<Int32>.makeStream()
        lock.lock()
        if let code = exitCode {
            lock.unlock()
            cont.yield(code); cont.finish()
        } else {
            subscribers[UUID()] = cont
            lock.unlock()
        }
        return stream
    }

    public func send(_ data: Data) async throws {
        guard process.isRunning else { throw ServerProcessError.notRunning }
        let handle = stdin
        let queue = writeQueue
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            queue.async {
                if self.stdinClosed { c.resume(throwing: ServerProcessError.notRunning); return }
                do { try handle.write(contentsOf: data); c.resume() }
                catch { c.resume(throwing: ServerProcessError.notRunning) }
            }
        }
    }

    /// Closes the server's stdin (the server sees EOF). Does not kill the process; see `stop(grace:)`.
    public func close() async {
        let handle = stdin
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writeQueue.async {
                if !self.stdinClosed { self.stdinClosed = true; try? handle.close() }
                c.resume()
            }
        }
    }

    public func stop(grace: Duration) async {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, SIGTERM)
        if await waitForExit(grace) { return }
        kill(pid, SIGKILL)
        _ = await waitForExit(.seconds(2))
    }

    private func waitForExit(_ limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while process.isRunning, clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return !process.isRunning
    }
}
