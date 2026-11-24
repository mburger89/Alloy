import Foundation

/// Opt-in startup phase trace. With `ALLOY_STARTUP_TRACE=1` every `mark` writes `startup <phase> <ms>` to standard
/// error, `ms` being wall-clock milliseconds since the kernel started the process. Unset, a mark is one cached
/// Bool check: no formatting, no clock, no syscall.
public enum StartupTrace {
    /// Read once, on the first mark.
    public static let isEnabled: Bool = getenv("ALLOY_STARTUP_TRACE").map { String(cString: $0) == "1" } ?? false
    private static let shared = Recorder(enabled: isEnabled, now: Recorder.millisecondsSinceProcessStart) { line in
        fputs(line + "\n", stderr)
    }

    /// Records `phase` now. Call sites pass a literal.
    @inline(__always)
    public static func mark(_ phase: StaticString) {
        guard isEnabled else { return }
        shared.mark("\(phase)")
    }

    /// Records `phase` at `ms` (milliseconds since process start), for a time measured elsewhere.
    public static func mark(_ phase: StaticString, atMilliseconds ms: Double) {
        guard isEnabled else { return }
        shared.mark("\(phase)", at: ms)
    }

    /// Milliseconds since the process started (kernel start time), or 0 when the kernel does not say.
    public static func now() -> Double { Recorder.millisecondsSinceProcessStart() }

    /// The recording engine, separate so a test can drive it with its own clock and sink.
    public final class Recorder: @unchecked Sendable {
        public struct Mark: Equatable, Sendable { public var phase: String; public var ms: Double }
        private let enabled: Bool
        private let now: @Sendable () -> Double
        private let sink: @Sendable (String) -> Void
        private let lock = NSLock()
        private var stored: [Mark] = []

        public init(enabled: Bool, now: @escaping @Sendable () -> Double, sink: @escaping @Sendable (String) -> Void) {
            self.enabled = enabled; self.now = now; self.sink = sink
        }

        public var marks: [Mark] { lock.lock(); defer { lock.unlock() }; return stored }

        public func mark(_ phase: String) {
            guard enabled else { return }
            mark(phase, at: now())
        }

        public func mark(_ phase: String, at ms: Double) {
            guard enabled else { return }
            lock.lock(); stored.append(Mark(phase: phase, ms: ms)); lock.unlock()
            sink("startup \(phase) \(String(format: "%.1f", ms))")
        }

        /// Wall clock minus `kp_proc.p_starttime` of this process.
        public static func millisecondsSinceProcessStart() -> Double {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
            guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return 0 }
            let start = info.kp_proc.p_un.__p_starttime
            var tv = timeval()
            gettimeofday(&tv, nil)
            let startMs = Double(start.tv_sec) * 1000 + Double(start.tv_usec) / 1000
            let nowMs = Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
            return nowMs - startMs
        }
    }
}
