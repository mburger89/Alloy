import Testing
import Foundation
@testable import BenchCore
@testable import BenchDrivers

private struct Fake {
    let dir: String
    var script: String { dir + "/fake" }
    var pidFile: String { dir + "/pid" }
    var output: String { dir + "/out.trace" }
    init(_ body: String) throws {
        dir = NSTemporaryDirectory() + "trace-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let text = "#!/bin/bash\necho $$ > '\(dir)/pid'\nOUT='\(dir)/out.trace'\n" + body + "\n"
        try text.write(toFile: dir + "/fake", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/fake")
    }
    var childPID: pid_t? { (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    func cleanup() {
        if let p = childPID, kill(p, 0) == 0 { kill(p, SIGKILL) }
        try? FileManager.default.removeItem(atPath: dir)
    }
    func recorder(start: Duration = .seconds(2), stop: Duration = .seconds(2)) -> TraceRecorder {
        TraceRecorder(kind: .time, pid: 42, output: output, executable: script, startTimeout: start, stopTimeout: stop)
    }
}

private func gone(_ pid: pid_t?) async -> Bool {
    guard let pid else { return false }
    for _ in 0..<50 { if kill(pid, 0) != 0 { return true }; try? await Task.sleep(for: .milliseconds(20)) }
    return false
}

@Suite(.serialized) struct TraceRecorderTests {
    @Test func argumentsMatchXctrace() {
        #expect(TraceRecorder.arguments(kind: .allocations, pid: 42, output: "/home/tester/t.trace") ==
                ["xctrace", "record", "--template", "Allocations", "--attach", "42", "--output", "/home/tester/t.trace", "--no-prompt"])
    }

    @Test func templatesMatchDecision1() {
        let expected: [TraceKind: String] = [.time: "Time Profiler", .allocations: "Allocations", .hitches: "Animation Hitches",
                                             .gpu: "Metal System Trace", .concurrency: "Swift Concurrency"]
        #expect(TraceKind.allCases.count == expected.count)
        for k in TraceKind.allCases { #expect(k.template == expected[k]) }
    }

    @Test func startSucceedsWhenRecordingBegins() async throws {
        let f = try Fake("""
        trap 'mkdir -p "$OUT"; exit 0' INT
        echo "Starting recording with the Time Profiler template."
        echo "Ctrl-C to stop the recording"
        while true; do sleep 0.05; done
        """)
        defer { f.cleanup() }
        let r = f.recorder()
        #expect(await r.start() == .recording)
        #expect(await r.stop() == .saved(f.output))
        #expect(await gone(f.childPID))
    }

    @Test func startTimesOutAndKillsChild() async throws {
        let f = try Fake("exec sleep 600")
        defer { f.cleanup() }
        let r = f.recorder(start: .milliseconds(300))
        let res = await r.start()
        guard case .failed(let why) = res else { Issue.record("expected failure, got \(res)"); return }
        #expect(why.contains("timed out"))
        #expect(await gone(f.childPID))
    }

    @Test func startingLineAloneIsNotReadyAndGivesAuthorizationHint() async throws {
        let f = try Fake("echo 'Starting recording'\nexec sleep 600")
        defer { f.cleanup() }
        let res = await f.recorder(start: .seconds(1)).start()
        guard case .failed(let why) = res else { Issue.record("expected failure, got \(res)"); return }
        #expect(why == "xctrace did not start within 1 s; it is probably waiting for macOS to authorize inspecting the app (Allocations needs your password once every 10 hours). See \"Allocations authorization\" in Bench/README.md")
        #expect(await gone(f.childPID))
    }

    @Test func readyLineMeansRecording() async throws {
        let f = try Fake("echo 'Starting recording'\necho 'Ctrl-C to stop the recording'\nexec sleep 600")
        defer { f.cleanup() }
        #expect(await f.recorder().start() == .recording)
        ActiveRecorders.killAll()
        #expect(await gone(f.childPID))
    }

    @Test func startFailureCarriesFirstErrorLine() async throws {
        let f = try Fake("echo 'Cannot find process for provided pid: 42' >&2\necho 'second line' >&2\nexit 1")
        defer { f.cleanup() }
        #expect(await f.recorder().start() == .failed("Cannot find process for provided pid: 42"))
    }

    @Test func stopEscalatesWhenSigintIgnored() async throws {
        let f = try Fake("""
        trap '' INT
        echo "Starting recording"
        echo "Ctrl-C to stop the recording"
        while true; do sleep 0.05; done
        """)
        defer { f.cleanup() }
        let r = f.recorder(stop: .milliseconds(300))
        #expect(await r.start() == .recording)
        let res = await r.stop()
        guard case .failed(let why) = res else { Issue.record("expected failure, got \(res)"); return }
        #expect(why.contains("did not stop"))
        #expect(await gone(f.childPID))
    }

    @Test func stopAfterChildExitedIsPartial() async throws {
        let f = try Fake("echo 'Starting recording'\necho 'Ctrl-C to stop the recording'\nmkdir -p \"$OUT\"\nsleep 0.1\nexit 0")
        defer { f.cleanup() }
        let r = f.recorder()
        #expect(await r.start() == .recording)
        try await Task.sleep(for: .milliseconds(400))
        let t0 = ContinuousClock.now
        let res = await r.stop()
        #expect(ContinuousClock.now - t0 < .seconds(1))
        guard case .partial(let path, let why) = res else { Issue.record("expected partial, got \(res)"); return }
        #expect(path == f.output)
        #expect(why.contains("may be partial"))
    }

    @Test func killAllReapsRegisteredChild() async throws {
        let f = try Fake("echo 'Starting recording'\necho 'Ctrl-C to stop the recording'\nsleep 30")
        defer { f.cleanup() }
        let r = f.recorder()
        #expect(await r.start() == .recording)
        let pid = f.childPID
        #expect(pid != nil)
        ActiveRecorders.killAll()
        #expect(await gone(pid))
        #expect(ActiveRecorders.count == 0)
        _ = await r.stop()
    }

    @Test func droppedRecorderKillsItsChild() async throws {
        let f = try Fake("echo 'Starting recording'\necho 'Ctrl-C to stop the recording'\nsleep 30")
        defer { f.cleanup() }
        var r: TraceRecorder? = f.recorder()
        #expect(await r!.start() == .recording)
        let pid = f.childPID
        #expect(pid != nil)
        r = nil
        #expect(await gone(pid))
    }
}
