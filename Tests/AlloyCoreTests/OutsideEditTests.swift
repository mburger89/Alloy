@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

@MainActor @Suite struct OutsideEditTests {
    /// Opens `name`, types at the start, and saves, so the ledger holds the file (baseline plus one `.user` edit).
    private func seed(_ e: Env, _ name: String = "a.txt", text: String = "one\ntwo\nthree\n") async throws {
        e.write(name, text)
        await e.ws.open(name)
        let doc = try #require(e.ws.document(name))
        _ = doc.buffer.replace(0..<0, with: "x")
        try await e.ws.save(name)
        await e.ws.close(name)
    }

    private func authors(_ e: Env, _ name: String = "a.txt") -> [Author] { e.ws.ledger.files[name]?.edits.map(\.author) ?? [] }

    @Test func ownSaveIgnored() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "hello\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "big ")
        try await e.ws.save("a.txt")
        await e.fire(["a.txt"])
        #expect(authors(e) == [.user])
        #expect(e.ws.notices.isEmpty)
        #expect(!doc.isDirty)
    }

    @Test func sessionToolWriteIgnoredByWatcher() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e, text: "one\ntwo\n")
        let s = await e.ws.newSession(name: "A")
        let t = try #require(e.transports.all.first)
        let old = "xone\ntwo\n", new = "xone\nTWO\n"
        // The Edit starts, the file changes, and the watcher sees it before the tool result arrives.
        await t.emit(.assistantBlock(messageID: "m1", block: .toolUse(id: "t1", name: "Edit",
                                     input: .object(["file_path": .string(e.url("a.txt").path)]))))
        await waitUntil("edit running") { s.transcript.blocks.contains { if case .tool = $0 { return true } else { return false } } }
        e.write("a.txt", new)
        await e.send(["a.txt"])
        await waitUntil("watcher waiting on the clock") { e.clock.pendingSleepers == 1 }
        #expect(authors(e) == [.user])
        let hunks = Patch.diff(old: TextLines(old).lines, new: TextLines(new).lines, context: 0)
        await t.emit(.toolResult(ToolResultMessage(toolUseID: "t1", isError: false, text: "ok",
                                                   result: .edit(filePath: e.url("a.txt").path, originalFile: old, hunks: hunks))))
        await e.ws.settle()
        #expect(authors(e) == [.user, .session(s.id)])
        #expect(e.ws.ledger.files["a.txt"]?.text.text == new)
    }

    @Test func runningEditWaitsOnlyTwoSeconds() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        _ = await e.ws.newSession(name: "A")
        let t = try #require(e.transports.all.first)
        await t.emit(.assistantBlock(messageID: "m1", block: .toolUse(id: "t1", name: "Write",
                                     input: .object(["file_path": .string(e.url("a.txt").path)]))))
        await waitUntil("write running") { e.ws.sessions.first?.transcript.blocks.isEmpty == false }
        e.write("a.txt", "changed\n")
        await e.send(["a.txt"])
        await waitUntil("watcher waiting") { e.clock.pendingSleepers == 1 }
        e.clock.advance(by: 2.0)
        await e.ws.settle()
        #expect(authors(e).last == .outside)
        #expect(e.ws.ledger.files["a.txt"]?.text.text == "changed\n")
    }

    @Test func externalEditRecordedOutside() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        e.write("a.txt", "one\ntwo\nthree\nfour\n")
        await e.fire(["a.txt"])
        #expect(authors(e) == [.user, .outside])
        #expect(e.ws.ledger.files["a.txt"]?.text.text == "one\ntwo\nthree\nfour\n")
        // A second event for the same text records nothing more.
        await e.fire(["a.txt"])
        #expect(authors(e) == [.user, .outside])
    }

    @Test func eventsAreCoalesced() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        try await seed(e, "b.txt")
        e.write("a.txt", "A\n"); e.write("b.txt", "B\n")
        e.ws.startWatching()
        e.changes.send([e.url("a.txt").path])
        await waitUntil("first queued") { e.ws.pendingOutside.count == 1 }
        for _ in 0..<200 { await Task.yield() }
        #expect(e.ws.pendingOutside.count == 1)     // the window has not passed: nothing is looked at yet
        #expect(authors(e) == [.user])
        e.clock.advance(by: 0.1)
        e.changes.send([e.url("b.txt").path, e.url("a.txt").path])
        await waitUntil("second queued") { e.ws.pendingOutside.count == 2 }
        #expect(authors(e) == [.user])          // not yet: the window is still open
        e.clock.advance(by: 0.05)
        await e.ws.settle()
        #expect(authors(e) == [.user, .outside])
        #expect(authors(e, "b.txt") == [.user, .outside])
    }

    @Test func bashEditAttributedToSession() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.startBash()
        e.write("a.txt", "one\ntwo\nthree\nfour\n")
        await e.fire(["a.txt"])
        #expect(authors(e) == [.user, .session(s.id)])
        #expect(e.ws.ledger.files["a.txt"]?.edits.last?.toolUseID == nil)
    }

    @Test func twoBashesFallBackToOutside() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        await e.startBash(session: "A", id: "b1")
        await e.startBash(session: "B", id: "b2")
        e.write("a.txt", "different\n")
        await e.fire(["a.txt"])
        #expect(authors(e) == [.user, .outside])
    }

    @Test func untrackedNewFileIgnored() async throws {
        let e = Env(); defer { e.cleanup() }
        await e.startBash()
        e.write("new.txt", "fresh\n")
        await e.fire(["new.txt"])
        #expect(e.ws.ledger.files["new.txt"] == nil)
        // No shell running: also ignored.
        let f = Env(); defer { f.cleanup() }
        f.write("n.txt", "x\n")
        await f.fire(["n.txt"])
        #expect(f.ws.ledger.files["n.txt"] == nil)
    }

    @Test func trackedFileBashEditUsesGitBaseline() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("t.txt", "head\nline\n")
        try git(e.root, "init", "-q")
        try git(e.root, "add", "t.txt")
        try git(e.root, "commit", "-q", "-m", "init")
        let s = await e.startBash()
        e.write("t.txt", "head\nline\nadded\n")
        e.write("u.txt", "untracked\n")
        await e.fire(["t.txt", "u.txt"])
        let file = try #require(e.ws.ledger.files["t.txt"])
        // Only the added line is the session's: the baseline is HEAD's text.
        #expect(e.lineAuthors("t.txt") == [nil, nil, .session(s.id)])
        #expect(file.edits.map(\.author) == [.session(s.id)])
        #expect(file.text.text == "head\nline\nadded\n")
        #expect(e.ws.ledger.files["u.txt"] == nil)
    }

    @Test func gitHeadTreatsNonRepoAndUntrackedAsNil() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "x\n")
        #expect(await Workspace.gitHead(root: e.root, rel: "a.txt", differingFrom: "y\n") == nil)   // not a repo
        try git(e.root, "init", "-q")
        #expect(await Workspace.gitHead(root: e.root, rel: "a.txt", differingFrom: "y\n") == nil)   // untracked
        try git(e.root, "add", "a.txt")
        try git(e.root, "commit", "-q", "-m", "i")
        #expect(await Workspace.gitHead(root: e.root, rel: "a.txt", differingFrom: "y\n") == "x\n")
        #expect(await Workspace.gitHead(root: e.root, rel: "a.txt", differingFrom: "x\n") == nil)   // unchanged
    }

    @Test func deletedOpenFileReadOnly() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        let before = e.ws.ledger.files["a.txt"]
        try FileManager.default.removeItem(at: e.url("a.txt"))
        await e.fire(["a.txt"])
        #expect(doc.state == .readOnly(reason: "File was deleted outside Alloy"))
        #expect(doc.buffer.isReadOnly)
        #expect(e.ws.ledger.files["a.txt"] == before)
        // It comes back: editable again.
        e.write("a.txt", "back\n")
        await e.fire(["a.txt"])
        let again = try #require(e.ws.document("a.txt"))
        #expect(again.state == .editable)
        #expect(!again.buffer.isReadOnly)
        #expect(again.buffer.snapshot().utf8(in: 0..<again.buffer.snapshot().utf8Count) == Array("back\n".utf8))
    }

    @Test func deletedDirtyFileKeepsTypingEditable() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "typed ")
        try FileManager.default.removeItem(at: e.url("a.txt"))
        await e.fire(["a.txt"])
        #expect(doc.state == .editable)
        #expect(e.ws.notices.contains { $0.text.contains("deleted outside Alloy") && $0.path == "a.txt" && $0.kind == .warning })
        try await e.ws.save("a.txt")
        #expect(e.read("a.txt") == "typed one\n")
    }

    @Test func deletedClosedFileIgnored() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let before = e.ws.ledger.files["a.txt"]
        try FileManager.default.removeItem(at: e.url("a.txt"))
        await e.fire(["a.txt"])
        #expect(e.ws.ledger.files["a.txt"] == before)
    }

    @Test func gitPathsGoToTheHook() async throws {
        let e = Env(); defer { e.cleanup() }
        var got: [String] = []
        e.ws.gitChanged = { got += $0 }
        try FileManager.default.createDirectory(at: e.url(".git"), withIntermediateDirectories: true)
        e.write(".git/HEAD", "ref\n")
        await e.send([".git/HEAD"])
        await waitUntil("hook called") { !got.isEmpty }
        e.clock.advance(by: 0.5)                // the baseline check's window
        await e.ws.settle()
        #expect(got == [".git/HEAD"])
        #expect(e.ws.ledger.files.isEmpty)
    }

    // MARK: Open buffers

    @Test func cleanBufferFollowsOutsideEdit() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "x"); try await e.ws.save("a.txt")
        e.write("a.txt", "xone\ntwo\nthree\n")
        await e.fire(["a.txt"])
        let snap = doc.buffer.snapshot()
        #expect(String(decoding: snap.utf8(in: 0..<snap.utf8Count), as: UTF8.self) == "xone\ntwo\nthree\n")
        #expect(!doc.isDirty)
        #expect(authors(e) == [.user, .outside])
    }

    @Test func dirtyBufferMergesOutsideEditAndNamesIt() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\nthree\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(4..<7, with: "MINE")
        e.write("a.txt", "one\ntwo\nthree\nfour\n")
        await e.fire(["a.txt"])
        #expect(e.read("a.txt") == "one\nMINE\nthree\nfour\n")
        #expect(!doc.isDirty)
        #expect(e.ws.notices.isEmpty)

        _ = doc.buffer.replace(0..<3, with: "mine")
        e.write("a.txt", "ONE\nMINE\nthree\nfour\n")
        await e.fire(["a.txt"])
        #expect(e.ws.notices.contains { $0.text.contains("another change to the file") })
        #expect(e.read("a.txt").hasPrefix("mine\n"))
        #expect(authors(e).contains(.outside))
    }

    @Test func dirtyConflictNamesTheShellSession() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<3, with: "mine")
        let s = await e.startBash(session: "Ann")
        e.write("a.txt", "ONE\ntwo\n")
        await e.fire(["a.txt"])
        #expect(e.ws.notices.contains { $0.text.contains("Ann's edit") })
        #expect(e.read("a.txt").hasPrefix("mine\n"))
        #expect(authors(e).contains(.session(s.id)))
    }

    // MARK: Attribution at the Task 3 sites

    @Test func saveLoopUsesTheAttributionHelper() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "x")
        let s = await e.startBash()
        e.write("a.txt", "one\ntwo\nthree\n")      // the Bash edit, seen first by the save
        try await e.ws.save("a.txt")
        #expect(authors(e).contains(.session(s.id)))
        #expect(!authors(e).contains(.outside))
        #expect(e.read("a.txt") == "xone\ntwo\nthree\n")
    }

    @Test func refreshReconcileUsesTheAttributionHelper() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "x"); try await e.ws.save("a.txt")
        let s = await e.startBash()
        e.write("a.txt", "xone\nmore\n")
        e.ws.syncOpenBuffer("a.txt", by: nil)
        await e.ws.settle()
        #expect(authors(e) == [.user, .session(s.id)])
    }

    @Test func lateEditResultAdoptsBashAttributedRecord() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e, text: "one\ntwo\n")
        let s = await e.ws.newSession(name: "A")
        let t = try #require(e.transports.all.first)
        let old = "xone\ntwo\n", new = "xone\nTWO\n"
        // Seed the ledger with the file.
        try await e.sessionEdit("a.txt", old: "zero\ntwo\n", new: old, id: "seed")
        await e.ws.settle()
        // A Bash block runs; the watcher attributes the disk change to the session with no tool call id.
        await t.emit(.assistantBlock(messageID: "mb", block: .toolUse(id: "b1", name: "Bash", input: .object([:]))))
        await waitUntil("bash running") { e.ws.diskChangeAuthor(at: e.clock.now) == .session(s.id) }
        e.write("a.txt", new)
        await e.fire(["a.txt"])
        let count = e.ws.ledger.files["a.txt"]?.edits.count
        #expect(e.ws.ledger.files["a.txt"]?.edits.last?.author == .session(s.id))
        #expect(e.ws.ledger.files["a.txt"]?.edits.last?.toolUseID == nil)
        // The Edit tool's own result arrives late: it takes over that record instead of adding another.
        try await e.sessionEdit("a.txt", old: old, new: new, id: "late", writeDisk: false)
        await waitUntil("late result handled") { e.ws.ledger.files["a.txt"]?.edits.last?.toolUseID == "late" }
        await e.ws.settle()
        #expect(e.ws.ledger.files["a.txt"]?.edits.count == count)
        #expect(e.ws.ledger.files["a.txt"]?.edits.last?.toolUseID == "late")
    }

    // MARK: Carry-forward fixes

    @Test func openTimeReconcileRecordsDifference() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        e.write("a.txt", "changed while closed\n")
        await e.ws.open("a.txt")
        #expect(authors(e) == [.user, .outside])
        #expect(e.ws.ledger.files["a.txt"]?.text.text == "changed while closed\n")
        // The same file with a shell running is attributed to the session.
        await e.ws.close("a.txt")
        let s = await e.startBash()
        e.write("a.txt", "by bash\n")
        await e.ws.open("a.txt")
        #expect(authors(e) == [.user, .outside, .session(s.id)])
    }

    @Test func openOfMatchingFileRecordsNothing() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        await e.ws.open("a.txt")
        #expect(authors(e) == [.user])
    }

    @Test func syncGenerationNeverRepeatsAcrossReopen() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\n")
        await e.ws.open("a.txt")
        e.ws.syncOpenBuffer("a.txt", by: nil)
        let first = try #require(e.ws.syncGeneration["a.txt"])
        await e.ws.settle()
        await e.ws.close("a.txt")
        await e.ws.open("a.txt")
        e.ws.syncOpenBuffer("a.txt", by: nil)
        let second = try #require(e.ws.syncGeneration["a.txt"])
        #expect(second > first)
        // Another file's syncs do not reuse numbers either.
        e.write("b.txt", "b\n")
        await e.ws.open("b.txt")
        e.ws.syncOpenBuffer("b.txt", by: nil)
        #expect(try #require(e.ws.syncGeneration["b.txt"]) > second)
        await e.ws.settle()
    }

    @Test func invalidUTF8DocumentBecomesEditableWhenFixed() async throws {
        let e = Env(); defer { e.cleanup() }
        try Data([0x61, 0xFF, 0x62, 0x0A]).write(to: e.url("bad.txt"))
        await e.ws.open("bad.txt")
        let old = try #require(e.ws.document("bad.txt"))
        #expect(old.state == .readOnly(reason: "File is not valid UTF-8"))
        e.write("bad.txt", "fixed\n")
        await e.fire(["bad.txt"])
        let doc = try #require(e.ws.document("bad.txt"))
        #expect(doc.state == .editable)
        #expect(!doc.buffer.isReadOnly)
        let snap = doc.buffer.snapshot()
        #expect(String(decoding: snap.utf8(in: 0..<snap.utf8Count), as: UTF8.self) == "fixed\n")
        _ = doc.buffer.replace(0..<0, with: "ok ")
        try await e.ws.save("bad.txt")
        #expect(e.read("bad.txt") == "ok fixed\n")
    }

    @Test func oversizedDocumentBecomesEditableWhenShrunk() async throws {
        let e = Env(); defer { e.cleanup() }
        let big = Data(repeating: UInt8(ascii: "a"), count: Workspace.previewLimit + 10)
        try big.write(to: e.url("big.txt"))
        await e.ws.open("big.txt")
        #expect(e.ws.document("big.txt")?.state == .readOnly(reason: "File is larger than 16 MB"))
        e.write("big.txt", "small\n")
        await e.fire(["big.txt"])
        #expect(e.ws.document("big.txt")?.state == .editable)
        #expect(e.ws.document("big.txt")?.buffer.isReadOnly == false)
    }

    @Test func stillInvalidDocumentStaysReadOnlyButUpdates() async throws {
        let e = Env(); defer { e.cleanup() }
        try Data([0x61, 0xFF, 0x0A]).write(to: e.url("bad.txt"))
        await e.ws.open("bad.txt")
        try Data([0x62, 0xFE, 0x0A]).write(to: e.url("bad.txt"))
        await e.fire(["bad.txt"])
        let doc = try #require(e.ws.document("bad.txt"))
        #expect(doc.state == .readOnly(reason: "File is not valid UTF-8"))
        #expect(doc.buffer.isReadOnly)
        #expect(e.ws.ledger.files["bad.txt"] == nil)
    }

    @Test func backgroundTasksArePruned() async throws {
        let e = Env(); defer { e.cleanup() }
        for i in 0..<20 { e.write("f\(i).txt", "\(i)\n") }
        for i in 0..<20 { e.ws.openFilePath = "f\(i).txt" }
        await waitUntil("opens finished") { e.ws.backgroundCount == 0 }
        #expect(e.ws.tabs.count == 20)
        e.ws.syncOpenBuffer("f0.txt", by: nil)
        await e.ws.settle()
        #expect(e.ws.backgroundCount == 0)
    }
}
