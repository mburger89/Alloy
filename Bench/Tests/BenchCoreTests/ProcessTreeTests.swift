import Testing
import Foundation
@testable import BenchCore

@Suite struct ProcessTreeTests {
    /// Spawns a child; returns the process and its stdout pipe.
    private func spawn(_ exe: String, _ args: [String]) throws -> (Process, Pipe) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        return (p, out)
    }

    private func kill(_ p: Process) {
        let pid = p.processIdentifier
        guard pid > 0 else { return }
        // Kill descendants first so grandchildren do not linger.
        for d in ProcessTree.descendants(of: pid) where d != pid { Foundation.kill(d, SIGKILL) }
        Foundation.kill(pid, SIGTERM)
        for _ in 0..<20 where p.isRunning { usleep(50_000) }
        if p.isRunning { Foundation.kill(pid, SIGKILL) }
    }

    private func waitForLine(_ pipe: Pipe, _ line: String) -> Bool {
        var buf = Data()
        let fd = pipe.fileHandleForReading
        while true {
            let chunk = fd.availableData
            if chunk.isEmpty { return false }
            buf.append(chunk)
            if String(decoding: buf, as: UTF8.self).contains(line) { return true }
        }
    }

    @Test func descendantsIncludesGrandchildren() throws {
        let (p, out) = try spawn("/bin/sh", ["-c", "/bin/sleep 30 & /bin/sleep 30 & echo ready; wait"])
        defer { kill(p) }
        #expect(waitForLine(out, "ready"))
        var found: [pid_t] = []
        for _ in 0..<40 {
            found = ProcessTree.descendants(of: p.processIdentifier)
            if found.count >= 3 { break }
            usleep(50_000)
        }
        #expect(found.contains(p.processIdentifier))
        #expect(found.count >= 3)
    }

    @Test func footprintGrowsWithAllocation() throws {
        let (p, out) = try spawn("/usr/bin/python3", ["-I", "-c",
            "b=bytearray(200*1024*1024)\nfor i in range(0,len(b),4096): b[i]=1\nprint('ready',flush=True)\nimport time; time.sleep(30)"])
        defer { kill(p) }
        #expect(waitForLine(out, "ready"))
        let s = ProcessTree.sample(root: p.processIdentifier)
        #expect(s.physFootprintBytes >= 150 * 1024 * 1024)
    }

    @Test func cpuPercentOfBusyChild() throws {
        let (p, out) = try spawn("/bin/sh", ["-c", "echo ready; while :; do :; done"])
        defer { kill(p) }
        #expect(waitForLine(out, "ready"))
        let t0 = DispatchTime.now().uptimeNanoseconds
        let a = ProcessTree.sample(root: p.processIdentifier)
        usleep(1_000_000)
        let b = ProcessTree.sample(root: p.processIdentifier)
        let wall = DispatchTime.now().uptimeNanoseconds - t0
        let pct = ProcessTree.cpuPercent(a, b, wallNanoseconds: wall)
        #expect(pct > 50 && pct < 150)
    }
}
