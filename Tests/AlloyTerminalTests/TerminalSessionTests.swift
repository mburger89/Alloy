#if !os(Windows)

@testable import AlloyTerminal
import AlloyTestSupport
import Foundation
import MetalUITerminal
import Testing

private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func update(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
}

private func settle(_ condition: @escaping @Sendable () -> Bool, seconds: Double = 10) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

private let size = TerminalSize(cols: 80, rows: 24)

private func text(_ session: TerminalSession) async -> [String] {
    await session.withEmulator { e in
        (e.firstRow..<(e.firstRow + 60)).compactMap { e.rowText($0) }
    }
}

struct TerminalSessionTests {
    private func make(_ pty: ScriptedPty = ScriptedPty()) -> (TerminalSession, ScriptedPty) {
        (TerminalSession(paneID: UUID(), pty: pty, size: size, scrollback: 1000), pty)
    }

    @Test func outputReachesTheEmulatorInOrder() async {
        let (session, pty) = make()
        session.start(.init())
        let bytes = Array("hello\r\nworld".utf8)
        pty.feed(Array(bytes[0..<3]))
        pty.feed(Array(bytes[3..<8]))
        pty.feed(Array(bytes[8...]))
        #expect(await settle { session.outputVersion >= 1 })
        var got = await text(session)
        for _ in 0..<200 where !got.contains("world") {
            try? await Task.sleep(nanoseconds: 5_000_000)
            got = await text(session)
        }
        #expect(got.contains("hello"))
        #expect(got.contains("world"))
        #expect(session.outputVersion >= 1)
    }

    @Test func snapshotSourceIsStable() {
        let (session, _) = make()
        // swiftlint:disable:next identical_operands - deliberate: two reads of the property must return the same object
        #expect(session.snapshotSource === session.snapshotSource)
    }

    @Test func resizeThroughTheSourceReachesThePtyOnce() async {
        let (session, pty) = make()
        session.start(.init())
        session.snapshotSource.resize(TerminalSize(cols: 100, rows: 30))
        session.resize(cols: 100, rows: 30)
        #expect(await settle { pty.resizes.last == TerminalSize(cols: 100, rows: 30) })
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(pty.resizes == [TerminalSize(cols: 100, rows: 30)])
    }

    @Test func titleAndDirectoryArriveCoalescedFromTheSource() async {
        let (session, pty) = make()
        let titles = Box<[String]>([])
        let dirs = Box<[String]>([])
        session.start(.init(onTitle: { t in titles.update { $0.append(t) } },
                            onWorkingDirectory: { d in dirs.update { $0.append(d) } }))
        pty.feed(Array("\u{1b}]7;file:///tmp\u{1b}\\".utf8))
        pty.feed(Array(String(repeating: "\u{1b}]0;vim\u{07}", count: 1000).utf8))
        #expect(await settle { titles.get().last == "vim" && dirs.get().last == "/tmp" })
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(titles.get().count <= 3)
        #expect(dirs.get().count <= 3)
    }

    @Test func replyEventsAreWrittenBackToThePty() async {
        let (session, pty) = make()
        session.start(.init())
        pty.feed([0x1b, 0x5b, 0x35, 0x6e])
        pty.feed([0x1b, 0x5b, 0x63])
        let reference = TerminalEmulator(cols: 80, rows: 24)
        let expected: [UInt8] = {
            var out: [UInt8] = []
            for chunk in [[UInt8]([0x1b, 0x5b, 0x35, 0x6e]), [0x1b, 0x5b, 0x63]] {
                chunk.withUnsafeBytes { reference.feed($0) }
                for case .reply(let b) in reference.drainEvents() { out += b }
            }
            return out
        }()
        let count = expected.count
        #expect(!expected.isEmpty)
        #expect(await settle { pty.written.count >= count })
        #expect(pty.written == expected)
    }

    @Test func wakeupReadsAtMost64KiBPerReadAnd1MiBPerWakeup() async {
        let (session, pty) = make()
        let perWakeup = Box<[Int]>([])
        let last = Box(0)
        session.onOutput = {
            let n = pty.readCalls.count
            perWakeup.update { $0.append(n - last.get()) }
            last.update { $0 = n }
        }
        session.start(.init())
        let total = 3 * 1024 * 1024
        pty.feed([UInt8](repeating: 0x61, count: total) + Array("\r\nEND".utf8))
        #expect(await settle { session.outputVersion >= 3 && pty.readCalls.count >= 49 })
        #expect(pty.readCalls.allSatisfy { $0 == 65_536 })
        // 16 reads of 64 KiB make 1 MiB; a final wakeup may add one empty read.
        let counts = perWakeup.get()
        #expect(counts.count >= 3)
        #expect(counts.allSatisfy { $0 <= 17 }, "reads per wakeup: \(counts)")
        var found = false
        for _ in 0..<400 where !found {
            found = await session.withEmulator { e in
                (e.firstRow..<(e.firstRow + 2000)).contains { e.rowText($0) == "END" }
            }
            if !found { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        #expect(found)
    }

    @Test func twoSessionsInterleaveOnTheSharedQueue() async {
        let (a, ptyA) = make()
        let (b, ptyB) = make()
        let mib = 1024 * 1024
        let order = Box<[String]>([])
        a.onOutput = { order.update { $0.append("a") } }
        b.onOutput = { order.update { $0.append("b") } }
        ptyA.feed([UInt8](repeating: 0x61, count: 3 * mib))
        ptyB.feed([UInt8](repeating: 0x62, count: 3 * mib))
        a.start(.init())
        b.start(.init())
        #expect(await settle { ptyA.readCalls.count >= 48 && ptyB.readCalls.count >= 48 })
        #expect(await settle { a.outputVersion >= 3 && b.outputVersion >= 3 })
        let seq = order.get()
        let firstB = seq.firstIndex(of: "b")
        let thirdA = seq.indices.filter { seq[$0] == "a" }.dropFirst(2).first
        #expect(firstB != nil && thirdA != nil)
        if let firstB, let thirdA { #expect(firstB < thirdA, "order: \(seq)") }
        // Neither session finishes before the other has had a wakeup.
        let lastA = seq.lastIndex(of: "a") ?? 0, lastB = seq.lastIndex(of: "b") ?? 0
        #expect((seq.firstIndex(of: "a") ?? 0) < lastB)
        #expect((firstB ?? Int.max) < lastA)
    }

    @Test func titleSpamDeliversOnceWithTheLastValue() async {
        let (session, _) = make()
        let titles = Box<[String]>([])
        session.start(.init(onTitle: { t in titles.update { $0.append(t) } }))
        await session.apply((0..<1000).map { .title("t\($0)") })
        #expect(await settle { titles.get().last == "t999" })
        #expect(titles.get().count <= 2)
    }

    @Test func workingDirectoryEventIsDelivered() async {
        let (session, _) = make()
        let tmp = FileManager.default.temporaryDirectory.path
        let dirs = Box<[String]>([])
        session.start(.init(onWorkingDirectory: { d in dirs.update { $0.append(d) } }))
        await session.apply([.workingDirectory(URL(fileURLWithPath: tmp))])
        #expect(await settle { !dirs.get().isEmpty })
        #expect(dirs.get() == [URL(fileURLWithPath: tmp).path])
    }

    @Test func outputThenImmediateExitDeliversBytesBeforeExit() async {
        let (session, pty) = make()
        let exits = Box<[Int32]>([])
        let sawBye = Box(false)
        let versionAtExit = Box<UInt64>(0)
        session.start(.init(onExit: { code in
            versionAtExit.update { $0 = session.outputVersion }
            exits.update { $0.append(code) }
        }))
        pty.feed(Array("bye".utf8))
        pty.finish(.exited(3))
        #expect(await settle { !exits.get().isEmpty })
        #expect(versionAtExit.get() >= 1)
        let rows = await text(session)
        sawBye.update { $0 = rows.contains("bye") }
        #expect(sawBye.get())
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(exits.get() == [3])
    }

    @Test func signaledExitMapsTo128PlusSignal() async {
        let (session, pty) = make()
        let exits = Box<[Int32]>([])
        session.start(.init(onExit: { code in exits.update { $0.append(code) } }))
        pty.finish(.signaled(9))
        #expect(await settle { !exits.get().isEmpty })
        #expect(exits.get() == [137])
    }

    @Test func invalidUTF8AndLoneEscapeDoNotWedgeTheReader() async {
        let (session, pty) = make()
        session.start(.init())
        pty.feed([0xff, 0xfe, 0x1b])
        pty.feed(Array("\u{1b}[mok".utf8))   // a second ESC abandons the lone one
        var got: [String] = []
        for _ in 0..<400 {
            got = await text(session)
            if got.contains(where: { $0.contains("ok") }) { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(got.contains { $0.contains("ok") })
    }

    @Test func hiddenSessionKeepsReading() async {
        let (session, pty) = make()
        session.start(.init())
        let chunk = [UInt8](repeating: 0x78, count: 1024 * 1024)
        for _ in 0..<50 { pty.feed(chunk) }
        #expect(await settle({ pty.readCalls.count >= 800 }, seconds: 60))
        #expect(await settle { session.outputVersion >= 50 })
    }

    // MARK: Task 4

    @Test func resizeClampsToTwoByOne() async {
        let (session, pty) = make()
        session.resize(cols: 0, rows: -3)
        #expect(await settle { session.size == TerminalSize(cols: 2, rows: 1) })
        #expect(pty.resizes.last == TerminalSize(cols: 2, rows: 1))
    }

    @Test func resizesCoalesceToTheNewest() async {
        let (session, pty) = make()
        let gate = DispatchSemaphore(value: 0)
        let entered = Box(false)
        TerminalSession.readerQueue.async { entered.update { $0 = true }; gate.wait() }
        #expect(await settle { entered.get() })
        for i in 0..<50 { session.resize(cols: 70 + i, rows: 20) }
        session.resize(cols: 120, rows: 40)
        gate.signal()
        #expect(await settle { session.size == TerminalSize(cols: 120, rows: 40) })
        #expect(pty.resizes.last == TerminalSize(cols: 120, rows: 40))
        #expect(pty.resizes.count <= 2)
    }

    @Test func busyWhenForegroundGroupDiffers() async {
        let clock = Box(Date(timeIntervalSince1970: 1000))
        let pty = ScriptedPty(processID: 500)
        let session = TerminalSession(paneID: UUID(), pty: pty, size: size, scrollback: 100, now: { clock.get() })
        session.start(.init())
        pty.foreground = 501
        #expect(session.isBusy())
        pty.foreground = 500
        #expect(!session.isBusy())
    }

    @Test func busyFallsBackToRecentOutputWhenGroupUnknown() async {
        let clock = Box(Date(timeIntervalSince1970: 1000))
        let pty = FallbackPty()
        let session = TerminalSession(paneID: UUID(), pty: pty, size: size, scrollback: 100, now: { clock.get() })
        session.start(.init())
        #expect(!session.isBusy())
        pty.feed(Array("x".utf8))
        #expect(await settle { session.outputVersion >= 1 })
        clock.update { $0 = Date(timeIntervalSince1970: 1001) }
        #expect(session.isBusy())
        clock.update { $0 = Date(timeIntervalSince1970: 1006) }
        #expect(!session.isBusy())
    }

    @Test func exitedSessionIsNeverBusy() async {
        let (session, pty) = make(ScriptedPty(processID: 500))
        session.start(.init())
        pty.foreground = 501
        pty.finish(.exited(0))
        #expect(await settle { session.hasExited })
        #expect(!session.isBusy())
    }

    @Test func terminateHangsUpThenReturnsWhenTheChildExits() async {
        let (session, pty) = make()
        session.start(.init())
        await session.terminate(grace: .seconds(2))
        #expect(pty.signals == [.hangup])
        #expect(pty.closed)
        #expect(session.hasExited)
    }

    @Test func terminateKillsAfterGraceWhenHangupIgnored() async {
        let (session, pty) = make()
        pty.ignoresHangup = true
        session.start(.init())
        await session.terminate(grace: .milliseconds(50))
        #expect(pty.signals == [.hangup, .kill])
        #expect(pty.closed)
    }

    @Test func noSignalAfterExit() async {
        let (session, pty) = make()
        session.start(.init())
        pty.finish(.exited(0))
        #expect(await settle { session.hasExited })
        await session.terminate(grace: .milliseconds(50))
        #expect(pty.signals.isEmpty)
        #expect(pty.closed)
    }

    @Test func terminateTwiceIsHarmless() async {
        let (session, pty) = make()
        pty.ignoresHangup = true
        session.start(.init())
        await session.terminate(grace: .milliseconds(20))
        await session.terminate(grace: .milliseconds(20))
        #expect(pty.signals == [.hangup, .kill])
    }

    @Test(.disabled("MetalUI emulator resize/reflow (plan 1.5) not landed"))
    func emulatorResizeFollowsMetalUIReflow() async {
        let (session, pty) = make()
        session.start(.init())
        session.resize(cols: 100, rows: 30)
        #expect(await settle { session.size == TerminalSize(cols: 100, rows: 30) })
        pty.feed(Array(String(repeating: "a", count: 100).utf8))
        #expect(await settle { session.outputVersion >= 1 })
        // After reflow support, a 100 column line fits one row of the resized emulator.
        let first = await session.withEmulator { $0.rowText($0.firstRow) }
        #expect(first == String(repeating: "a", count: 100))
    }
}

/// A pty that cannot name its foreground group.
private final class FallbackPty: PtyHandle, @unchecked Sendable {
    let inner = ScriptedPty()
    var processID: Int32 { inner.processID }
    func feed(_ b: [UInt8]) { inner.feed(b) }
    func onReadable(queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) { inner.onReadable(queue: queue, handler) }
    func read(into: UnsafeMutableRawBufferPointer) -> Int { inner.read(into: into) }
    func write(_ bytes: [UInt8]) { inner.write(bytes) }
    func resize(cols: Int, rows: Int) { inner.resize(cols: cols, rows: rows) }
    func signalGroup(_ signal: PseudoTerminal.Signal) { inner.signalGroup(signal) }
    func foregroundProcessGroup() -> Int32? { nil }
    var exitStatus: PseudoTerminal.ExitStatus { get async { await inner.exitStatus } }
    func close() { inner.close() }
}

#endif
