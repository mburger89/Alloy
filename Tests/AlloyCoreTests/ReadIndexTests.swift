@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

private final class Harness: @unchecked Sendable {
    private let lock = NSLock()
    private var _transports: [ScriptedTransport] = []
    var transports: [ScriptedTransport] { lock.withLock { _transports } }
    var factory: TransportFactory {
        { [self] _ in
            let t = ScriptedTransport()
            lock.withLock { _transports.append(t) }
            return t
        }
    }
}

private final class Dirs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func make() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-reads-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        let r = u.resolvingSymlinksInPath()
        lock.withLock { urls.append(r) }
        return r
    }
    func cleanup() { lock.withLock { urls }.forEach { try? FileManager.default.removeItem(at: $0) } }
}

/// Fixture lines with the probe's project path rewritten to `root`.
private func fixture(_ name: String, root: URL) -> [Data] {
    Fixture.lines(name).map { Data(String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "/tmp/alloy-fixture", with: root.path).utf8) }
}

private func readUse(_ id: String, _ path: String, offset: Int? = nil, limit: Int? = nil, parent: String? = nil) -> InboundMessage {
    var input: [String: JSONValue] = ["file_path": .string(path)]
    if let offset { input["offset"] = .number(Double(offset)) }
    if let limit { input["limit"] = .number(Double(limit)) }
    return .assistantBlock(messageID: "m-\(id)", block: .toolUse(id: id, name: "Read", input: .object(input), parentToolUseID: parent))
}

/// A subagent-style result: numbered text and no `tool_use_result`.
private func textResult(_ id: String, _ text: String, isError: Bool = false) -> InboundMessage {
    .toolResult(ToolResultMessage(toolUseID: id, isError: isError, text: text, result: .none, raw: nil, parentToolUseID: "agent-1"))
}

private func readResult(_ id: String, _ path: String, start: Int = 1, num: Int, total: Int, truncated: Bool = false) -> InboundMessage {
    var file: [String: JSONValue] = ["filePath": .string(path), "content": .string("x"), "numLines": .number(Double(num)),
                                     "startLine": .number(Double(start)), "totalLines": .number(Double(total))]
    if truncated { file["truncatedByTokenCap"] = .bool(true) }
    return .toolResult(ToolResultMessage(toolUseID: id, isError: false, text: "x", result: .none,
                                         raw: .object(["type": .string("text"), "file": .object(file)])))
}

@MainActor
@Suite final class ReadIndexTests {
    private let dirs = Dirs()
    deinit { dirs.cleanup() }

    private func makeWS(root: URL, support: URL, _ h: Harness) -> Workspace {
        Workspace(projectRoot: root, appSupport: support, settings: AlloySettings(),
                  locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: h.factory, now: Date.init)
    }

    private func write(_ root: URL, _ name: String, _ text: String = "one\ntwo\nthree\n") throws -> String {
        let u = root.appendingPathComponent(name)
        try text.write(to: u, atomically: true, encoding: .utf8)
        return u.path
    }

    /// One complete Read: tool_use, then its result, each settled.
    private func doRead(_ ws: Workspace, _ t: ScriptedTransport, _ id: String, _ path: String, num: Int = 3, total: Int = 3,
                        offset: Int? = nil, limit: Int? = nil, start: Int = 1, truncated: Bool = false) async {
        await t.emit(readUse(id, path, offset: offset, limit: limit))
        await waitUntil("tool_use \(id) handled") { ws.judgedReads.contains(id) }
        await ws.settle()
        await t.emit(readResult(id, path, start: start, num: num, total: total, truncated: truncated))
        await waitUntil("tool_result \(id) handled") { ws.pendingReadPaths[id] == nil }
        await ws.settle()
    }

    @Test func readIsIndexedWithStamp() async throws {
        let h = Harness(); let root = dirs.make()
        let path = try write(root, "a.txt")
        let ws = makeWS(root: root, support: dirs.make(), h)
        let s = await ws.newSession(name: "A")
        await doRead(ws, h.transports[0], "t1", path)
        let entries = ws.readIndex.readers(path: "a.txt")
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.session == s.id && entry.lines == nil && entry.generation == 0)
        #expect(entry.stamp == FileStamp.read(path))
    }

    @Test func truncatedReadIndexesOnlyReturnedLines() async throws {
        let h = Harness(); let root = dirs.make()
        _ = try write(root, "huge.txt", "x\n")
        let ws = makeWS(root: root, support: dirs.make(), h)
        _ = await ws.newSession(name: "A")
        await h.transports[0].emit(fixture: fixture("read-truncated", root: root))
        await waitUntil("read") { !ws.readIndex.readers(path: "huge.txt").isEmpty }
        await ws.settle()
        let entries = ws.readIndex.readers(path: "huge.txt")
        #expect(entries.count == 1)
        guard let lines = entries.first?.lines else { Issue.record("a truncated read must carry a range"); return }
        #expect(lines.lowerBound == 1 && lines.upperBound < 6001 && lines.upperBound > 1)
    }

    @Test func offsetReadIndexesItsOwnRange() async throws {
        let h = Harness(); let root = dirs.make()
        let path = try write(root, "a.txt")
        let ws = makeWS(root: root, support: dirs.make(), h)
        _ = await ws.newSession(name: "A")
        let t = h.transports[0]
        await t.emit(readUse("t1", path))
        await waitUntil("tool_use handled") { ws.judgedReads.contains("t1") }
        await t.emit(readResult("t1", path, start: 2998, num: 2, total: 3001))
        await waitUntil("tool_result handled") { ws.pendingReadPaths["t1"] == nil }
        await ws.settle()
        #expect(ws.readIndex.readers(path: "a.txt").first?.lines == 2998...2999)
    }

    @Test func subagentReadCountsForTheSession() async throws {
        let h = Harness(); let root = dirs.make()
        _ = try write(root, "target.txt", "line one\nline two\nline three\n")
        let ws = makeWS(root: root, support: dirs.make(), h)
        let s = await ws.newSession(name: "A")
        await h.transports[0].emit(fixture: fixture("subagent-read", root: root))
        await waitUntil("read") { !ws.readIndex.readers(path: "target.txt").isEmpty }
        await ws.settle()
        let entries = ws.readIndex.readers(path: "target.txt")
        #expect(entries.count == 1)
        #expect(entries.first?.session == s.id)
    }

    @Test func rereadOfUnchangedFileIsRedundant() async throws {
        let h = Harness(); let root = dirs.make()
        let path = try write(root, "a.txt")
        let ws = makeWS(root: root, support: dirs.make(), h)
        let s = await ws.newSession(name: "A")
        let t = h.transports[0]
        await doRead(ws, t, "t1", path)
        #expect(s.redundantReads == 0 && ws.redundantReads == 0)
        await doRead(ws, t, "t2", path)
        #expect(s.redundantReads == 1 && ws.redundantReads == 1)
    }

    @Test func rereadAfterCompactionIsNot() async throws {
        let h = Harness(); let root = dirs.make()
        let path = try write(root, "a.txt")
        let ws = makeWS(root: root, support: dirs.make(), h)
        let s = await ws.newSession(name: "A")
        let t = h.transports[0]
        await doRead(ws, t, "t1", path)
        await t.emit(fixture: Fixture.lines("compact").filter { String(decoding: $0, as: UTF8.self).contains("compact_boundary") })
        await waitUntil("generation") { ws.compactionGeneration[s.id] == 1 }
        await doRead(ws, t, "t2", path)
        #expect(s.redundantReads == 0)
        // The post-compaction read is now the current one.
        await doRead(ws, t, "t3", path)
        #expect(s.redundantReads == 1)
    }

    @Test func rereadAfterClearIsNot() async throws {
        let h = Harness(); let root = dirs.make()
        let path = try write(root, "a.txt")
        let ws = makeWS(root: root, support: dirs.make(), h)
        let s = await ws.newSession(name: "A")
        let t = h.transports[0]
        await doRead(ws, t, "t1", path)
        await t.emit(.conversationReset(newSessionID: "new"))
        await waitUntil("generation") { ws.compactionGeneration[s.id] == 1 }
        await doRead(ws, t, "t2", path)
        #expect(s.redundantReads == 0)
        // Control: a second read in the new conversation is redundant.
        await doRead(ws, t, "t3", path)
        #expect(s.redundantReads == 1)
    }

    @Test func rereadAfterTheFileChangedIsNot() async throws {
        let h = Harness(); let root = dirs.make()
        let path = try write(root, "a.txt")
        let ws = makeWS(root: root, support: dirs.make(), h)
        let s = await ws.newSession(name: "A")
        let t = h.transports[0]
        await doRead(ws, t, "t1", path)
        _ = try write(root, "a.txt", "one\ntwo\nthree\nfour\n")
        await doRead(ws, t, "t2", path, num: 4, total: 4)
        #expect(s.redundantReads == 0)
        // Control: the same read again, with the file unchanged since t2, is redundant.
        await doRead(ws, t, "t3", path, num: 4, total: 4)
        #expect(s.redundantReads == 1)
    }

    @Test func otherSessionsReadMakesItRedundant() async throws {
        let h = Harness(); let root = dirs.make()
        let path = try write(root, "a.txt")
        let ws = makeWS(root: root, support: dirs.make(), h)
        let a = await ws.newSession(name: "A")
        let b = await ws.newSession(name: "B")
        await doRead(ws, h.transports[0], "t1", path)
        await doRead(ws, h.transports[1], "t2", path)
        #expect(a.redundantReads == 0 && b.redundantReads == 1 && ws.redundantReads == 1)
    }

    @Test func currentNoteMakesAReadRedundant() async throws {
        let h = Harness(); let root = dirs.make()
        let path = try write(root, "a.txt")
        let ws = makeWS(root: root, support: dirs.make(), h)
        let s = await ws.newSession(name: "A")
        ws.hasCurrentNote = { p, _ in p == "a.txt" }
        await doRead(ws, h.transports[0], "t1", path)
        #expect(s.redundantReads == 1)
    }

    @Test func outsideRootIgnored() async throws {
        let h = Harness(); let root = dirs.make(); let other = dirs.make()
        let outside = try write(other, "o.txt")
        let ws = makeWS(root: root, support: dirs.make(), h)
        let s = await ws.newSession(name: "A")
        let t = h.transports[0]
        await doRead(ws, t, "t1", outside)
        await doRead(ws, t, "t2", outside)
        #expect(ws.readIndex.readers(path: "o.txt").isEmpty)
        #expect(s.redundantReads == 0)
        // Control: the same calls on a file inside the root are indexed and the second one is redundant.
        let inside = try write(root, "in.txt")
        await doRead(ws, t, "t3", inside)
        await doRead(ws, t, "t4", inside)
        #expect(ws.readIndex.readers(path: "in.txt").count == 1)
        #expect(s.redundantReads == 1)
    }

    @Test func missingFileRecordsNothing() async throws {
        let h = Harness(); let root = dirs.make()
        let ws = makeWS(root: root, support: dirs.make(), h)
        _ = await ws.newSession(name: "A")
        await doRead(ws, h.transports[0], "t1", root.appendingPathComponent("gone.txt").path)
        #expect(ws.readIndex.readers(path: "gone.txt").isEmpty)
    }

    @Test func indexSurvivesRestart() async throws {
        let h = Harness(); let root = dirs.make(); let support = dirs.make()
        let path = try write(root, "a.txt")
        let ws = makeWS(root: root, support: support, h)
        _ = await ws.newSession(name: "A")
        await doRead(ws, h.transports[0], "t1", path)
        let before = ws.readIndex.readers(path: "a.txt")
        #expect(before.count == 1)
        let ws2 = makeWS(root: root, support: support, Harness())
        _ = await ws2.newSession(name: "A")
        #expect(ws2.readIndex.readers(path: "a.txt") == before)
    }

    @Test func corruptReadsFileIsMovedAside() async throws {
        let h = Harness(); let root = dirs.make(); let support = dirs.make()
        let path = try write(root, "a.txt")
        let ws = makeWS(root: root, support: support, h)
        _ = await ws.newSession(name: "A")
        await doRead(ws, h.transports[0], "t1", path)
        let dir = ProjectLedger.storeURL(projectRoot: root, appSupport: support).deletingLastPathComponent()
        try Data("{broken".utf8).write(to: dir.appendingPathComponent("reads.json"))
        let ws2 = makeWS(root: root, support: support, Harness())
        _ = await ws2.newSession(name: "A")
        #expect(ws2.readIndex.readers(path: "a.txt").isEmpty)
        #expect(ws2.errors.contains { $0.contains("reads.json") })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(names.contains { $0.hasPrefix("reads.json.corrupt-") })
    }

    @Test func forkCopiesTheSourcesReads() {
        var index = ReadIndex()
        let a = UUID(), b = UUID()
        let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1), size: 3)
        index.record(ReadEntry(session: a, path: "x", lines: nil, stamp: stamp, date: Date(timeIntervalSince1970: 2), generation: 0))
        index.copy(from: a, to: b, generation: 3)
        #expect(index.readers(path: "x").first { $0.session == b }?.generation == 3)
        let sessions = Set(index.current(path: "x", stamp: stamp).map(\.session))
        #expect(sessions == [a, b])
    }

    @Test func pagingPastTheCapIsNotRedundant() async throws {
        let h = Harness(); let root = dirs.make()
        let path = try write(root, "big.txt")
        let ws = makeWS(root: root, support: dirs.make(), h)
        let s = await ws.newSession(name: "A")
        let t = h.transports[0]
        await doRead(ws, t, "t1", path, num: 780, total: 1500, truncated: true)
        await doRead(ws, t, "t2", path, num: 720, total: 1500, offset: 781, start: 781)
        #expect(s.redundantReads == 0)
        await doRead(ws, t, "t3", path, num: 780, total: 1500, offset: 1, limit: 780, truncated: true)
        #expect(s.redundantReads == 1)
    }

    @Test func wholeFileRequestNeedsAWholeFileEntry() async throws {
        let h = Harness(); let root = dirs.make()
        let path = try write(root, "big.txt")
        let ws = makeWS(root: root, support: dirs.make(), h)
        let s = await ws.newSession(name: "A")
        let t = h.transports[0]
        await doRead(ws, t, "t1", path, num: 2, total: 3, offset: 1, limit: 2)
        await doRead(ws, t, "t2", path)
        #expect(s.redundantReads == 0)
        await doRead(ws, t, "t3", path)
        #expect(s.redundantReads == 1)
    }

    @Test func generationsSurviveRestart() async throws {
        let h = Harness(); let root = dirs.make(); let support = dirs.make()
        let path = try write(root, "a.txt")
        let ws = makeWS(root: root, support: support, h)
        let s = await ws.newSession(name: "A")
        await doRead(ws, h.transports[0], "t1", path)
        await h.transports[0].emit(.compactBoundary(preTokens: 10, postTokens: 5))
        await waitUntil("generation") { ws.compactionGeneration[s.id] == 1 }
        await ws.settle()
        let h2 = Harness()
        let ws2 = makeWS(root: root, support: support, h2)
        await ws2.restore()
        await ws2.wake(s.id)
        #expect(ws2.compactionGeneration[s.id] == 1)
        await doRead(ws2, h2.transports[0], "t2", path)
        #expect(ws2.session(s.id)?.redundantReads == 0)
        await doRead(ws2, h2.transports[0], "t3", path)
        #expect(ws2.session(s.id)?.redundantReads == 1)
    }

    @Test func oldBareIndexFormatStillLoads() async throws {
        let root = dirs.make(); let support = dirs.make()
        var index = ReadIndex()
        let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1), size: 3)
        index.record(ReadEntry(session: UUID(), path: "x", lines: nil, stamp: stamp, date: Date(timeIntervalSince1970: 2), generation: 0))
        let dir = ProjectLedger.storeURL(projectRoot: root, appSupport: support).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: dir.appendingPathComponent("reads.json"))
        let ws = makeWS(root: root, support: support, Harness())
        _ = await ws.newSession(name: "A")
        #expect(ws.readIndex.readers(path: "x").count == 1)
        #expect(ws.errors.isEmpty)
    }

    @Test func adjacentRangesMergeAndSupersededStampsDrop() {
        var index = ReadIndex()
        let a = UUID()
        let s1 = FileStamp(modified: Date(timeIntervalSince1970: 1), size: 3)
        let s2 = FileStamp(modified: Date(timeIntervalSince1970: 2), size: 4)
        func entry(_ r: ClosedRange<Int>?, _ stamp: FileStamp, gen: Int = 0) -> ReadEntry {
            ReadEntry(session: a, path: "x", lines: r, stamp: stamp, date: Date(timeIntervalSince1970: 5), generation: gen)
        }
        index.record(entry(1...10, s1)); index.record(entry(11...20, s1)); index.record(entry(5...12, s1))
        #expect(index.readers(path: "x").map(\.lines) == [1...20])
        index.record(entry(30...40, s1))
        #expect(index.readers(path: "x").count == 2)
        index.record(entry(nil, s1))
        #expect(index.readers(path: "x").map(\.lines) == [nil])
        index.record(entry(1...3, s2))
        #expect(index.readers(path: "x").map(\.stamp) == [s2])
        // A newer generation that covers an older one replaces it; one that does not, keeps it.
        index.record(entry(1...2, s2, gen: 1))
        #expect(index.readers(path: "x").count == 2)
        index.record(entry(1...3, s2, gen: 2))
        #expect(index.readers(path: "x").map(\.generation) == [2])
    }

    @Test func judgedIdsAreReleasedWhenTheResultLands() async throws {
        let h = Harness(); let root = dirs.make()
        let path = try write(root, "a.txt")
        let ws = makeWS(root: root, support: dirs.make(), h)
        _ = await ws.newSession(name: "A")
        await doRead(ws, h.transports[0], "t1", path)
        #expect(ws.judgedReads.isEmpty && ws.pendingReadPaths.isEmpty)
    }

    @Test func burstOfWritesIsCoalesced() async throws {
        let h = Harness(); let root = dirs.make(); let support = dirs.make()
        let ws = makeWS(root: root, support: support, h)
        _ = await ws.newSession(name: "A")
        let before = ws.readsWritesStarted
        for _ in 0..<30 { ws.persistReads() }
        await ws.settle()
        #expect(ws.readsWritesStarted - before == 1)
        let url = ProjectLedger.storeURL(projectRoot: root, appSupport: support).deletingLastPathComponent().appendingPathComponent("reads.json")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func nonTextAndEmptyReadsAreNotFormatProblems() async throws {
        let h = Harness(); let root = dirs.make()
        let ws = makeWS(root: root, support: dirs.make(), h)
        _ = await ws.newSession(name: "A")
        let t = h.transports[0]
        func result(_ id: String, _ name: String, _ text: String) async throws {
            let path = try write(root, name)
            await t.emit(readUse(id, path))
            await waitUntil("use") { ws.pendingReadPaths[id] != nil }
            await t.emit(.toolResult(ToolResultMessage(toolUseID: id, isError: false, text: text, result: .none, raw: nil, parentToolUseID: nil)))
            await waitUntil("result") { ws.pendingReadPaths[id] == nil }
            await ws.settle()
        }
        // A notebook comes back as cells, not numbered lines.
        try await result("n1", "nb.ipynb", "Cell 1 [code]\nprint(1)\n\nCell 2 [markdown]\nhello")
        try await result("n2", "diagram.pdf", "pdf text without numbers")
        // The CLI's own notes for an empty file and an offset past the end.
        try await result("n3", "empty.txt", "<system-reminder>Warning: the file exists but the contents are empty.</system-reminder>")
        try await result("n4", "short.txt", "<system-reminder>Warning: the file exists but is shorter than the provided offset (50). The file has 3 lines.</system-reminder>")
        #expect(ws.errors.isEmpty, "\(ws.errors)")
        // A text file that really comes back without numbered lines is still reported, once.
        try await result("n5", "odd.swift", "no numbers here")
        #expect(ws.errors.filter { $0.contains("numbered lines") }.count == 1)
    }

    @Test func subagentTextParsing() async throws {
        let h = Harness(); let root = dirs.make()
        let path = try write(root, "a.txt")
        let ws = makeWS(root: root, support: dirs.make(), h)
        _ = await ws.newSession(name: "A")
        let t = h.transports[0]
        func result(_ id: String, _ text: String, isError: Bool = false) async {
            await t.emit(readUse(id, path, parent: "agent-1"))
            await waitUntil("use") { ws.pendingReadPaths[id] != nil }
            await t.emit(textResult(id, text, isError: isError))
            await waitUntil("result") { ws.pendingReadPaths[id] == nil }
            await ws.settle()
        }
        // Numbered text: indexed with an explicit range.
        await result("t1", "1\tone\n2\ttwo\n3\tthree")
        #expect(ws.readIndex.readers(path: "a.txt").first?.lines == 1...3)
        #expect(ws.errors.isEmpty)
        // An error result records nothing and is not a format problem.
        await result("t2", "Error: File does not exist.", isError: true)
        #expect(ws.readIndex.readers(path: "a.txt").count == 1 && ws.errors.isEmpty)
        // An empty result (an empty file) records nothing and is not a format problem.
        let empty = try write(root, "empty.txt", "")
        await t.emit(readUse("t3", empty, parent: "agent-1"))
        await waitUntil("use") { ws.pendingReadPaths["t3"] != nil }
        await t.emit(textResult("t3", ""))
        await waitUntil("result") { ws.pendingReadPaths["t3"] == nil }
        await ws.settle()
        #expect(ws.readIndex.readers(path: "empty.txt").isEmpty && ws.errors.isEmpty)
        // Text that is not numbered lines records nothing and says so once.
        await result("t4", "<system-reminder>something new</system-reminder>")
        await result("t5", "again unnumbered")
        #expect(ws.readIndex.readers(path: "a.txt").count == 1)
        #expect(ws.errors.filter { $0.contains("numbered lines") }.count == 1)
    }
}
