import AlloyCore
import Foundation

public enum ACPProcessError: Error, Equatable, CustomStringConvertible {
    case notInstalled(command: String)
    case launchFailed(String)
    case notRunning

    public var description: String {
        switch self {
        case .notInstalled(let c): "Agent not found: \(c)"
        case .launchFailed(let why): "Could not launch the agent: \(why)"
        case .notRunning: "The agent is not running."
        }
    }
}

/// An agent child process speaking ACP over stdin/stdout.
public final class ACPProcess: @unchecked Sendable {
    public static let stderrLimit = 64 * 1024
    private static let eofGrace: TimeInterval = 2

    /// Raw stdout chunks; finishes at EOF.
    public let stdout: AsyncStream<Data>

    private let process: Process
    private let stdin: FileHandle
    private let writeQueue = DispatchQueue(label: "alloy.acp.stdin")
    private let lock = NSLock()
    private var stderrBuffer = Data()
    private var exitCode: Int32?
    private var subscribers: [UUID: AsyncStream<Int32>.Continuation] = [:]
    private var stdinClosed = false  // touched only on writeQueue

    /// - Parameters:
    ///   - command: a path, or a bare command name searched on the merged PATH.
    ///   - environment: added over the current process environment (the caller keeps secrets out of logs).
    ///   - loginPATH: the login shell's PATH, merged in front of the existing one.
    public init(command: String, arguments: [String], environment: [String: String] = [:],
                currentDirectory: URL, loginPATH: String? = nil) throws {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        if let merged = ClaudeLocator.mergePATH(login: loginPATH, existing: env["PATH"]) { env["PATH"] = merged }
        guard let resolved = Self.resolve(command, path: env["PATH"]) else {
            throw ACPProcessError.notInstalled(command: command)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: resolved)
        p.arguments = arguments
        p.environment = env
        p.currentDirectoryURL = currentDirectory
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        let (stdout, outCont) = AsyncStream<Data>.makeStream()
        self.stdout = stdout
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
                outCont.finish()
                eof.leave()
            } else {
                outCont.yield(data)
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
                _ = eof.wait(timeout: .now() + Self.eofGrace)
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil
                outCont.finish()
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
            throw ACPProcessError.launchFailed(error.localizedDescription)
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

    /// The last 64 KiB of the agent's stderr.
    public var stderrTail: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrBuffer, as: UTF8.self)
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// Yields the exit status once (128 + signal when killed by a signal), then finishes. Every access returns an
    /// independent stream; a late subscriber still receives the status.
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

    /// Writes bytes to the agent's stdin.
    public func send(_ data: Data) async throws {
        guard process.isRunning else { throw ACPProcessError.notRunning }
        let handle = stdin
        let queue = writeQueue
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            queue.async {
                if self.stdinClosed { c.resume(throwing: ACPProcessError.notRunning); return }
                do { try handle.write(contentsOf: data); c.resume() }
                catch { c.resume(throwing: ACPProcessError.notRunning) }
            }
        }
    }

    /// Closes the agent's stdin (it sees EOF). Does not kill the process.
    public func closeStdin() async {
        let handle = stdin
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writeQueue.async {
                if !self.stdinClosed { self.stdinClosed = true; try? handle.close() }
                c.resume()
            }
        }
    }

    /// SIGINT, then SIGTERM, then SIGKILL, each given a third of `timeout`; returns once the process has ended.
    public func stopAndWait(timeout: Duration = .seconds(3)) async {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let step = timeout / 3
        for signal in [SIGINT, SIGTERM, SIGKILL] {
            guard process.isRunning else { return }
            kill(pid, signal)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: step)
            while process.isRunning, clock.now < deadline { try? await Task.sleep(for: .milliseconds(15)) }
            if !process.isRunning { return }
        }
    }
}
