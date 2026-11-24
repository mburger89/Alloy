import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Reads a process's start time and resource use. The seam lets tests answer without a real process.
public protocol PluginProcessProbe: Sendable {
    /// Seconds since the epoch the process started (macOS) or a stable per-process figure (Linux); nil when gone.
    func startTime(pid: Int32) -> Double?
    func sample(pid: Int32) -> (residentBytes: UInt64, cpuSeconds: Double)?
    /// The pids that are members of process group `pgid` (empty when none, or when the platform cannot list them).
    func groupMembers(pgid: Int32) -> [Int32]
}

extension PluginProcessProbe {
    public func groupMembers(pgid: Int32) -> [Int32] { [] }
}

/// A flag one task sets and another polls.
final class PluginFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

public struct LiveProcessProbe: PluginProcessProbe {
    public init() {}

    #if os(macOS)
    public func startTime(pid: Int32) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    public func groupMembers(pgid: Int32) -> [Int32] {
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(bitPattern: pgid), nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size + 16)
        let got = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(bitPattern: pgid), &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return [] }
        return pids.prefix(Int(got) / MemoryLayout<Int32>.size).filter { $0 > 0 }
    }

    public func sample(pid: Int32) -> (residentBytes: UInt64, cpuSeconds: Double)? {
        var usage = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        let ticks = Double(usage.ri_user_time &+ usage.ri_system_time)
        return (usage.ri_resident_size, ticks * Double(base.numer) / Double(base.denom) / 1_000_000_000)
    }
    #elseif os(Linux)
    /// Fields after the parenthesised command name, starting at the state (field 3).
    private func fields(_ pid: Int32) -> [Substring]? {
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = text.lastIndex(of: ")") else { return nil }
        return text[text.index(after: close)...].split(separator: " ")
    }

    public func startTime(pid: Int32) -> Double? {
        guard let f = fields(pid), f.count > 19, let ticks = Double(f[19]) else { return nil }
        return ticks / Double(sysconf(Int32(_SC_CLK_TCK)))
    }

    public func sample(pid: Int32) -> (residentBytes: UInt64, cpuSeconds: Double)? {
        guard let f = fields(pid), f.count > 21, let u = Double(f[11]), let s = Double(f[12]), let pages = UInt64(f[21]) else { return nil }
        let hz = Double(sysconf(Int32(_SC_CLK_TCK)))
        return (pages * UInt64(sysconf(Int32(_SC_PAGESIZE))), (u + s) / hz)
    }
    #else
    public func startTime(pid: Int32) -> Double? { nil }
    public func sample(pid: Int32) -> (residentBytes: UInt64, cpuSeconds: Double)? { nil }
    #endif
}
