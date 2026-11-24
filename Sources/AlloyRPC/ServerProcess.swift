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
public final class ServerProcess: RPCByteChannel, ServerExitObserving, @unchecked Sendable {
    public static let stderrLimit = 64 * 1024
    /// How long to wait for stdout/stderr EOF after the process ended (a grandchild may hold the pipes).
    private static let eofGrace: Duration = .seconds(2)

    public let incoming: AsyncStream<Data>

    /// Nil for a process-group launch (`posix_spawn`); see `spawnedPID`.
    private let process: Process?
    /// The leader's pid for a process-group launch; 0 otherwise.
    private var spawnedPID: Int32 = 0
    /// Set (under `lock`) once a process-group leader has been reaped.
    private var reaped = false
    /// The pgid when launched with `processGroup`, else nil.
    public let processGroupID: Int32?
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
    ///   - processGroup: launch as the leader of a new process group; `stop(grace:)` then signals the whole group.
    public convenience init(executable: String, arguments: [String], environment: [String: String],
                            currentDirectory: URL, processGroup: Bool = false) throws {
        guard let resolved = Self.resolve(executable, path: environment["PATH"]) else {
            throw ServerProcessError.notInstalled(command: executable)
        }
        if processGroup {
            try self.init(spawning: resolved, arguments: arguments, environment: environment,
                          currentDirectory: currentDirectory)
        } else {
            try self.init(launching: resolved, arguments: arguments, environment: environment,
                          currentDirectory: currentDirectory)
        }
    }

    private init(launching resolved: String, arguments: [String], environment: [String: String],
                 currentDirectory: URL) throws {
        processGroupID = nil
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

    /// The process-group launch: `posix_spawn` with its own group, pipes wired like the `Process` path.
    private init(spawning executable: String, arguments: [String], environment: [String: String],
                 currentDirectory: URL) throws {
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        let (incoming, incomingCont) = AsyncStream<Data>.makeStream()
        self.incoming = incoming
        self.process = nil
        self.stdin = inPipe.fileHandleForWriting

        #if os(macOS)
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        let childEnds: [(Int32, Int32)] = [
            (inPipe.fileHandleForReading.fileDescriptor, 0),
            (outPipe.fileHandleForWriting.fileDescriptor, 1),
            (errPipe.fileHandleForWriting.fileDescriptor, 2),
        ]
        for (fd, target) in childEnds { posix_spawn_file_actions_adddup2(&actions, fd, target) }
        let chdirResult = currentDirectory.path.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        var flags = Int32(POSIX_SPAWN_SETPGROUP)
        #if os(macOS)
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #else
        for h in [inPipe.fileHandleForReading, inPipe.fileHandleForWriting, outPipe.fileHandleForReading,
                  outPipe.fileHandleForWriting, errPipe.fileHandleForReading, errPipe.fileHandleForWriting] {
            _ = fcntl(h.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }
        var pid: pid_t = 0
        let rc = chdirResult == 0 ? posix_spawn(&pid, executable, &actions, &attributes, argv, envp) : chdirResult
        if rc != 0 {
            for h in [inPipe.fileHandleForReading, inPipe.fileHandleForWriting, outPipe.fileHandleForReading,
                      outPipe.fileHandleForWriting, errPipe.fileHandleForReading, errPipe.fileHandleForWriting] {
                try? h.close()
            }
            incomingCont.finish()
            processGroupID = nil
            throw ServerProcessError.launchFailed(String(cString: strerror(rc)))
        }
        spawnedPID = pid
        processGroupID = pid
        _ = fcntl(stdin.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? inPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

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
        // Strong on purpose: the owner lives until the leader has been reaped and its exit published.
        let owner = self
        let onExit: @Sendable (Int32) -> Void = { code in
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
        Self.reapLeader(pid) { code in
            owner.markReaped()
            onExit(code)
        }
    }

    private func markReaped() {
        lock.lock(); reaped = true; lock.unlock()
    }

    /// Waits for `pid` to exit, reaps it and reports the status (128 + signal when killed by a signal).
    private static func reapLeader(_ pid: pid_t, _ done: @escaping @Sendable (Int32) -> Void) {
        func status(_ raw: Int32) -> Int32 {
            let signal = raw & 0x7f
            return signal == 0 ? (raw >> 8) & 0xff : 128 + signal
        }
        #if os(macOS)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler {
            var raw: Int32 = 0
            waitpid(pid, &raw, 0)
            source.cancel()
            done(status(raw))
        }
        source.resume()
        #else
        let thread = Thread {
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1, errno == EINTR {}
            done(status(raw))
        }
        thread.start()
        #endif
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

    public var processIdentifier: Int32 { process?.processIdentifier ?? spawnedPID }
    public var isRunning: Bool {
        if let process { return process.isRunning }
        lock.lock(); defer { lock.unlock() }
        return !reaped
    }

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
        guard isRunning else { throw ServerProcessError.notRunning }
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
        guard isRunning else { return }
        if let group = processGroupID {
            kill(-group, SIGTERM)
            if await waitForExit(grace) {
                // The leader is gone; sweep any descendant that ignored SIGTERM.
                kill(-group, SIGKILL)
                return
            }
            kill(-group, SIGKILL)
            _ = await waitForExit(.seconds(2))
            return
        }
        let pid = processIdentifier
        kill(pid, SIGTERM)
        if await waitForExit(grace) { return }
        kill(pid, SIGKILL)
        _ = await waitForExit(.seconds(2))
    }

    private func waitForExit(_ limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while isRunning, clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return !isRunning
    }
}
