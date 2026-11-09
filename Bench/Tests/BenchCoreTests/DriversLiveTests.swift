import Testing
import Foundation
import CoreGraphics
@testable import BenchCore
@testable import BenchDrivers
@testable import BenchScenarios

private let live = ProcessInfo.processInfo.environment["BENCH_LIVE"] == "1"

private func ms(_ ticks: UInt64) -> Double {
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    return Double(ticks) * Double(tb.numer) / Double(tb.denom) / 1e6
}

extension LiveTests {
@Suite(.serialized, .enabled(if: live)) struct DriversLiveTests {
    @Test func launchFindsWindowAndCaptures() async throws {
        let missing = Permissions.missing()
        try #require(missing.isEmpty, "not run: missing \(missing)")
        let count = try await withLaunched(fixtureApp(), file: "animate") { app in
            let w = try await Windows.waitForMainWindow(pid: app.pid, timeout: .seconds(10))
            let cap = WindowCapture(windowID: w.windowID, fps: 60)
            try await cap.start()
            let stream = await cap.frames()
            let task = Task { () -> Int in
                var n = 0
                for await f in stream where !FrameDiff.isBlank(f.image) { n += 1 }
                return n
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { await cap.stop(); throw error }
            await cap.stop()
            return await task.value
        }
        #expect(count >= 10)
    }

    @Test func typingChangesFrame() async throws {
        let missing = Permissions.missing()
        try #require(missing.isEmpty, "not run: missing \(missing)")
        let latency = try await withLaunched(fixtureApp(), file: "static") { app -> Double? in
            let w = try await Windows.waitForMainWindow(pid: app.pid, timeout: .seconds(10))
            await Input.activate(pid: app.pid)
            let cap = WindowCapture(windowID: w.windowID, fps: 60)
            try await cap.start()
            let stream = await cap.frames()
            do { try await Task.sleep(for: .seconds(1)) } catch { await cap.stop(); throw error }
            // Frames buffered since capture start include a startup change (title-bar activation, ~67x21 px);
            // only changes at or after the key post count.
            let mark = Box<UInt64>(.max)
            let result = Task { () -> UInt64? in
                var last: CGImage?
                for await f in stream {
                    if let l = last, f.hostTime >= mark.value,
                       FrameDiff.isContentChange(FrameDiff.changedBounds(l, f.image, in: nil)) {
                        return f.hostTime
                    }
                    last = f.image
                }
                return nil
            }
            let watchdog = Task { try await Task.sleep(for: .milliseconds(1500)); await cap.stop() }
            mark.update { $0 = mach_absolute_time() }
            let posted = Input.typeKey("x", to: app.pid)
            let changedAt = await result.value
            watchdog.cancel(); await cap.stop()
            guard let changedAt, changedAt >= posted else { return nil }
            return ms(changedAt - posted)
        }
        let l = try #require(latency, "no content-change frame arrived")
        #expect(l < 500, "typing-to-frame latency \(l) ms")
    }

    @Test func timeoutWhenNoWindow() async throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["60"]
        try p.run()
        defer { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            _ = try await Windows.waitForMainWindow(pid: p.processIdentifier, timeout: .seconds(2))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func terminateOnlyOwnTree() async throws {
        let bystander = Process(); bystander.executableURL = URL(fileURLWithPath: "/bin/sleep"); bystander.arguments = ["60"]
        try bystander.run()
        defer { kill(bystander.processIdentifier, SIGKILL); bystander.waitUntilExit() }
        let l = try Launcher.launch(fixtureApp(), file: "static")
        do { try await Task.sleep(for: .seconds(1)) } catch { await Launcher.terminate(l); throw error }
        await Launcher.terminate(l)
        #expect(ProcessTree.descendants(of: l.pid).filter { kill($0, 0) == 0 }.isEmpty)
        #expect(bystander.isRunning)
    }
}
}

@Suite struct PermissionsTests {
    @Test func missingReturnsKnownNames() {
        for m in Permissions.missing() { #expect(m.hasPrefix("Screen Recording") || m.hasPrefix("Accessibility")) }
    }
}

@Suite struct LauncherStartTimeTests {
    @Test func startTimeGuardsPidReuse() async throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["60"]
        try p.run()
        defer { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
        let pid = p.processIdentifier
        let st = try #require(Launcher.startTime(of: pid))
        let real = LaunchedApp(pid: pid, launchedAt: 0, startTime: st)
        let stale = LaunchedApp(pid: pid, launchedAt: 0, startTime: st &+ 1_000_000)
        #expect(Launcher.isStillLaunched(real))
        #expect(!Launcher.isStillLaunched(stale))
        await Launcher.terminate(stale)      // mismatched start time: must not signal
        #expect(p.isRunning)
        await Launcher.terminate(real)       // matching: terminated
        #expect(!Launcher.isStillLaunched(real))
    }
}
