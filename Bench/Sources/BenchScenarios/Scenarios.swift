import CoreGraphics
import Darwin
import Foundation
import BenchCore
import BenchDrivers

/// Strict collection for the display-capture metrics: any excluded run makes the whole outcome `.notMeasured`;
/// a median of survivors is never published.
func collectStrict(runs: Int, unit: String, notes: () -> [String], _ body: (Int) async throws -> Double) async -> Outcome {
    var samples: [Double] = []
    var failures: [String] = []
    let n = max(runs, 1)
    for i in 0..<n {
        do { samples.append(try await body(i)) } catch { failures.append("run \(i + 1): \(error)") }
    }
    if !failures.isEmpty {
        return .notMeasured("\(failures.count) of \(n) runs excluded (no median of survivors published): " + failures.joined(separator: "; "))
    }
    guard let s = Stats.summarize(samples, unit: unit) else { return .notMeasured("no samples") }
    return .measured(s, samples: samples, notes: notes(), failures: [])
}

/// Launch to the first frame in which the app's window region has painted non-blank content that differs from the
/// pre-launch baseline. Display capture runs before the launch (no capture-ready floor); the window is found by
/// polling CGWindowList every 5 ms. Warm unless `cold` (then `sudo -n purge` precedes each run).
public struct StartupScenario: Scenario {
    public var metric: Metric { .startup }
    public var cold: Bool
    public var windowTimeout: Duration
    public init(cold: Bool = false, windowTimeout: Duration = .seconds(30)) {
        self.cold = cold; self.windowTimeout = windowTimeout
    }
    public func run(_ app: TargetApp, corpus: Corpus, runs: Int) async -> Outcome {
        let windowMs = Box<[Double]>([])
        return await collectStrict(runs: runs, unit: "ms", notes: { windowOnScreenNote(windowMs.value) }) { _ in
            if cold, !Purge.run() { throw ScenarioFailure("purge needs sudo") }
            let r = try await Harness.measureOnDisplay(app, file: corpus.small, mode: .startup, timeout: windowTimeout)
            windowMs.update { $0.append(r.windowMs) }
            return r.hitMs
        }
    }
}

func windowOnScreenNote(_ v: [Double]) -> [String] {
    guard let s = Stats.summarize(v, unit: "ms") else { return [] }
    return [String(format: "window on screen: median %.0f ms after launch (CGWindowList, 5 ms polling)", s.median)]
}

/// Launch with large.rs; time until text rows cover >= 30 % of the app window's height (display capture
/// started before the launch).
public struct LargeFileOpenScenario: Scenario {
    public var metric: Metric { .largeFileOpen }
    public var windowTimeout: Duration
    public var paintTimeout: Duration
    public init(windowTimeout: Duration = .seconds(30), paintTimeout: Duration = .seconds(30)) {
        self.windowTimeout = windowTimeout; self.paintTimeout = paintTimeout
    }
    public func run(_ app: TargetApp, corpus: Corpus, runs: Int) async -> Outcome {
        let windowMs = Box<[Double]>([])
        return await collectStrict(runs: runs, unit: "ms", notes: { windowOnScreenNote(windowMs.value) }) { _ in
            let r = try await Harness.measureOnDisplay(app, file: corpus.large, mode: .textPainted, timeout: max(windowTimeout, paintTimeout))
            windowMs.update { $0.append(r.windowMs) }
            return r.hitMs
        }
    }
}

/// Types `keystrokes` letters `interval` apart into small.rs (caret at end); each sample is
/// post time to the first content-change frame.
public struct TypingLatencyScenario: Scenario {
    public var metric: Metric { .typingLatency }
    public var keystrokes: Int
    public var interval: Duration
    public var windowTimeout: Duration
    public init(keystrokes: Int = 200, interval: Duration = .milliseconds(150), windowTimeout: Duration = .seconds(30)) {
        self.keystrokes = keystrokes; self.interval = interval; self.windowTimeout = windowTimeout
    }
    public func run(_ app: TargetApp, corpus: Corpus, runs: Int) async -> Outcome {
        // One launch; the keystrokes are the samples (runs is not used).
        do {
            let r: (samples: [Double], total: Int, coveredBy: String?) = try await Harness.withApp(app, file: corpus.small, capture: .window, windowTimeout: windowTimeout) { p in
                _ = try await Harness.firstVisible(p, timeout: windowTimeout)
                await Input.activate(pid: p.launched.pid)
                if let click = app.typingClickPoint?(p.windowFrame) {
                    guard Harness.targetIsSafe(p, at: click) else {
                        throw ScenarioFailure("typing click point is not over \(app.displayName)'s window; refusing to click")
                    }
                    Input.click(at: click)
                    try await Task.sleep(for: .milliseconds(300))
                }
                Input.moveCaretToEnd(to: p.launched.pid)
                try await Task.sleep(for: .seconds(1))
                let changes = Box<[UInt64]>([])
                let prev = Box<CGImage?>(nil)
                await p.consume { f in
                    if let a = prev.value,
                       FrameDiff.isContentChange(FrameDiff.changedBounds(a, f.image, in: nil)) {
                        changes.update { $0.append(f.hostTime) }
                    }
                    prev.update { $0 = f.image }
                    return true
                }
                try await Task.sleep(for: .milliseconds(300))
                let letters = Array("etaoinshrdlcumwfgypbvk")
                var posts: [UInt64] = []
                for i in 0..<keystrokes {
                    posts.append(Input.typeKey(letters[i % letters.count], to: p.launched.pid))
                    try await Task.sleep(for: interval)
                }
                try await Task.sleep(for: .milliseconds(500))
                await p.finish()
                if p.droppedFrames > 0 { Notes.shared.add("capture buffer dropped \(p.droppedFrames) frames (bufferingNewest)") }
                let all = changes.value.sorted()
                var samples: [Double] = []
                for (i, post) in posts.enumerated() {
                    let limit = i + 1 < posts.count ? posts[i + 1] : post &+ 1_000_000_000
                    if let c = all.first(where: { $0 >= post && $0 < limit }) { samples.append(ms(c &- post)) }
                }
                return (samples, posts.count, samples.count * 2 < posts.count ? Harness.coveringAppName(launchedPid: p.launched.pid) : nil)
            }
            return Self.outcome(samples: r.samples, total: r.total, coveredBy: r.coveredBy).withNotes(Notes.shared.drain())
        } catch {
            _ = Notes.shared.drain()
            return .notMeasured("all runs failed: run 1: \(error)")
        }
    }

    /// Fewer than half of the keystrokes producing a frame change means the run is not trustworthy (the window
    /// was covered, unfocused or never repainted): no median is published.
    static func outcome(samples: [Double], total: Int, coveredBy: String?) -> Outcome {
        if samples.count * 2 < total {
            return .notMeasured("only \(samples.count) of \(total) keystrokes produced a frame change"
                                + (coveredBy.map { " (covered by \($0))" } ?? ""))
        }
        guard let s = Stats.summarize(samples, unit: "ms") else { return .notMeasured("no samples") }
        let missed = total - samples.count
        return .measured(s, samples: samples,
                         notes: missed > 0 ? ["\(missed) of \(total) keystrokes produced no frame change"] : [], failures: [])
    }
}

/// Posts 3-line scrolls every 8 ms at the app's scroll point (`TargetApp.scrollPoint`; window centre by default) for `duration` on large.rs; samples are
/// intervals between changed frames. Capture runs at the display's real refresh rate (recorded in the notes),
/// so intervals cannot be shorter than one capture period.
public struct ScrollFramesScenario: Scenario {
    public var metric: Metric { .scrollFrames }
    public var duration: Duration
    public var windowTimeout: Duration
    /// The safety guard (frontmost app, topmost window at the scroll point) runs at least every this many events.
    static let safetyCheckInterval = 2

    /// Intervals (ms) between consecutive changed frames, trimmed to the scrolling itself: frames before the first
    /// post or after the last post plus one refresh period are not part of the scroll.
    static func intervals(changeTimes: [UInt64], firstPost: UInt64, lastPost: UInt64, periodTicks: UInt64) -> [Double] {
        let t = changeTimes.sorted().filter { $0 >= firstPost && $0 <= lastPost &+ periodTicks }
        return zip(t, t.dropFirst()).map { ms($1 &- $0) }
    }

    /// Test hook, run right before the scroll loop.
    var beforeScroll: (@Sendable () async -> Void)?
    public init(duration: Duration = .seconds(3), windowTimeout: Duration = .seconds(30)) {
        self.duration = duration; self.windowTimeout = windowTimeout
    }
    public func run(_ app: TargetApp, corpus: Corpus, runs: Int) async -> Outcome {
        let hzBox = Box<Int>(0)
        let fallbackBox = Box<Bool>(false)
        let droppedBox = Box<Int>(0)
        return await collect(runs: runs, unit: "ms", extraNotes: { s in
            let hz = Double(max(hzBox.value, 1))
            let threshold = 1.5 * 1000 / hz
            let dropped = s.filter { $0 > threshold }.count
            var notes: [String] = droppedBox.value > 0
                ? ["capture buffer dropped \(droppedBox.value) frames (bufferingNewest); intervals around them are inflated"] : []
            notes += [String(format: "captured at %.0f Hz (\(fallbackBox.value ? "display refresh unknown; fallback 60 Hz" : "display refresh")); dropped frames: %.1f%% (%d of %d intervals > %.1f ms = 1.5x refresh period); intervals floor at %.1f ms; intervals trimmed to the first and last scroll post (+1 refresh period)",
                           hz, 100 * Double(dropped) / Double(max(s.count, 1)), dropped, s.count, threshold, 1000 / hz)]
            return notes
        }) { _ in
            try await Harness.withApp(app, file: corpus.large, capture: .window, windowTimeout: windowTimeout) { p in
                _ = try await Harness.firstVisible(p, timeout: windowTimeout)
                hzBox.update { $0 = 0 }
                let hz = await p.captureHz
                hzBox.update { $0 = hz }
                let fromDisplay = await p.captureHzFromDisplay
                fallbackBox.update { $0 = !fromDisplay }
                await Input.activate(pid: p.launched.pid)
                try await Task.sleep(for: .seconds(1))
                let times = Box<[UInt64]>([])
                let prev = Box<CGImage?>(nil)
                await p.consume { f in
                    if let a = prev.value, FrameDiff.isContentChange(FrameDiff.changedBounds(a, f.image, in: nil)) {
                        times.update { $0.append(f.hostTime) }
                    }
                    prev.update { $0 = f.image }
                    return true
                }
                await beforeScroll?()
                let end = ContinuousClock.now + duration
                var n = 0
                var firstPost: UInt64?, lastPost: UInt64 = 0
                while ContinuousClock.now < end {
                    if n % Self.safetyCheckInterval == 0, !Harness.targetIsSafe(p, at: p.scrollTarget) {
                        throw ScenarioFailure("target not frontmost/unobscured; aborted to avoid touching other apps")
                    }
                    lastPost = Input.scroll(lines: -3, to: p.launched.pid, at: p.scrollTarget)
                    if firstPost == nil { firstPost = lastPost }
                    n += 1
                    try await Task.sleep(for: .milliseconds(8))
                }
                try await Task.sleep(for: .milliseconds(200))
                await p.finish()
                droppedBox.update { $0 += p.droppedFrames }
                let period = DisplayScan.ticks(ms: 1000 / Double(max(hz, 1)))
                let iv = Self.intervals(changeTimes: times.value, firstPost: firstPost ?? 0, lastPost: lastPost, periodTicks: period)
                guard iv.count >= 1 else { throw ScenarioFailure("fewer than 2 changed frames while scrolling") }
                return iv
            }
        }
    }
}

/// Physical footprint (MiB) of the process tree `delay` after large.rs text is painted.
public struct MemoryScenario: Scenario {
    public var metric: Metric { .memory }
    public var delay: Duration
    public var windowTimeout: Duration
    public init(delay: Duration = .seconds(10), windowTimeout: Duration = .seconds(30)) {
        self.delay = delay; self.windowTimeout = windowTimeout
    }
    public func run(_ app: TargetApp, corpus: Corpus, runs: Int) async -> Outcome {
        await collect(runs: runs, unit: "MiB") { _ in
            let hit = Box<Harness.Hit>(Harness.Hit())
            return try await Harness.withApp(app, file: corpus.large, capture: .app(Harness.textPaintedHandler(hit)),
                                             windowTimeout: windowTimeout) { p in
                _ = try await Harness.await_(hit, timeout: windowTimeout, what: "text not painted")
                await p.finish()   // stop capturing before the settle wait; it is no longer needed
                try await Task.sleep(for: delay)
                let s = ProcessTree.sample(root: p.launched.pid)
                return [Double(s.physFootprintBytes) / 1_048_576]
            }
        }
    }
}

/// CPU % (of one core) over `window` after `settle` with small.rs open. The same launch also yields the
/// `memoryIdle` metric: the process-tree footprint (MiB) sampled at the end of the window.
public struct IdleCPUScenario: Scenario {
    public var metric: Metric { .idleCPU }
    public var settle: Duration
    public var window: Duration
    public var windowTimeout: Duration
    public init(settle: Duration = .seconds(10), window: Duration = .seconds(30), windowTimeout: Duration = .seconds(30)) {
        self.settle = settle; self.window = window; self.windowTimeout = windowTimeout
    }
    public func run(_ app: TargetApp, corpus: Corpus, runs: Int) async -> Outcome {
        await runBoth(app, corpus: corpus, runs: runs).cpu
    }

    /// One set of launches producing both the idle CPU and the idle memory outcome.
    public func runBoth(_ app: TargetApp, corpus: Corpus, runs: Int) async -> (cpu: Outcome, memory: Outcome) {
        let mem = Box<[Double]>([])
        let cpu = await collect(runs: runs, unit: "%") { _ in
            try await Harness.withApp(app, file: corpus.small, capture: .none, windowTimeout: windowTimeout) { p in
                try await Task.sleep(for: settle)
                // Wall time is stamped at each sample point (after the CPU counters were read).
                let a = ProcessTree.sample(root: p.launched.pid)
                let t0 = mach_absolute_time()
                try await Task.sleep(for: window)
                let b = ProcessTree.sample(root: p.launched.pid)
                let t1 = mach_absolute_time()
                mem.update { $0.append(Double(b.physFootprintBytes) / 1_048_576) }
                return [ProcessTree.cpuPercent(a, b, wallNanoseconds: UInt64(ms(t1 &- t0) * 1e6))]
            }
        }
        return (cpu, Self.memoryOutcome(cpu: cpu, samples: mem.value))
    }

    /// Idle-footprint outcome sharing the CPU run's failures; not measured when no run produced a footprint.
    static func memoryOutcome(cpu: Outcome, samples: [Double]) -> Outcome {
        guard let s = Stats.summarize(samples, unit: "MiB") else {
            if case .notMeasured(let why) = cpu { return .notMeasured(why) }
            return .notMeasured("no idle footprint sample")
        }
        var failures: [String] = []
        if case .measured(_, _, _, let f) = cpu { failures = f }
        return .measured(s, samples: samples, notes: ["footprint of the process tree at the end of the idle CPU window, small.rs open"],
                         failures: failures)
    }
}

/// Standalone `memoryIdle`; the runner shares one launch with `IdleCPUScenario` when both metrics are requested.
public struct MemoryIdleScenario: Scenario {
    public var metric: Metric { .memoryIdle }
    public var idle = IdleCPUScenario()
    public init() {}
    public func run(_ app: TargetApp, corpus: Corpus, runs: Int) async -> Outcome {
        await idle.runBoth(app, corpus: corpus, runs: runs).memory
    }
}

enum Purge {
    /// `sudo -n purge`; false when passwordless sudo is unavailable. Never prompts.
    static func run() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo"); p.arguments = ["-n", "purge"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// Side-channel for notes produced inside a run body (typing misses).
final class Notes: @unchecked Sendable {
    static let shared = Notes()
    private let lock = NSLock(); private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    func drain() -> [String] { lock.lock(); defer { lock.unlock() }; let r = items; items = []; return r }
}

extension Outcome {
    func withNotes(_ notes: [String]) -> Outcome {
        addingNotes(notes)
    }
}
