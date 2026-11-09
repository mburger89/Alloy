import AlloyCore
import Foundation
import Testing

private func fakeScript() -> String {
    Bundle.module.url(forResource: "fake-claude", withExtension: "sh", subdirectory: "Fixtures")!.path
}

private func fixturePath(_ name: String) -> String {
    Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!.path
}

private func makeFake(env: [String: String]) -> ClaudeProcess {
    let cfg = LaunchConfiguration(executable: URL(fileURLWithPath: "/bin/sh"),
                                  projectDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                                  sessionID: UUID(), resume: false)
    return ClaudeProcess(configuration: cfg, environment: env, argumentsPrefix: [fakeScript()])
}

/// Wraps the stream iterator; `next()` returns nil on stream end or after 10 s (a hang fails, not blocks).
/// Calls are strictly sequential within a test, hence @unchecked Sendable.
private final class Reader: @unchecked Sendable {
    private var it: AsyncStream<ProcessEvent>.Iterator
    init(_ stream: AsyncStream<ProcessEvent>) { it = stream.makeAsyncIterator() }
    private func pull() async -> ProcessEvent? { await it.next() }
    func next() async -> ProcessEvent? {
        await withTaskGroup(of: ProcessEvent??.self) { group in
            group.addTask { .some(await self.pull()) }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return .some(nil) }
            let r = await group.next()!
            group.cancelAll()
            return r ?? nil
        }
    }
}

@Suite struct ClaudeProcessTests {
    @Test func streamsDecodedLinesInOrder() async throws {
        let proc = makeFake(env: ["FAKE_FIXTURE": fixturePath("edit-turn")])
        let expected = Fixture.lines("edit-turn").map { InboundDecoder.decode($0) }
        let it = Reader(try await proc.start())
        #expect(await it.next() == .message(.unknown(type: "argv")))
        for (i, want) in expected.enumerated() {
            let got = await it.next()
            #expect(got == .message(want), "line \(i)")
        }
        await proc.terminate()
    }

    @Test func sendWritesOneLine() async throws {
        let proc = makeFake(env: [:])
        let it = Reader(try await proc.start())
        _ = await it.next()
        try await proc.send(.user(text: "hi", uuid: UUID(), priority: nil))
        #expect(await it.next() == .message(.unknown(type: "echo")))
        await proc.terminate()
        // Drains to .exited, then the stream ends.
        var rest: [ProcessEvent] = []
        while let e = await it.next() { rest.append(e) }
        #expect(rest.count == 1, "no second echo before .exited: \(rest)")
        if case .exited = rest.last {} else { Issue.record("expected exited, got \(String(describing: rest.last))") }
        await #expect(throws: ClaudeProcessError.notRunning) {
            try await proc.send(.user(text: "late", uuid: UUID(), priority: nil))
        }
    }

    @Test func handlesNineMegabyteLine() async throws {
        let proc = makeFake(env: ["FAKE_BIG": "1"])
        let it = Reader(try await proc.start())
        _ = await it.next()
        let first = await it.next()
        guard case .message(.assistantBlock(_, .text(let t))) = first else {
            Issue.record("got \(String(describing: first))"); return
        }
        #expect(t.utf8.count == 9_000_000)
        await proc.terminate()
    }

    @Test func exitReportsStatusAndStderrTail() async throws {
        let cfg = LaunchConfiguration(executable: URL(fileURLWithPath: "/bin/sh"),
                                      projectDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                                      sessionID: UUID(), resume: false)
        let proc = ClaudeProcess(configuration: cfg, environment: [:],
                                 argumentsPrefix: ["-c", "echo boom >&2; exit 3", "sh"])
        let it = Reader(try await proc.start())
        var last: ProcessEvent?
        while let e = await it.next() { last = e }
        #expect(last == .exited(status: 3, stderrTail: "boom\n"))
    }

    @Test func stderrTailKeepsLast4096Bytes() async throws {
        let cfg = LaunchConfiguration(executable: URL(fileURLWithPath: "/bin/sh"),
                                      projectDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                                      sessionID: UUID(), resume: false)
        let script = "head -c 3000 /dev/zero | tr '\\0' a >&2; head -c 3000 /dev/zero | tr '\\0' b >&2; exit 1"
        let proc = ClaudeProcess(configuration: cfg, environment: ["PATH": "/usr/bin:/bin"],
                                 argumentsPrefix: ["-c", script, "sh"])
        let it = Reader(try await proc.start())
        var last: ProcessEvent?
        while let e = await it.next() { last = e }
        let expected = String(repeating: "a", count: 1096) + String(repeating: "b", count: 3000)
        #expect(last == .exited(status: 1, stderrTail: expected))
    }

    @Test func exitedArrivesEvenWhenGrandchildHoldsPipes() async throws {
        let proc = makeFake(env: ["FAKE_GRANDCHILD": "1"])
        let it = Reader(try await proc.start())
        _ = await it.next() // argv
        var grandchild: pid_t = 0
        if case .message(.unknown(let type)) = await it.next(), type.hasPrefix("pid-") {
            grandchild = pid_t(type.dropFirst(4)) ?? 0
        } else { Issue.record("no pid line") }
        defer { if grandchild > 0 { kill(grandchild, SIGKILL) } }
        let clock = ContinuousClock()
        let start = clock.now
        let last = await it.next()
        let elapsed = clock.now - start
        #expect(last == .exited(status: 0, stderrTail: ""))
        #expect(elapsed < .seconds(5), "elapsed \(elapsed)")
        #expect(await it.next() == nil)
    }

    @Test func sigtermEscalationWhenSigintIgnored() async throws {
        let proc = makeFake(env: ["FAKE_TRAPINT": "1"])
        let it = Reader(try await proc.start())
        _ = await it.next() // argv: trap is installed before it is printed
        let clock = ContinuousClock()
        let start = clock.now
        await proc.terminate()
        var last: ProcessEvent?
        while let e = await it.next() { last = e }
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(5), "elapsed \(elapsed)")
        guard case .exited(let status, _) = last else { Issue.record("got \(String(describing: last))"); return }
        #expect(status == 143)
    }

    @Test func fastExitDeliversExitedPromptly() async throws {
        let cfg = LaunchConfiguration(executable: URL(fileURLWithPath: "/bin/sh"),
                                      projectDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                                      sessionID: UUID(), resume: false)
        let proc = ClaudeProcess(configuration: cfg, environment: [:],
                                 argumentsPrefix: ["-c", "exit 3", "sh"])
        let clock = ContinuousClock()
        let start = clock.now
        let it = Reader(try await proc.start())
        var last: ProcessEvent?
        while let e = await it.next() { last = e }
        let elapsed = clock.now - start
        #expect(last == .exited(status: 3, stderrTail: ""))
        #expect(elapsed < .seconds(1), "elapsed \(elapsed)")
    }

    @Test func stopAndWaitReturnsOnlyAfterExit() async throws {
        let proc = makeFake(env: [:])
        let it = Reader(try await proc.start())
        _ = await it.next()
        await proc.stopAndWait(timeout: .seconds(3))
        #expect(await proc.isRunning == false)
        var last: ProcessEvent?
        while let e = await it.next() { last = e }
        guard case .exited = last else { Issue.record("got \(String(describing: last))"); return }
    }

    @Test func stopAndWaitEscalatesPastIgnoredSigint() async throws {
        let proc = makeFake(env: ["FAKE_TRAPINT": "1"])
        let it = Reader(try await proc.start())
        _ = await it.next() // the trap is installed before argv is printed
        await proc.stopAndWait(timeout: .seconds(3))
        #expect(await proc.isRunning == false)
        var last: ProcessEvent?
        while let e = await it.next() { last = e }
        guard case .exited(let status, _) = last else { Issue.record("got \(String(describing: last))"); return }
        #expect(status == 143)
    }

    @Test func stopAndWaitEscalatesToSigkill() async throws {
        let proc = makeFake(env: ["FAKE_TRAPINT": "1", "FAKE_TRAPTERM": "1"])
        let it = Reader(try await proc.start())
        _ = await it.next()
        let clock = ContinuousClock()
        let start = clock.now
        await proc.stopAndWait(timeout: .seconds(3))
        let elapsed = clock.now - start
        #expect(await proc.isRunning == false)
        #expect(elapsed < .seconds(4), "elapsed \(elapsed)")
        var last: ProcessEvent?
        while let e = await it.next() { last = e }
        guard case .exited(let status, _) = last else { Issue.record("got \(String(describing: last))"); return }
        #expect(status == 137)
    }

    @Test func stopAndWaitOnAnExitedProcessReturnsAtOnce() async throws {
        let proc = makeFake(env: [:])
        await proc.stopAndWait(timeout: .seconds(3)) // never started
        let it = Reader(try await proc.start())
        _ = await it.next()
        await proc.stopAndWait(timeout: .seconds(3))
        await proc.stopAndWait(timeout: .seconds(3))
        #expect(await proc.isRunning == false)
    }
}

@Suite struct LaunchArgumentTests {
    private func config(resume: Bool = true) -> LaunchConfiguration {
        LaunchConfiguration(executable: URL(fileURLWithPath: "/bin/claude"), projectDirectory: URL(fileURLWithPath: "/tmp"),
                            sessionID: UUID(), resume: resume, resumeID: "src",
                            appendSystemPrompt: "G",
                            allowedTools: ["mcp__alloy__notes_lookup", "mcp__alloy__notes_read", "mcp__alloy__notes_write"],
                            forkSession: true)
    }

    @Test func launchArgumentsCarryForkPromptAndAllowedTools() {
        let args = config().arguments()
        func has(_ run: [String]) -> Bool { args.indices.contains { args[$0...].starts(with: run) } }
        #expect(has(["--resume", "src", "--fork-session"]))
        #expect(has(["--append-system-prompt", "G", "--system-prompt-snapshot", "off"]))
        #expect(has(["--allowedTools", "mcp__alloy__notes_lookup,mcp__alloy__notes_read,mcp__alloy__notes_write"]))
        #expect(!args.contains("--permission-mode") && !args.contains("--setting-sources"))
    }

    @Test func forkPointIsPassedOnlyToAForkLaunch() {
        var c = config()
        c.resumeSessionAt = "6e4d18ff-4b16-40da-b5e2-832293e680d8"
        let args = c.arguments()
        let i = args.firstIndex(of: "--resume-session-at")
        #expect(i != nil && args[(i ?? 0) + 1] == "6e4d18ff-4b16-40da-b5e2-832293e680d8")
        c.forkSession = false
        #expect(!c.arguments().contains("--resume-session-at"))
        #expect(!config().arguments().contains("--resume-session-at"))
    }

    @Test func defaultsAddNoNewFlags() {
        let args = LaunchConfiguration(executable: URL(fileURLWithPath: "/bin/claude"), projectDirectory: URL(fileURLWithPath: "/tmp"),
                                       sessionID: UUID(), resume: false).arguments()
        for flag in ["--fork-session", "--append-system-prompt", "--system-prompt-snapshot", "--allowedTools"] {
            #expect(!args.contains(flag))
        }
    }
}
