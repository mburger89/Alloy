import Darwin
import Foundation

public struct TreeSample: Sendable, Equatable {
    public var pids: [pid_t]
    public var physFootprintBytes: UInt64
    public var cpuNanoseconds: UInt64
    public init(pids: [pid_t], physFootprintBytes: UInt64, cpuNanoseconds: UInt64) {
        self.pids = pids; self.physFootprintBytes = physFootprintBytes; self.cpuNanoseconds = cpuNanoseconds
    }
}

public enum ProcessTree {
    private static func directChildren(of pid: pid_t) -> [pid_t] {
        var capacity = 64
        while true {
            var buf = [pid_t](repeating: 0, count: capacity)
            // Returns the number of pids written (not bytes), despite the buffer being sized in bytes.
            let count = proc_listchildpids(pid, &buf, Int32(capacity * MemoryLayout<pid_t>.size))
            if count <= 0 { return [] }
            let n = Int(count)
            if n < capacity { return Array(buf[0..<n].filter { $0 > 0 }) }
            capacity *= 4
        }
    }

    /// The root plus all transitive children (proc_listchildpids is direct-only).
    public static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = [pid]
        var seen: Set<pid_t> = [pid]
        var queue: [pid_t] = [pid]
        while !queue.isEmpty {
            let cur = queue.removeFirst()
            for c in directChildren(of: cur) where seen.insert(c).inserted {
                result.append(c); queue.append(c)
            }
        }
        return result
    }

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    public static func sample(root pid: pid_t) -> TreeSample {
        let pids = descendants(of: pid)
        var footprint: UInt64 = 0
        var ticks: UInt64 = 0
        for p in pids {
            var info = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(p, RUSAGE_INFO_V4, $0)
                }
            }
            if rc != 0 { continue }  // exited between listing and sampling
            footprint += info.ri_phys_footprint
            ticks += info.ri_user_time &+ info.ri_system_time
        }
        let tb = timebase
        let ns = tb.denom == 0 ? ticks : UInt64(Double(ticks) * Double(tb.numer) / Double(tb.denom))
        return TreeSample(pids: pids, physFootprintBytes: footprint, cpuNanoseconds: ns)
    }

    /// CPU use over the window as a percentage of one core (100 = one core fully busy).
    public static func cpuPercent(_ a: TreeSample, _ b: TreeSample, wallNanoseconds: UInt64) -> Double {
        guard wallNanoseconds > 0, b.cpuNanoseconds >= a.cpuNanoseconds else { return 0 }
        return Double(b.cpuNanoseconds - a.cpuNanoseconds) / Double(wallNanoseconds) * 100
    }
}
