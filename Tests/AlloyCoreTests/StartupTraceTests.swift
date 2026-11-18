import Foundation
import Testing
@testable import AlloyCore

@Suite struct StartupTraceTests {
    final class Clock: @unchecked Sendable { var t = 0.0 }

    @Test func enabledRecordsInOrderWithNonDecreasingTimes() {
        let clock = Clock()
        let lines = LockedLines()
        let recorder = StartupTrace.Recorder(enabled: true, now: { clock.t += 1.5; return clock.t }) { lines.append($0) }
        for phase in ["a", "b", "c"] { recorder.mark(phase) }
        #expect(recorder.marks.map(\.phase) == ["a", "b", "c"])
        let times = recorder.marks.map(\.ms)
        #expect(times == times.sorted())
        #expect(lines.all == ["startup a 1.5", "startup b 3.0", "startup c 4.5"])
    }

    @Test func disabledRecordsNothing() {
        let lines = LockedLines()
        let recorder = StartupTrace.Recorder(enabled: false, now: { Issue.record("clock read while disabled"); return 0 }) { lines.append($0) }
        recorder.mark("a"); recorder.mark("b", at: 2)
        #expect(recorder.marks.isEmpty)
        #expect(lines.all.isEmpty)
    }

    @Test func processStartClockIsPositiveAndGrows() {
        let first = StartupTrace.now()
        let second = StartupTrace.now()
        #expect(first > 0)
        #expect(second >= first)
    }
}

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock(); private var lines: [String] = []
    func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
