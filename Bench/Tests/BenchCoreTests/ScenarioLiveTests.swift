import Testing
import Foundation
@testable import BenchCore
@testable import BenchDrivers
@testable import BenchScenarios

private let live = ProcessInfo.processInfo.environment["BENCH_LIVE"] == "1"

private func requireMeasured(_ o: Outcome, _ metric: String) throws -> Summary {
    guard case .measured(let s, _, let notes, let failures) = o else {
        Issue.record("\(metric): expected measured, got \(o)"); throw CancellationError()
    }
    print("LIVE \(metric): count=\(s.count) median=\(s.median) p95=\(s.p95) min=\(s.min) max=\(s.max) \(s.unit) failures=\(failures) notes=\(notes)")
    #expect(s.count > 0)
    return s
}

/// Runs each scenario against the AppKit fixture app (never against Zed or Delta).
extension LiveTests {
@Suite(.serialized, .enabled(if: live)) struct ScenarioLiveTests {
    private func gate() throws {
        let missing = Permissions.missing()
        try #require(missing.isEmpty, "not run: missing \(missing)")
    }

    /// No delay: the fixture paints ~150 ms after launch, around when an app-scoped capture would be ready.
    /// Pre-launch display capture has no such floor, so this must be measurable.
    @Test func startupOnUndelayedFixture() async throws {
        try gate()
        let o = await StartupScenario().run(fixtureApp(), corpus: .default, runs: 5)
        let s = try requireMeasured(o, "startup(undelayed)")
        #expect(s.count == 5 && s.median > 1 && s.max < 1_000)
    }

    @Test func startupOnDelayedFixture() async throws {
        try gate()
        let o = await StartupScenario().run(fixtureApp(extra: ["delay=700"]), corpus: .default, runs: 2)
        let s = try requireMeasured(o, "startup(delay 700)")
        #expect(s.median > 700 && s.median < 3_000)
    }

    /// Median "window on screen" ms parsed from the outcome's note.
    private func windowOnScreen(_ o: Outcome) -> Double? {
        guard case .measured(_, _, let notes, _) = o else { return nil }
        for n in notes where n.hasPrefix("window on screen: median ") {
            return Double(n.dropFirst("window on screen: median ".count).prefix { $0.isNumber || $0 == "." })
        }
        return nil
    }

    /// The window is up at once but only paints its content 400 ms later: the measurement must not fire on the blank window.
    @Test func startupOnBlankThenPaintFixture() async throws {
        try gate()
        let o = await StartupScenario().run(fixtureApp(extra: ["blankThenPaint=400"]), corpus: .default, runs: 3)
        let s = try requireMeasured(o, "startup(blankThenPaint 400)")
        let w = try #require(windowOnScreen(o))
        print("LIVE startup(blankThenPaint 400): window on screen \(w) ms, painted median \(s.median) ms, min \(s.min)")
        #expect(s.min >= w + 350 - 40, "fired on the blank window")   // 40 ms: CGWindowList detection lags the compositor
    }

    @Test func largeFileOpenOnBlankThenPaintFixture() async throws {
        try gate()
        let o = await LargeFileOpenScenario().run(fixtureApp(extra: ["blankThenPaint=400"]), corpus: .default, runs: 3)
        let s = try requireMeasured(o, "largeFileOpen(blankThenPaint 400)")
        let w = try #require(windowOnScreen(o))
        print("LIVE largeFileOpen(blankThenPaint 400): window on screen \(w) ms, painted median \(s.median) ms, min \(s.min)")
        #expect(s.min >= w + 350 - 40, "fired on the blank window")
    }

    @Test func memoryOnFixture() async throws {
        try gate()
        let o = await MemoryScenario(delay: .seconds(1)).run(fixtureApp(), corpus: .default, runs: 1)
        let s = try requireMeasured(o, "memory")
        #expect(s.median > 1 && s.median < 2_000)
    }

    @Test func idleCPUOnFixture() async throws {
        try gate()
        let o = await IdleCPUScenario(settle: .seconds(1), window: .seconds(3))
            .run(fixtureApp(), corpus: .default, runs: 1)
        let s = try requireMeasured(o, "idleCPU")
        #expect(s.median >= 0 && s.median < 100)
    }

    @Test func typingLatencyOnFixture() async throws {
        try gate()
        let o = await TypingLatencyScenario(keystrokes: 20).run(fixtureApp(), corpus: .default, runs: 1)
        let s = try requireMeasured(o, "typingLatency")
        #expect(s.median > 0 && s.median < 1_000)
    }

    @Test func largeFileOpenOnUndelayedFixture() async throws {
        try gate()
        let o = await LargeFileOpenScenario().run(fixtureApp(), corpus: .default, runs: 3)
        let s = try requireMeasured(o, "largeFileOpen(undelayed)")
        #expect(s.count == 3 && s.max < 2_000)
    }

    @Test func largeFileOpenOnDelayedFixture() async throws {
        try gate()
        let o = await LargeFileOpenScenario().run(fixtureApp(extra: ["delay=700"]), corpus: .default, runs: 1)
        let s = try requireMeasured(o, "largeFileOpen(delay 700)")
        #expect(s.median > 700 && s.median < 3_000)
    }

    @Test func scrollFramesOnFixture() async throws {
        try gate()
        let o = await ScrollFramesScenario(duration: .seconds(2)).run(fixtureApp(), corpus: .default, runs: 1)
        let s = try requireMeasured(o, "scrollFrames")
        #expect(s.median > 0 && s.median < 1_000)
    }

    /// Evidence for the application-scoped capture: everything except the app's windows is transparent,
    /// so the opaque bounds of a frame match the app window rather than the whole display.
    @Test func appCaptureIsTransparentOutsideTheWindow() async throws {
        try gate()
        let last = Box<FrameDiff.AppFrame?>(nil)
        let size = Box<(Int, Int)>((0, 0))
        let (w, h) = try await Harness.withApp(fixtureApp(), file: Corpus.default.small,
            capture: .app({ f in
                size.update { $0 = (f.image.width, f.image.height) }
                let a = FrameDiff.analyzeAppFrame(f.image)
                if a.bounds != nil { last.update { $0 = a } }
                return true
            }), windowTimeout: .seconds(10)) { p in
            try await Task.sleep(for: .seconds(1))
            return (p.windowFrame.width, p.windowFrame.height)
        }
        let a = try #require(last.value?.bounds)
        print("LIVE appCapture: frame \(size.value) opaque bounds \(a) window \(w)x\(h) pt")
        #expect(abs(Double(a.width) - w) < 20 && abs(Double(a.height) - h) < 20)
        #expect(a.width < size.value.0 / 2)
    }

    @Test func scrollAbortsWhenAnotherWindowCoversTarget() async throws {
        try gate()
        let countFile = NSTemporaryDirectory() + "cover-\(getpid()).count"
        let cover = fixtureApp(extra: ["count=" + countFile])
        let covering = Box<LaunchedApp?>(nil)
        var sc = ScrollFramesScenario(duration: .seconds(2))
        sc.beforeScroll = {
            guard let l = try? Launcher.launch(cover, file: nil) else { return }
            ActiveLaunches.add(l); covering.update { $0 = l }
            _ = try? await Windows.waitForMainWindow(pid: l.pid, timeout: .seconds(10))
            await Input.activate(pid: l.pid)
        }
        let o = await sc.run(fixtureApp(), corpus: .default, runs: 1)
        await ActiveLaunches.terminateAll()
        let count = (try? String(contentsOfFile: countFile, encoding: .utf8)) ?? "missing"
        print("LIVE coverAbort: outcome \(o); covering window scroll events: \(count)")
        guard case .notMeasured(let why) = o else { Issue.record("expected abort, got \(o)"); return }
        #expect(why.contains("not frontmost/unobscured"))
        #expect(count == "0")
        try? FileManager.default.removeItem(atPath: countFile)
    }

    @Test func terminateAllKillsRegisteredLaunches() async throws {
        let l = try Launcher.launch(fixtureApp(), file: nil)
        ActiveLaunches.add(l)
        try await Task.sleep(for: .milliseconds(500))
        #expect(Launcher.isStillLaunched(l))
        await ActiveLaunches.terminateAll()
        #expect(!Launcher.isStillLaunched(l))
        #expect(ActiveLaunches.current.isEmpty)
    }

    @Test func noWindowTimesOutAsFailedSample() async throws {
        // /bin/sleep never shows a window: the run must fail with a reason and leave nothing running.
        let sleeper = TargetApp(id: "sleeper", displayName: "Sleeper", bundlePath: nil,
                                executablePath: "/bin/sleep", launchArguments: { _ in ["61.37"] })
        let t0 = ContinuousClock.now
        let o = await StartupScenario(windowTimeout: .seconds(2)).run(sleeper, corpus: .default, runs: 1)
        #expect(ContinuousClock.now - t0 < .seconds(15))
        guard case .notMeasured(let why) = o else { Issue.record("expected notMeasured, got \(o)"); return }
        #expect(why.contains("window"))
        let pg = Process(); pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); pg.arguments = ["-f", "sleep 61.37"]
        pg.standardOutput = FileHandle.nullDevice
        try pg.run(); pg.waitUntilExit()
        #expect(pg.terminationStatus == 1, "launched sleeper still running")
    }
}
}
