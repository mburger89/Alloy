import Foundation

/// The outcome of one git run. `status` is -1 when git is unusable, failed to launch, or was abandoned after SIGKILL; a SIGTERMed git reports its
/// signal number. Rely on `timedOut` to detect a kill.
public struct GitResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data(), timedOut: Bool = false) {
        self.status = status; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
    }
}

public enum GitProcess {
    /// stderr is kept up to this many bytes.
    static let stderrCap = 64 * 1024

    /// Runs git in `root`. The wait does not occupy a thread of the cooperative pool: output is read by readability
    /// handlers and the exit arrives through the termination handler. A hung git gets SIGTERM after `terminateAfter`
    /// seconds and SIGKILL after `killAfter`, when the run also gives up whatever the process does; only the process
    /// started here is ever signalled. Read runs set `GIT_OPTIONAL_LOCKS=0`; write runs leave it unset.
    public static func run(_ args: [String], in root: URL, stdin: Data? = nil, readOnly: Bool,
                           terminateAfter: Double = 10, killAfter: Double = 12) async -> GitResult {
        guard case .usable(let path, _) = GitExecutable.current else { return GitResult(status: -1) }
        return await withCheckedContinuation { (continuation: CheckedContinuation<GitResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.currentDirectoryURL = root
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_LITERAL_PATHSPECS"] = "1"
            if readOnly { env["GIT_OPTIONAL_LOCKS"] = "0" } else { env.removeValue(forKey: "GIT_OPTIONAL_LOCKS") }
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let inPipe: Pipe? = stdin == nil ? nil : Pipe()
            process.standardInput = inPipe ?? FileHandle.nullDevice
            if let inPipe { _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
            let run = GitRun(continuation)
            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; run.outputEnded() } else { run.appendOut(chunk) }
            }
            err.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; run.errorEnded() } else { run.appendErr(chunk) }
            }
            process.terminationHandler = { run.exited($0.terminationStatus) }
            do { try process.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                try? inPipe?.fileHandleForWriting.close()
                run.fail()
                return
            }
            if let inPipe, let stdin {
                // Off the caller's thread: a large write blocks until git reads it.
                DispatchQueue.global().async {
                    try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                    try? inPipe.fileHandleForWriting.close()
                }
            }
            let box = ProcessBox(process)
            DispatchQueue.global().asyncAfter(deadline: .now() + terminateAfter) { if box.terminateIfRunning() { run.markTimedOut() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + killAfter) { if box.killIfRunning() { run.markTimedOut() }; run.fail() }
        }
    }
}

/// The state of one git run: output so far, whether it ended, how the process exited; resumes once.
private final class GitRun: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var outEnded = false
    private var errEnded = false
    private var status: Int32?
    private var timedOut = false
    private var done = false
    private let continuation: CheckedContinuation<GitResult, Never>

    init(_ c: CheckedContinuation<GitResult, Never>) { continuation = c }

    func appendOut(_ chunk: Data) { lock.withLock { out.append(chunk) } }
    func appendErr(_ chunk: Data) {
        lock.withLock {
            let room = GitProcess.stderrCap - err.count
            if room > 0 { err.append(chunk.prefix(room)) }
        }
    }
    func outputEnded() { lock.withLock { outEnded = true }; finishIfReady() }
    func errorEnded() { lock.withLock { errEnded = true }; finishIfReady() }
    func markTimedOut() { lock.withLock { timedOut = true } }
    func exited(_ code: Int32) {
        lock.withLock { status = code }
        finishIfReady()
        // A grandchild holding a pipe open must not hold the result back.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            lock.withLock { outEnded = true; errEnded = true }
            finishIfReady()
        }
    }
    func fail() { resume(nil) }

    private func finishIfReady() {
        let ready: Bool = lock.withLock { outEnded && errEnded && status != nil && !done }
        if ready { resume(status) }
    }

    private func resume(_ code: Int32?) {
        let result: GitResult? = lock.withLock {
            guard !done else { return nil }
            done = true
            return GitResult(status: code ?? -1, stdout: out, stderr: err, timedOut: timedOut)
        }
        if let result { continuation.resume(returning: result) }
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    init(_ p: Process) { process = p }
    /// True when the process was still running.
    func terminateIfRunning() -> Bool { if process.isRunning { process.terminate(); return true }; return false }
    func killIfRunning() -> Bool { if process.isRunning { kill(process.processIdentifier, SIGKILL); return true }; return false }
}
