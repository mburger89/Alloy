import Darwin
import Foundation
import BenchCore

public enum TraceStartResult: Equatable, Sendable {
    case recording
    case failed(String)
}

public enum TraceStopResult: Equatable, Sendable {
    case saved(String)
    case partial(String, String)
    case failed(String)
}

/// xctrace children that are still running, so the signal guard can kill them before the harness exits
/// (`exit` skips `deinit`). Holds Process objects, so a reused pid is never signalled.
public enum ActiveRecorders {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var children: [Process] = []
    static func add(_ p: Process) { lock.lock(); children.append(p); lock.unlock() }
    static func remove(_ p: Process) { lock.lock(); children.removeAll { $0 === p }; lock.unlock() }
    public static var count: Int { lock.lock(); defer { lock.unlock() }; return children.count }
    /// SIGKILLs every registered child that is still running (only those), then clears the registry.
    public static func killAll() {
        lock.lock(); let all = children; children = []; lock.unlock()
        for p in all where p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
}

/// Wraps `xcrun xctrace record --attach <pid>`. Every wait is bounded: a start timeout, then (after SIGINT) a stop
/// timeout followed by SIGKILL of the xctrace child only. Never signals anything but its own child.
public final class TraceRecorder: @unchecked Sendable {
    public static func arguments(kind: TraceKind, pid: pid_t, output: String) -> [String] {
        // Allocations needs macOS to authorize inspecting the app, which may prompt for a password; --no-prompt would hang it.
        ["xctrace", "record", "--template", kind.template, "--attach", "\(pid)", "--output", output]
            + (kind == .allocations ? [] : ["--no-prompt"])
    }

    /// Allocations gets time to type the password; everything else starts quickly.
    static func defaultStartTimeout(kind: TraceKind) -> Duration { kind == .allocations ? .seconds(120) : .seconds(15) }
    var effectiveStartTimeout: Duration { startTimeout }

    private let kind: TraceKind
    private let pid: pid_t
    private let output: String
    private let executable: String
    private let startTimeout: Duration
    private let stopTimeout: Duration

    private let lock = NSLock()
    private var process: Process?
    private var stdoutText = ""
    private var stderrText = ""

    public init(kind: TraceKind, pid: pid_t, output: String, executable: String = "/usr/bin/xcrun",
                startTimeout: Duration? = nil, stopTimeout: Duration = .seconds(30)) {
        self.kind = kind; self.pid = pid; self.output = output; self.executable = executable
        self.startTimeout = startTimeout ?? Self.defaultStartTimeout(kind: kind); self.stopTimeout = stopTimeout
    }

    deinit {
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        if let p = process { ActiveRecorders.remove(p) }
    }

    private func appended(stdout chunk: String? = nil, stderr errChunk: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let chunk { stdoutText += chunk }
        if let errChunk { stderrText += errChunk }
    }

    private func snapshot() -> (out: String, err: String) {
        lock.lock(); defer { lock.unlock() }
        return (stdoutText, stderrText)
    }

    private func setProcess(_ p: Process) { lock.lock(); process = p; lock.unlock() }
    private func currentProcess() -> Process? { lock.lock(); defer { lock.unlock() }; return process }

    private func firstLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    private static func ticks(_ d: Duration) -> Int {
        let c = d.components
        return max(1, Int((Double(c.seconds) + Double(c.attoseconds) / 1e18) * 1000 / 20))
    }

    private func killChild(_ p: Process) async {
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        for _ in 0..<100 where p.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        ActiveRecorders.remove(p)
    }

    /// xctrace prints `Starting recording` before it starts; this line means it really is recording.
    static let readyLine = "Ctrl-C to stop the recording"

    public func start() async -> TraceStartResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = Self.arguments(kind: kind, pid: pid, output: output)
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe; p.standardInput = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.appended(stdout: String(decoding: d, as: UTF8.self))
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.appended(stderr: String(decoding: d, as: UTF8.self))
        }
        do { try p.run() } catch { return .failed("could not start xctrace: \(error.localizedDescription)") }
        setProcess(p)
        ActiveRecorders.add(p)

        for _ in 0..<Self.ticks(startTimeout) {
            let s = snapshot()
            if (s.out + s.err).contains(Self.readyLine), p.isRunning { return .recording }
            if !p.isRunning {
                try? await Task.sleep(for: .milliseconds(50))  // let the pipe handlers drain
                let s = snapshot()
                let reason = firstLine(s.err) ?? firstLine(s.out) ?? "xctrace exited with status \(p.terminationStatus)"
                return .failed(reason)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let seen = snapshot()
        await killChild(p)
        if (seen.out + seen.err).contains("Starting recording") {
            let secs = Int(startTimeout.components.seconds)
            return .failed("xctrace did not start within \(secs) s; it is probably waiting for macOS to authorize inspecting the app (Allocations asks for your password once every 10 hours, and only from a Terminal you started yourself). See \"Allocations authorization\" in Bench/README.md")
        }
        return .failed("xctrace timed out after \(startTimeout) waiting for the recording to start")
    }

    public func stop() async -> TraceStopResult {
        guard let p = currentProcess() else { return .failed("recording was never started") }
        defer { ActiveRecorders.remove(p) }
        let exists = FileManager.default.fileExists(atPath: output)
        if !p.isRunning {
            return exists ? .partial(output, "xctrace exited before the run ended; the trace may be partial")
                          : .failed("xctrace exited before the run ended and wrote no trace")
        }
        p.interrupt()
        for _ in 0..<Self.ticks(stopTimeout) where p.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        if p.isRunning {
            await killChild(p)
            return .failed("xctrace did not stop within \(stopTimeout) after SIGINT and was killed")
        }
        let present = FileManager.default.fileExists(atPath: output)
        if p.terminationStatus == 0 { return present ? .saved(output) : .failed("xctrace finished but wrote no trace") }
        let why = firstLine(snapshot().err) ?? "xctrace exited with status \(p.terminationStatus)"
        return present ? .partial(output, why) : .failed(why)
    }
}
