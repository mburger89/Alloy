@testable import AlloyCore
import MetalUICodeBuffer
import Foundation
import Testing

@MainActor @Suite struct DirtyMergeTests {
    private static let ten = (1...12).map { "line\($0)\n" }.joined()

    @Test func dirtyMergeKeepsUserText() async throws {
        let e = Env(); defer { e.cleanup() }
        let old = Self.ten
        e.write("a.txt", old)
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = await e.ws.newSession(name: "Ann")
        let sessionID = try #require(e.ws.sessions.first).id
        // The user types on line 2 and has not saved.
        let line2 = old.range(of: "line2")!.upperBound.utf16Offset(in: old)
        _ = doc.buffer.replace(line2..<line2, with: " typed")
        #expect(doc.isDirty)
        let new = old.replacingOccurrences(of: "line10", with: "LINE10")
        try await e.sessionEdit("a.txt", old: old, new: new)
        await waitUntil("ledger") { e.ws.ledger.files["a.txt"] != nil }
        await e.ws.settle()
        let merged = new.replacingOccurrences(of: "line2", with: "line2 typed")
        #expect(doc.buffer.snapshot().text == merged)
        #expect(e.read("a.txt") == merged)
        #expect(!doc.isDirty)
        let authors = e.lineAuthors("a.txt")
        #expect(authors[9] == .session(sessionID))
        #expect(authors[1] == .user)
        #expect(e.ws.notices.isEmpty)
    }

    @Test func overlapKeepsUserVersion() async throws {
        let e = Env(); defer { e.cleanup() }
        let old = Self.ten
        e.write("a.txt", old)
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = await e.ws.newSession(name: "Ann")
        let at = old.range(of: "line5")!.upperBound.utf16Offset(in: old)
        _ = doc.buffer.replace(at..<at, with: " mine")
        let new = old.replacingOccurrences(of: "line5", with: "LINE5 theirs")
        try await e.sessionEdit("a.txt", old: old, new: new)
        await waitUntil("ledger") { e.ws.ledger.files["a.txt"] != nil }
        await e.ws.settle()
        let mine = old.replacingOccurrences(of: "line5", with: "line5 mine")
        #expect(doc.buffer.snapshot().text == mine)
        #expect(e.read("a.txt") == mine)
        #expect(!doc.isDirty)
        let text = "Your unsaved edit in a.txt overlaps Ann's edit at lines 5\u{2013}5; your text was kept."
        #expect(e.ws.notices == [Notice(path: "a.txt", kind: .warning, text: text)])
        let s = try #require(e.ws.sessions.first)
        #expect(s.transcript.blocks.contains { if case .notice(_, _, let t) = $0 { return t == text } else { return false } })
        // The ledger holds the session's edit, then the user's edit that reverses it.
        let file = try #require(e.ws.ledger.files["a.txt"])
        #expect(file.edits.last?.author == .user)
        #expect(file.text.text == mine)
    }

    @Test func mixedHunksApplyOnlyTheCleanOnes() async throws {
        let e = Env(); defer { e.cleanup() }
        let old = Self.ten
        e.write("a.txt", old)
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = await e.ws.newSession(name: "Ann")
        let at = old.range(of: "line3")!.upperBound.utf16Offset(in: old)
        _ = doc.buffer.replace(at..<at, with: "!")
        let new = old.replacingOccurrences(of: "line3", with: "L3").replacingOccurrences(of: "line8", with: "L8")
        try await e.sessionEdit("a.txt", old: old, new: new)
        await waitUntil("ledger") { e.ws.ledger.files["a.txt"] != nil }
        await e.ws.settle()
        let expected = old.replacingOccurrences(of: "line3", with: "line3!").replacingOccurrences(of: "line8", with: "L8")
        #expect(doc.buffer.snapshot().text == expected)
        #expect(e.read("a.txt") == expected)
        #expect(e.ws.notices.count == 1 && e.ws.notices[0].text.contains("lines 3\u{2013}3"))
    }

    @Test func manyUserEditsDoNotMakeSessionHunksConflict() async throws {
        let e = Env(); defer { e.cleanup() }
        let old = Self.ten
        e.write("a.txt", old)
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = await e.ws.newSession(name: "Ann")
        // 320 single-character edits on line 2 (past the buffer's 256-event minimum log).
        var at = old.range(of: "line2")!.upperBound.utf16Offset(in: old)
        for _ in 0..<320 { _ = doc.buffer.replace(at..<at, with: "x"); at += 1 }
        let new = old.replacingOccurrences(of: "line10", with: "LINE10")
        try await e.sessionEdit("a.txt", old: old, new: new)
        await waitUntil("ledger") { e.ws.ledger.files["a.txt"] != nil }
        await e.ws.settle()
        let merged = new.replacingOccurrences(of: "line2", with: "line2" + String(repeating: "x", count: 320))
        #expect(doc.buffer.snapshot().text == merged)
        #expect(e.read("a.txt") == merged)
        #expect(e.ws.notices.isEmpty)
    }

    @Test func manyUserEditsDoNotMakeCursorMergeConflict() {
        let old = (1...12).map { "l\($0)\n" }.joined()
        let b = CodeBuffer(old), v = b.version, cursor = b.makeEditCursor()
        for _ in 0..<320 { _ = b.replace(2..<2, with: "x") }
        let out = DirtyMerge.merge(buffer: b, savedVersion: v, oldDisk: old,
                                   newDisk: old.replacingOccurrences(of: "l10", with: "L10"), cursor: cursor)
        #expect(out == MergeOutcome(applied: 1, conflicts: []))
    }

    @Test func typingAtColumnZeroOfTheNextLineIsNotAConflict() {
        let old = "a\nb\nc\n"
        let b = CodeBuffer(old), v = b.version, cursor = b.makeEditCursor()
        _ = b.replace(4..<4, with: "!")      // column 0 of "c"
        let out = DirtyMerge.merge(buffer: b, savedVersion: v, oldDisk: old, newDisk: "a\nB\nc\n", cursor: cursor)
        #expect(out == MergeOutcome(applied: 1, conflicts: []))
        #expect(b.snapshot().text == "a\nB\n!c\n")
    }

    // MARK: Save racing a session edit

    @Test func sessionEditDuringAnInFlightSaveKeepsBoth() async throws {
        let e = Env(); defer { e.cleanup() }
        let old = Self.ten
        e.write("a.txt", old)
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = await e.ws.newSession(name: "Ann")
        let sessionID = try #require(e.ws.sessions.first).id
        let at = old.range(of: "line2")!.upperBound.utf16Offset(in: old)
        _ = doc.buffer.replace(at..<at, with: " typed")
        let gate = TestGate()
        e.ws.closeGate = { _ in await gate.hold() }
        let saver = Task { try await e.ws.save("a.txt") }
        await gate.waitUntilEntered()               // the save has its snapshot and has not written
        let new = old.replacingOccurrences(of: "line10", with: "LINE10")
        try await e.sessionEdit("a.txt", old: old, new: new)
        await waitUntil("ledger") { e.ws.ledger.files["a.txt"] != nil }
        await gate.release()
        try await saver.value
        await e.ws.settle()
        let merged = new.replacingOccurrences(of: "line2", with: "line2 typed")
        #expect(e.read("a.txt") == merged)
        #expect(doc.buffer.snapshot().text == merged)
        #expect(!doc.isDirty)
        let file = try #require(e.ws.ledger.files["a.txt"])
        #expect(file.text.text == merged)
        let authors = e.lineAuthors("a.txt")
        #expect(authors[9] == .session(sessionID))
        #expect(authors[1] == .user)
    }

    @Test func renameBeforeTheToolResultDoesNotReverseTheSessionEdit() async throws {
        let e = Env(); defer { e.cleanup() }
        let old = Self.ten
        e.write("a.txt", old)
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = await e.ws.newSession(name: "Ann")
        let at = old.range(of: "line2")!.upperBound.utf16Offset(in: old)
        _ = doc.buffer.replace(at..<at, with: " typed")
        // The CLI has written the file, but its tool result has not reached Alloy yet.
        let new = old.replacingOccurrences(of: "line10", with: "LINE10")
        e.write("a.txt", new)
        try await e.ws.save("a.txt")
        let merged = new.replacingOccurrences(of: "line2", with: "line2 typed")
        #expect(e.read("a.txt") == merged)
        // Now the tool result arrives.
        try await e.sessionEdit("a.txt", old: old, new: new, writeDisk: false)
        await waitUntil("session record") { e.ws.ledger.files["a.txt"]?.edits.contains { if case .session = $0.author { return true } else { return false } } == true }
        await e.ws.settle()
        #expect(e.read("a.txt") == merged)
        #expect(doc.buffer.snapshot().text == merged)
        let file = try #require(e.ws.ledger.files["a.txt"])
        #expect(file.text.text == merged)
        // The late tool result adopts the outside record: the user's typing is theirs, line 10 the session's.
        let sessionID = try #require(e.ws.sessions.first).id
        #expect(!file.edits.contains { $0.author == .outside })
        #expect(file.edits.map(\.author) == [.session(sessionID), .user])
        let authors = e.lineAuthors("a.txt")
        #expect(authors[1] == .user)
        #expect(authors[9] == .session(sessionID))
    }

    @Test func overlappingMergesReportNoFalseConflict() async throws {
        let e = Env(); defer { e.cleanup() }
        let old = Self.ten
        e.write("a.txt", old)
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = await e.ws.newSession(name: "Ann")
        let at = old.range(of: "line2")!.upperBound.utf16Offset(in: old)
        _ = doc.buffer.replace(at..<at, with: " typed")
        // The refresh merge is held before it merges; the save then merges the same disk text and is held in its
        // second pass; releasing the refresh merge must not find its hunks already applied.
        let refreshHold = TestGate(), saveHold = TestGate()
        e.ws.refreshGate = { _, _ in await refreshHold.hold() }
        let calls = CallCounter()
        e.ws.closeGate = { _ in if await calls.next() == 2 { await saveHold.hold() } }
        let new = old.replacingOccurrences(of: "line10", with: "LINE10")
        try await e.sessionEdit("a.txt", old: old, new: new)
        await refreshHold.waitUntilEntered()
        let saver = Task { try await e.ws.save("a.txt") }
        await saveHold.waitUntilEntered()
        await refreshHold.release()
        for _ in 0..<200 { await Task.yield() }
        await saveHold.release()
        try await saver.value
        await e.ws.settle()
        let merged = new.replacingOccurrences(of: "line2", with: "line2 typed")
        #expect(e.ws.notices.isEmpty)
        #expect(e.read("a.txt") == merged)
        #expect(doc.buffer.snapshot().text == merged)
        #expect(!doc.isDirty)
    }

    // MARK: Unit

    private func fixture(_ old: String) -> (CodeBuffer, UInt64, CodeEditCursor) {
        let b = CodeBuffer(old)
        return (b, b.version, b.makeEditCursor())
    }

    @Test func hunksCarryByteRanges() {
        let h = DirtyMerge.hunks(oldDisk: "a\nbé\nc\n", newDisk: "a\nB\nc\nd\n")
        #expect(h.count == 2)
        #expect(h[0].oldBytes == 2..<6 && h[0].newText == "B\n" && h[0].newLines == 2...2)
        #expect(h[1].oldBytes == 8..<8 && h[1].newText == "d\n" && h[1].newLines == 4...4)
    }

    @Test func finalNewlineChangeIsAHunk() {
        let h = DirtyMerge.hunks(oldDisk: "a\nb", newDisk: "a\nb\n")
        #expect(h.count == 1 && h[0].oldBytes == 2..<3 && h[0].newText == "b\n")
    }

    @Test func nonOverlappingUserEditMerges() {
        let old = "a\nb\nc\nd\n"
        let (buf, v, cursor) = fixture(old)
        _ = buf.replace(0..<0, with: "XX")
        let out = DirtyMerge.merge(buffer: buf, savedVersion: v, oldDisk: old, newDisk: "a\nb\nC\nd\n", cursor: cursor)
        #expect(out == MergeOutcome(applied: 1, conflicts: []))
        #expect(buf.snapshot().text == "XXa\nb\nC\nd\n")
    }

    @Test func overlappingUserEditIsAConflictAndKept() {
        let old = "a\nb\nc\nd\n"
        let (buf, v, cursor) = fixture(old)
        _ = buf.replace(4..<4, with: "!")   // inside "c"
        let out = DirtyMerge.merge(buffer: buf, savedVersion: v, oldDisk: old, newDisk: "a\nb\nC\nd\n", cursor: cursor)
        #expect(out == MergeOutcome(applied: 0, conflicts: [3...3]))
        #expect(buf.snapshot().text == "a\nb\n!c\nd\n")
    }

    @Test func userDeletionInsideAHunkConflicts() {
        let old = "a\nbbb\nc\n"
        let (buf, v, cursor) = fixture(old)
        _ = buf.replace(3..<5, with: "")
        let out = DirtyMerge.merge(buffer: buf, savedVersion: v, oldDisk: old, newDisk: "a\nBBB\nc\n", cursor: cursor)
        #expect(out.conflicts == [2...2] && out.applied == 0)
    }

    @Test func typingAtTheEndOfThePreviousLineIsNotAnOverlap() {
        let old = "a\nb\nc\n"
        let (buf, v, cursor) = fixture(old)
        _ = buf.replace(1..<1, with: "!")   // end of "a", before its newline
        let out = DirtyMerge.merge(buffer: buf, savedVersion: v, oldDisk: old, newDisk: "a\nB\nc\n", cursor: cursor)
        #expect(out == MergeOutcome(applied: 1, conflicts: []))
        #expect(buf.snapshot().text == "a!\nB\nc\n")
    }

    @Test func manyUserEditsStillMapForward() {
        let old = (1...6).map { "l\($0)\n" }.joined()
        let (buf, v, cursor) = fixture(old)
        _ = buf.replace(0..<0, with: "top\n")
        _ = buf.replace(buf.snapshot().utf8Count..<buf.snapshot().utf8Count, with: "end\n")
        let out = DirtyMerge.merge(buffer: buf, savedVersion: v, oldDisk: old,
                                   newDisk: old.replacingOccurrences(of: "l3", with: "L3"), cursor: cursor)
        #expect(out.applied == 1)
        #expect(buf.snapshot().text == "top\nl1\nl2\nL3\nl4\nl5\nl6\nend\n")
    }
}
