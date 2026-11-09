@testable import AlloyCore
import MetalUICodeBuffer
import Foundation
import Testing

@MainActor @Suite struct AutosaveTests {
    @Test func autosaveAfterOneSecond() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "hello\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "big ")
        await waitUntil("timer armed") { e.clock.pendingSleepers == 1 }
        e.clock.advance(by: 0.9)
        #expect(e.clock.pendingSleepers == 1)   // not due yet
        for _ in 0..<50 { await Task.yield() }
        #expect(e.ws.writeCount == 0)
        #expect(e.read("a.txt") == "hello\n")
        e.clock.advance(by: 0.2)
        await waitUntil("autosave") { !doc.isDirty }
        #expect(e.ws.writeCount == 1)
        #expect(e.read("a.txt") == "big hello\n")
    }

    @Test func typingRestartsTheDebounce() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "x\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "1")
        await waitUntil("first timer") { e.clock.pendingSleepers == 1 }   // deadline 1.0
        e.clock.advance(by: 0.8)
        // Wait for the observer to re-arm: the second edit must be seen as a change.
        for _ in 0..<50 { await Task.yield() }
        _ = doc.buffer.replace(0..<0, with: "2")                          // deadline 1.8
        await waitUntil("restarted timer") { e.clock.pendingSleepers == 1 && e.clock.now == 0.8 }
        e.clock.advance(by: 0.8)                                           // t = 1.6: past the first deadline
        #expect(e.clock.pendingSleepers == 1)
        for _ in 0..<50 { await Task.yield() }
        #expect(e.ws.writeCount == 0)
        #expect(e.read("a.txt") == "x\n")
        e.clock.advance(by: 0.3)                                           // t = 1.9
        await waitUntil("autosave") { !doc.isDirty }
        for _ in 0..<50 { await Task.yield() }
        #expect(e.ws.writeCount == 1)
        #expect(e.read("a.txt") == "21x\n")
    }

    @Test func saveRecordsYouEdit() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\nthree\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(4..<7, with: "TWO")
        try await e.ws.save("a.txt")
        let file = try #require(e.ws.ledger.files["a.txt"])
        #expect(file.edits.last?.author == .user)
        #expect(file.text.text == "one\nTWO\nthree\n")
        #expect(e.lineAuthors("a.txt") == [nil, .user, nil])
        #expect(!doc.isDirty)
        #expect(e.read("a.txt") == "one\nTWO\nthree\n")
        #expect(doc.diskStamp.size == 14)
        #expect(e.ws.changedFiles.first?.authors == [.user])
    }

    @Test func saveKeepsFileMode() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("run.sh", "echo\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: e.url("run.sh").path)
        await e.ws.open("run.sh")
        _ = try #require(e.ws.document("run.sh")).buffer.replace(0..<0, with: "# x\n")
        try await e.ws.save("run.sh")
        let mode = try FileManager.default.attributesOfItem(atPath: e.url("run.sh").path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(e.read("run.sh") == "# x\necho\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: e.root.path).filter { $0.hasPrefix(".alloy-save") }
        #expect(leftovers.isEmpty)
    }

    /// Minor 8: an editor revert goes through the same mode-keeping atomic writer as save.
    @Test func revertKeepsFileMode() async throws {
        let e = Env(); defer { e.cleanup() }
        let old = "echo one\necho two\n", new = "echo one\necho TWO\n"
        e.write("run.sh", old)
        await e.ws.open("run.sh")
        _ = await e.ws.newSession(name: "Ann")
        try await e.sessionEdit("run.sh", old: old, new: new)
        await waitUntil("session record") { e.ws.ledger.files["run.sh"] != nil }
        await e.ws.settle()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: e.url("run.sh").path)
        let id = try #require(e.ws.ledger.files["run.sh"]?.edits.first?.id)
        let outcome = await e.ws.revertInEditor(edit: id, path: "run.sh")
        await e.ws.settle()
        #expect(outcome == .reverted(newText: old))
        #expect(e.read("run.sh") == old)
        let mode = try FileManager.default.attributesOfItem(atPath: e.url("run.sh").path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: e.root.path).filter { $0.hasPrefix(".alloy-save") }
        #expect(leftovers.isEmpty)
    }

    /// N2: a save that lands while a revert computes must not be overwritten by the revert's write.
    @Test func aSaveDuringARevertIsNotOverwritten() async throws {
        let e = Env(); defer { e.cleanup() }
        let old = "one\ntwo\nthree\n", new = "one\nTWO\nthree\n"
        e.write("a.txt", old)
        await e.ws.open("a.txt")
        _ = await e.ws.newSession(name: "Ann")
        try await e.sessionEdit("a.txt", old: old, new: new)
        await waitUntil("session record") { e.ws.ledger.files["a.txt"]?.edits.isEmpty == false }
        await e.ws.settle()
        let id = try #require(e.ws.ledger.files["a.txt"]?.edits.first?.id)
        let doc = try #require(e.ws.document("a.txt"))
        let hold = TestGate()
        e.ws.revertWriteGate = { _ in await hold.hold() }
        let reverter = Task { await e.ws.revertInEditor(edit: id, path: "a.txt") }
        await hold.waitUntilEntered()
        // The user types and the autosave/tab-switch save runs while the revert is computing.
        let at = doc.buffer.utf8Count
        _ = doc.buffer.replace(at..<at, with: "typed\n")
        let saver = Task { try await e.ws.save("a.txt") }
        for _ in 0..<2_000 { await Task.yield() }
        await hold.release()
        let outcome = await reverter.value
        try await saver.value
        await e.ws.settle()
        let disk = e.read("a.txt")
        #expect(disk.contains("typed\n"), "typing lost on disk: \(disk.debugDescription)")
        #expect(doc.buffer.snapshot().text.contains("typed\n"), "typing lost in the buffer")
        switch outcome {
        case .reverted: #expect(disk.contains("\ntwo\n") && !disk.contains("TWO"), "not reverted: \(disk.debugDescription)")
        case .conflict: break
        }
        #expect(!doc.isDirty)
    }

    /// N2: another program writing the file while the revert is about to write it is never overwritten; the revert
    /// is recomputed against the current text.
    @Test func anExternalWriteDuringARevertSurvives() async throws {
        let e = Env(); defer { e.cleanup() }
        let old = "one\ntwo\nthree\n", new = "one\nTWO\nthree\n"
        e.write("a.txt", old)
        await e.ws.open("a.txt")
        _ = await e.ws.newSession(name: "Ann")
        try await e.sessionEdit("a.txt", old: old, new: new)
        await waitUntil("session record") { e.ws.ledger.files["a.txt"]?.edits.isEmpty == false }
        await e.ws.settle()
        let id = try #require(e.ws.ledger.files["a.txt"]?.edits.first?.id)
        let hold = TestGate()
        e.ws.revertWriteGate = { _ in await hold.hold() }
        let reverter = Task { await e.ws.revertInEditor(edit: id, path: "a.txt") }
        await hold.waitUntilEntered()
        e.write("a.txt", "one\nTWO\nTHREE\n")                 // another program, meanwhile
        await hold.release()
        let outcome = await reverter.value
        await e.ws.settle()
        #expect(outcome == .reverted(newText: "one\ntwo\nTHREE\n"), "\(outcome)")
        #expect(e.read("a.txt") == "one\ntwo\nTHREE\n")
    }

    @Test func outsideChangeBeforeSaveRecorded() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "a\nb\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        // The first save creates the ledger.
        _ = doc.buffer.replace(0..<0, with: "u1 ")
        try await e.ws.save("a.txt")
        // Something else rewrites the file, and the user types again before Alloy notices.
        e.write("a.txt", "u1 a\nb\nfrom outside\n")
        _ = doc.buffer.replace(0..<0, with: "u2 ")
        try await e.ws.save("a.txt")
        let file = try #require(e.ws.ledger.files["a.txt"])
        #expect(file.edits.map(\.author) == [.user, .outside, .user])
        #expect(file.edits[1].hunks.contains { $0.lines.contains("+from outside\n") || $0.lines.contains("+from outside") })
        // The outside change is merged into the buffer, not overwritten.
        #expect(e.read("a.txt") == "u2 u1 a\nb\nfrom outside\n")
        #expect(file.text.text == e.read("a.txt"))
    }

    @Test func saveWithoutLedgerUsesSavedTextAsBaseline() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "a\nb\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        e.write("a.txt", "a\nb\nc\n")          // changed outside, Alloy has not noticed
        _ = doc.buffer.replace(0..<0, with: "x")
        try await e.ws.save("a.txt")
        let file = try #require(e.ws.ledger.files["a.txt"])
        #expect(file.edits.map(\.author) == [.outside, .user])
        #expect(file.text.text == "xa\nb\nc\n")
        #expect(e.read("a.txt") == "xa\nb\nc\n")
    }

    @Test func switchingTabsSaves() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "a"); e.write("b.txt", "b")
        await e.ws.open("a.txt"); await e.ws.open("b.txt")
        _ = try #require(e.ws.document("b.txt")).buffer.replace(0..<0, with: "z")
        e.ws.activeTab = "a.txt"
        await e.ws.settle()
        #expect(e.read("b.txt") == "zb")
    }

    @Test func focusLeftSaves() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "a")
        await e.ws.open("a.txt")
        _ = try #require(e.ws.document("a.txt")).buffer.replace(0..<0, with: "z")
        await e.ws.focusLeft("a.txt")
        #expect(e.read("a.txt") == "za")
    }

    @Test func saveAllWritesEveryDirtyDocument() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "a"); e.write("b.txt", "b")
        await e.ws.open("a.txt"); await e.ws.open("b.txt")
        _ = try #require(e.ws.document("a.txt")).buffer.replace(0..<0, with: "1")
        _ = try #require(e.ws.document("b.txt")).buffer.replace(0..<0, with: "2")
        await e.ws.saveAll()
        #expect(e.read("a.txt") == "1a" && e.read("b.txt") == "2b")
    }

    @Test func failedSaveIsReportedAndKeepsTheBuffer() async throws {
        let e = Env(); defer { e.cleanup() }
        try FileManager.default.createDirectory(at: e.url("d"), withIntermediateDirectories: true)
        e.write("d/a.txt", "a")
        await e.ws.open("d/a.txt")
        let doc = try #require(e.ws.document("d/a.txt"))
        _ = doc.buffer.replace(0..<0, with: "z")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: e.url("d").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: e.url("d").path) }
        await #expect(throws: (any Error).self) { try await e.ws.save("d/a.txt") }
        #expect(doc.isDirty)
        #expect(e.ws.errors.contains { $0.hasPrefix("Can't save d/a.txt") })
        #expect(e.ws.ledger.files["d/a.txt"] == nil)
    }
}
