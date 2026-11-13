import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP


private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private struct Harness {
    let server: LanguageServer
    let sync: DocumentSync
    let dir: URL
    let logURL: URL

    init(sync kind: Int?, encoding: String? = nil, extra: [String: JSONValue] = [:]) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("log.jsonl")
        var caps: [String: JSONValue] = [:]
        if let kind { caps["textDocumentSync"] = .number(Double(kind)) }
        if let encoding { caps["positionEncoding"] = .string(encoding) }
        var script = extra
        script["capabilities"] = .object(caps)
        var env = ProcessInfo.processInfo.environment
        env["FAKE_LSP_SCRIPT"] = String(decoding: try JSONEncoder().encode(JSONValue.object(script)), as: UTF8.self)
        env["FAKE_LSP_LOG"] = logURL.path
        let environment = env, dir = self.dir
        let config = ServerConfig(id: "fake", name: "Fake", languageID: "fake", command: fakeServerPath)
        server = LanguageServer(config: config, root: dir, launcher: {
            try ServerProcess(executable: fakeServerPath, arguments: [], environment: environment, currentDirectory: dir)
        })
        sync = DocumentSync(server: server)
    }

    private func lines(_ url: URL) -> [JSONValue] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
    }
    func log() -> [JSONValue] { lines(logURL) }
    /// The fake's reconstructed document text after each didOpen/didChange.
    func docs() -> [JSONValue] { lines(URL(fileURLWithPath: logURL.path + ".docs")) }
    /// Protocol violations the strict fake saw (out-of-range positions, change/save/close for an unopened document).
    func errors() -> [String] { lines(URL(fileURLWithPath: logURL.path + ".errors")).compactMap { $0["error"]?.stringValue } }
    /// The methods of the document messages (open/change/save/close) the server received, in order.
    func documentMethods() -> [String] {
        log().compactMap { $0["method"]?.stringValue }.filter {
            ["textDocument/didOpen", "textDocument/didChange", "textDocument/didSave", "textDocument/didClose"].contains($0)
        }
    }
    func messages(_ method: String) -> [JSONValue] { log().filter { $0["method"]?.stringValue == method } }
    /// Every contentChanges entry of every didChange, in arrival order.
    func changes() -> [JSONValue] {
        messages("textDocument/didChange").flatMap { $0["params"]?["contentChanges"]?.arrayValue ?? [] }
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

/// A buffer whose edit stream feeds a `DocumentSync`.
@MainActor
private final class Driver {
    let buffer: CodeBuffer
    let cursor: CodeEditCursor
    let sync: DocumentSync
    let uri: URL

    init(text: String, sync: DocumentSync, uri: URL = URL(string: "file:///tmp/doc.txt")!) {
        buffer = CodeBuffer(text)
        cursor = buffer.makeEditCursor()
        self.sync = sync
        self.uri = uri
    }

    func open() async { await sync.open(uri: uri, languageID: "plaintext", snapshot: buffer.snapshot()) }

    func flush() async {
        switch cursor.drain() {
        case .edits(let edits): if !edits.isEmpty { await sync.apply(uri: uri, change: .edits(edits, after: buffer.snapshot())) }
        case .resync(let snapshot): await sync.apply(uri: uri, change: .resync(snapshot))
        }
    }

    func edit(_ range: Range<Int>, _ text: String, origin: CodeEditOrigin = .typing) async {
        buffer.replace(range, with: text, origin: origin)
        await flush()
    }
}

private func range(_ change: JSONValue) -> [Int] {
    [change["range"]?["start"]?["line"]?.intValue, change["range"]?["start"]?["character"]?.intValue,
     change["range"]?["end"]?["line"]?.intValue, change["range"]?["end"]?["character"]?.intValue].map { $0 ?? -1 }
}

@Suite
@MainActor
struct DocumentSyncTests {
    @Test func incrementalChangesMatchEdits() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        await h.server.start()
        let d = Driver(text: "hello\nworld", sync: h.sync)
        await d.open()
        await d.edit(5..<5, "!")           // "hello!\nworld"
        await d.edit(7..<12, "")           // delete "world"
        #expect(await waitUntil { h.changes().count == 2 })
        let changes = h.changes()
        #expect(range(changes[0]) == [0, 5, 0, 5])
        #expect(changes[0]["text"]?.stringValue == "!")
        #expect(range(changes[1]) == [1, 0, 1, 5])
        #expect(changes[1]["text"]?.stringValue == "")
        let versions = h.messages("textDocument/didChange").compactMap { $0["params"]?["textDocument"]?["version"]?.intValue }
        #expect(versions.last == 2)
        #expect(versions == versions.sorted())
        #expect(await waitUntil { h.docs().last?["text"]?.stringValue == "hello!\n" })
        #expect(h.errors().isEmpty)
        let open = try #require(h.messages("textDocument/didOpen").first)
        #expect(open["params"]?["textDocument"]?["version"]?.intValue == 0)
        #expect(open["params"]?["textDocument"]?["languageId"]?.stringValue == "plaintext")
        await h.server.shutdown()
    }

    @Test func multiEditBatchUsesPerEditCoordinatesUTF16() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        await h.server.start()
        let d = Driver(text: "a😀b\nxyz", sync: h.sync)
        await d.open()
        // Two edits drained together: after the first, the second is measured in the already edited text.
        d.buffer.replace(1..<5, with: "", origin: .deletion)     // "ab\nxyz"
        d.buffer.replace(2..<2, with: "é😀", origin: .typing)    // "abé😀\nxyz"
        await d.flush()
        #expect(await waitUntil { h.changes().count == 2 })
        let changes = h.changes()
        #expect(range(changes[0]) == [0, 1, 0, 3])
        #expect(range(changes[1]) == [0, 2, 0, 2])
        #expect(await waitUntil { h.docs().last?["text"]?.stringValue == d.buffer.snapshot().text })
        await h.server.shutdown()
    }

    @Test func fullSyncSendsWholeText() async throws {
        let h = try Harness(sync: 1)
        defer { h.cleanup() }
        await h.server.start()
        let d = Driver(text: "abc", sync: h.sync)
        await d.open()
        await d.edit(3..<3, "d")
        #expect(await waitUntil { !h.changes().isEmpty })
        let changes = h.changes()
        #expect(changes.allSatisfy { $0["range"] == nil })
        #expect(changes.last?["text"]?.stringValue == "abcd")
        await h.server.shutdown()
    }

    @Test func resyncSendsWholeText() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        await h.server.start()
        let d = Driver(text: "abc", sync: h.sync)
        await d.open()
        d.buffer.replace(0..<3, with: "zzzz")
        await h.sync.apply(uri: d.uri, change: .resync(d.buffer.snapshot()))
        #expect(await waitUntil { !h.changes().isEmpty })
        let changes = h.changes()
        #expect(changes.count == 1)
        #expect(changes[0]["range"] == nil)
        #expect(changes[0]["text"]?.stringValue == "zzzz")
        #expect(h.messages("textDocument/didChange").first?["params"]?["textDocument"]?["version"]?.intValue == 1)
        await h.server.shutdown()
    }

    @Test func burstEditsStayOrdered() async throws {
        let h = try Harness(sync: 2, extra: ["delayMs": .number(5)])
        defer { h.cleanup() }
        await h.server.start()
        let d = Driver(text: "", sync: h.sync)
        await d.open()
        for i in 0..<200 {
            let c = String(UnicodeScalar(UInt8(97 + i % 26)))
            await d.edit(d.buffer.utf8Count..<d.buffer.utf8Count, c)
        }
        let expected = d.buffer.snapshot().text
        #expect(expected.count == 200)
        #expect(await waitUntil { h.docs().last?["version"]?.intValue == 200 })
        #expect(h.docs().last?["text"]?.stringValue == expected)
        let versions = h.messages("textDocument/didChange").compactMap { $0["params"]?["textDocument"]?["version"]?.intValue }
        #expect(versions == versions.sorted())
        #expect(h.changes().count == 200)
        #expect(h.errors().isEmpty)
        await h.server.shutdown()
    }

    @Test func externalEditsReachServer() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        await h.server.start()
        let d = Driver(text: "one two", sync: h.sync)
        await d.open()
        try d.buffer.applyExternalEdits([CodeTextEdit(range: 4..<7, text: "three")])
        await d.flush()
        #expect(await waitUntil { h.docs().last?["text"]?.stringValue == "one three" })
        #expect(range(h.changes()[0]) == [0, 4, 0, 7])
        await h.server.shutdown()
    }

    @Test func largeFilesAreNotOpened() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        await h.server.start()
        let big = String(repeating: "a", count: 1_048_577)
        let d = Driver(text: big, sync: h.sync)
        await d.open()
        await d.edit(0..<0, "b")
        #expect(await h.sync.snapshot(for: d.uri, version: 0) == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.messages("textDocument/didOpen").isEmpty)
        #expect(h.messages("textDocument/didChange").isEmpty)
        // Exactly at the cap is still opened.
        let edge = Driver(text: String(repeating: "a", count: 1_048_576), sync: h.sync, uri: URL(string: "file:///tmp/edge.txt")!)
        await edge.open()
        #expect(await waitUntil { h.messages("textDocument/didOpen").count == 1 })
        await h.server.shutdown()
    }

    @Test func snapshotsAreKeptByVersion() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        await h.server.start()
        let d = Driver(text: "", sync: h.sync)
        await d.open()
        for _ in 0..<10 { await d.edit(d.buffer.utf8Count..<d.buffer.utf8Count, "x") }
        #expect(await h.sync.snapshot(for: d.uri, version: 10)?.text == String(repeating: "x", count: 10))
        #expect(await h.sync.snapshot(for: d.uri, version: 3)?.text == "xxx")
        #expect(await h.sync.snapshot(for: d.uri, version: 2) == nil)
        #expect(await h.sync.snapshot(for: d.uri, version: 99) == nil)
        await h.server.shutdown()
    }

    @Test func saveBeforeCloseIsSentThenClose() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        await h.server.start()
        let d = Driver(text: "x", sync: h.sync)
        await d.open()
        #expect(await waitUntil { !h.messages("textDocument/didOpen").isEmpty })   // the server has the document
        await h.sync.saved(uri: d.uri)
        await h.sync.close(uri: d.uri)
        await d.edit(1..<1, "y")   // unknown now: ignored
        #expect(await waitUntil { !h.messages("textDocument/didClose").isEmpty })
        #expect(h.documentMethods() == ["textDocument/didOpen", "textDocument/didSave", "textDocument/didClose"])
        #expect(h.errors().isEmpty)
        await h.server.shutdown()
    }

    @Test func closeBeforeOpenWasSentSendsNothing() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        let d = Driver(text: "x", sync: h.sync)
        await d.open()               // server not started: queued
        await h.sync.saved(uri: d.uri)
        await h.sync.close(uri: d.uri)
        await d.open()               // re-opened with the same URI
        await h.server.start()
        #expect(await waitUntil { !h.messages("textDocument/didOpen").isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.documentMethods() == ["textDocument/didOpen"])
        #expect(h.errors().isEmpty)
        await h.server.shutdown()
    }

    @Test func opsBeforeFirstStartAreQueuedAndOpenComesFirst() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        let d = Driver(text: "abc", sync: h.sync)
        await d.open()
        await d.edit(3..<3, "d")
        await h.sync.saved(uri: d.uri)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.log().isEmpty)     // nothing can be sent yet, and nothing was dropped
        await h.server.start()
        #expect(await waitUntil { !h.messages("textDocument/didSave").isEmpty })
        #expect(h.documentMethods() == ["textDocument/didOpen", "textDocument/didSave"])
        let open = try #require(h.messages("textDocument/didOpen").first)
        #expect(open["params"]?["textDocument"]?["text"]?.stringValue == "abcd")
        #expect(open["params"]?["textDocument"]?["version"]?.intValue == 1)
        #expect(h.errors().isEmpty)
        await h.server.shutdown()
    }

    @Test func opsAreDroppedWhenServerFailed() async throws {
        let h = try Harness(sync: 2, extra: ["exitOnInitializeFromLaunch": .number(1)])
        defer { h.cleanup() }
        await h.server.start()
        #expect(await waitUntil(.seconds(20)) { if case .failed = await h.server.state { true } else { false } })
        let d = Driver(text: "abc", sync: h.sync)
        await d.open()
        await d.edit(3..<3, "d")
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.documentMethods().isEmpty)
    }

    @Test func coalescedMultiLineNonASCIIBatchesHaveExactRanges() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        await h.server.start()
        let d = Driver(text: "héllo wörld 😀\nsecond línea\nthird 😀 line\nfourth", sync: h.sync)
        await d.open()
        #expect(await waitUntil { !h.docs().isEmpty })
        await h.sync.setPaused(true)
        func find(_ s: String) -> Range<Int> { d.buffer.snapshot().ranges(of: s)[0] }
        // 1: insert before the emoji on line 0.
        await d.edit(find("😀").lowerBound..<find("😀").lowerBound, "X")
        // 2: replace a word after non-ASCII text on line 1.
        await d.edit(find("línea"), "LÍNEA!")
        // 3: two edits drained together; the second is measured in the text left by the first.
        d.buffer.replace(find("third"), with: "3rd")
        d.buffer.replace(find(" line"), with: "!")
        await d.flush()
        // 4: delete the line break between lines 2 and 3.
        let nl = find("\nfourth").lowerBound
        await d.edit(nl..<(nl + 1), "")
        await h.sync.setPaused(false)
        let expected = d.buffer.snapshot().text
        #expect(await waitUntil { h.docs().last?["text"]?.stringValue == expected })
        #expect(h.messages("textDocument/didChange").count == 1)   // one coalesced message
        #expect(h.messages("textDocument/didChange")[0]["params"]?["textDocument"]?["version"]?.intValue == 5)
        #expect(h.changes().map(range) == [[0, 12, 0, 12], [1, 7, 1, 12], [2, 0, 2, 5], [2, 6, 2, 11], [2, 7, 3, 0]])
        #expect(h.errors().isEmpty)
        await h.server.shutdown()
    }

    @Test func discontinuousBatchSendsFullText() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        await h.server.start()
        let d = Driver(text: "abc", sync: h.sync)
        await d.open()
        d.buffer.replace(0..<0, with: "x")
        _ = d.cursor.drain()            // a batch the caller never delivered
        await d.edit(4..<4, "y")        // "xabcy"
        #expect(await waitUntil { h.docs().last?["text"]?.stringValue == "xabcy" })
        let changes = h.changes()
        #expect(changes.count == 1)
        #expect(changes[0]["range"] == nil)
        #expect(changes[0]["text"]?.stringValue == "xabcy")
        #expect(h.errors().isEmpty)
        await h.server.shutdown()
    }

    @Test func pendingStepsCollapseToFullText() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        await h.server.start()
        let d = Driver(text: "", sync: h.sync)
        await d.open()
        #expect(await waitUntil { !h.docs().isEmpty })
        await h.sync.setPaused(true)
        for i in 0..<70 { await d.edit(d.buffer.utf8Count..<d.buffer.utf8Count, String(i % 10)) }
        await h.sync.setPaused(false)
        let expected = d.buffer.snapshot().text
        #expect(await waitUntil { h.docs().last?["text"]?.stringValue == expected })
        let changes = h.changes()
        // 64 steps, then the 65th collapsed them into one whole-text change; 5 incremental steps follow.
        #expect(changes.count == 6)
        #expect(changes[0]["range"] == nil)
        #expect(changes[0]["text"]?.stringValue == String(expected.prefix(65)))
        #expect(changes.dropFirst().allSatisfy { $0["range"] != nil })
        #expect(h.messages("textDocument/didChange").last?["params"]?["textDocument"]?["version"]?.intValue == 70)
        #expect(h.errors().isEmpty)
        await h.server.shutdown()
    }

    @Test func crlfGapInLaterBatchMemberClampsLikeFirst() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        await h.server.start()
        let d = Driver(text: "ab\r\ncd", sync: h.sync)
        await d.open()
        d.buffer.replace(0..<0, with: "Z", origin: .typing)      // "Zab\r\ncd"
        d.buffer.replace(4..<4, with: "q", origin: .typing)      // offset 4 is between CR and LF
        await d.flush()
        #expect(await waitUntil { h.changes().count == 2 })
        let r = h.changes().map(range)
        #expect(r[0] == [0, 0, 0, 0])
        #expect(r[1] == [0, 3, 0, 3])        // before the CR, same as a first edit would report
        #expect(h.errors().isEmpty)
        await h.server.shutdown()
    }

    @Test func reopenAllAfterRestartSendsDidOpenWithCurrentText() async throws {
        // The first launch dies right after the didOpen (initialize, initialized, didOpen = 3 messages).
        let h = try Harness(sync: 2, extra: ["crashAfter": .number(3), "crashLaunches": .number(1)])
        defer { h.cleanup() }
        let restarts = Counter()
        let sync = h.sync
        await h.server.setOnRestart { restarts.bump(); await sync.reopenAll() }
        await h.server.start()
        let d = Driver(text: "abc", sync: h.sync)
        await d.open()
        await d.edit(3..<3, "d")
        #expect(await waitUntil { restarts.value == 1 })
        // Under load the edit may reach the restarted server after its reopen (didOpen of the older text, then a
        // didChange) or before it (one didOpen with the new text). Either way it ends with the current text.
        #expect(await waitUntil { h.docs().last?["text"]?.stringValue == "abcd" })
        let log = h.log()
        let restartedAt = try #require(log.lastIndex { $0["method"]?.stringValue == "initialize" })
        let first = log[restartedAt...].first { ["textDocument/didOpen", "textDocument/didChange"].contains($0["method"]?.stringValue ?? "") }
        #expect(first?["method"]?.stringValue == "textDocument/didOpen", "the restarted server's first document message is a didOpen")
        await h.server.shutdown()
    }

    @Test func nothingReachesRestartedServerBeforeItsDidOpen() async throws {
        let h = try Harness(sync: 2, extra: ["crashAfter": .number(3), "crashLaunches": .number(1)])
        defer { h.cleanup() }
        let restarts = Counter()
        let sync = h.sync
        await h.server.setOnRestart { restarts.bump(); await sync.reopenAll() }
        await h.server.start()
        let d = Driver(text: "abc", sync: h.sync)
        await d.open()
        // Keep editing and saving across the crash and restart.
        for i in 0..<40 {
            await d.edit(d.buffer.utf8Count..<d.buffer.utf8Count, String(i % 10))
            await h.sync.saved(uri: d.uri)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await waitUntil { restarts.value == 1 })
        let expected = d.buffer.snapshot().text
        #expect(await waitUntil { h.docs().last?["text"]?.stringValue == expected })
        // In the second launch the first document message is a didOpen, and there is exactly one.
        let all = h.log().compactMap { $0["method"]?.stringValue }
        let second = try #require(all.lastIndex(of: "initialize"))
        let after = all[second...].filter { $0.hasPrefix("textDocument/did") }
        #expect(after.first == "textDocument/didOpen")
        #expect(after.filter { $0 == "textDocument/didOpen" }.count == 1)
        #expect(h.errors().isEmpty)
        await h.server.shutdown()
    }

    @Test func stalledServerBoundsTheQueueAndCollapsesToFullText() async throws {
        // The server completes the handshake and then never reads stdin again.
        let h = try Harness(sync: 2, extra: ["stallAfterInitialized": .bool(true)])
        defer { h.cleanup() }
        await h.server.start()
        let rpc = try await h.server.connection()
        let text = String(repeating: "0123456789abcdef\n", count: 3000)   // ~51 KB
        let d = Driver(text: text, sync: h.sync)
        await d.open()
        // Each keystroke is a few hundred bytes; the pipe (64 KiB) fills, the writer blocks, the queue stops growing.
        for i in 0..<4000 {
            await d.edit(0..<0, "x")
            if i % 500 == 0 { await Task.yield() }
        }
        let uri = d.uri
        let queued = await rpc.queuedByteCount
        #expect(queued <= (1 << 20) + 64 * 1024, "the connection queued \(queued) bytes")
        #expect(await rpc.queuedMessageCount <= 257)
        // Everything behind the blocked write sits in the sync, coalesced and capped.
        let pending = await h.sync.pendingStepCount(for: uri)
        #expect(pending <= DocumentSync.maxPendingSteps, "\(pending) change steps pending")
        // Stopping the stalled server frees the pump and drops what was queued.
        await h.server.shutdown()
        await h.sync.shutdown()
        #expect(await waitUntil { await !h.sync.isPumping })
    }

    @Test func shutdownFreesAPumpParkedOnAStoppedServer() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        // The server never starts: the pump waits for it.
        let d = Driver(text: "hello", sync: h.sync)
        await d.open()
        #expect(await h.sync.isPumping)
        let waiter = Task { await h.sync.waitUntilSent() }
        try await Task.sleep(for: .milliseconds(100))
        await h.sync.shutdown()
        await waiter.value   // resumed by the shutdown
        #expect(await waitUntil { await !h.sync.isPumping })
        // Nothing is accepted afterwards, and nothing waits.
        await d.open()
        #expect(await !h.sync.isPumping)
        await h.sync.waitUntilSent()
    }

    @Test func waitUntilSentHonoursCancellation() async throws {
        let h = try Harness(sync: 2)
        defer { h.cleanup() }
        let d = Driver(text: "hello", sync: h.sync)
        await d.open()   // the server is stopped, so the open stays queued
        let waiter = Task { await h.sync.waitUntilSent() }
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        // Returns although the queue never drains.
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await waiter.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished, "a cancelled waitUntilSent stayed suspended")
        await h.sync.shutdown()
    }
}
