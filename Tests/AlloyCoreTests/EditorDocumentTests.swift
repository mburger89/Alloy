@testable import AlloyCore
import MetalUICodeBuffer
import AlloyTestSupport
import Foundation
import Testing

@MainActor @Suite struct EditorDocumentTests {
    @Test func openCreatesTabAndBuffer() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.swift", "let x = 1\n")
        await e.ws.open("a.swift")
        #expect(e.ws.tabs == ["a.swift"])
        #expect(e.ws.activeTab == "a.swift")
        let doc = try #require(e.ws.document("a.swift"))
        #expect(doc.buffer.snapshot().text == "let x = 1\n")
        #expect(doc.state == .editable)
        #expect(doc.language == "swift")
        #expect(!doc.isDirty)
    }

    @Test func openTwiceReusesTab() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.swift", "a"); e.write("b.swift", "b")
        await e.ws.open("a.swift")
        let first = try #require(e.ws.document("a.swift"))
        await e.ws.open("b.swift")
        await e.ws.open("a.swift")
        #expect(e.ws.tabs == ["a.swift", "b.swift"])
        #expect(e.ws.activeTab == "a.swift")
        #expect(e.ws.document("a.swift") === first)
    }

    @Test func closeSavesDirtyFirst() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "hello")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "big ")
        #expect(doc.isDirty)
        await e.ws.close("a.txt")
        #expect(try String(contentsOf: e.root.appendingPathComponent("a.txt"), encoding: .utf8) == "big hello")
        #expect(e.ws.tabs.isEmpty)
        #expect(e.ws.activeTab == nil)
        #expect(e.ws.document("a.txt") == nil)
    }

    @Test func closingActiveTabActivatesRightThenLeft() async {
        let e = Env(); defer { e.cleanup() }
        for n in ["a", "b", "c"] { e.write(n, n); await e.ws.open(n) }
        e.ws.activeTab = "b"
        await e.ws.close("b")
        #expect(e.ws.activeTab == "c")
        await e.ws.close("c")
        #expect(e.ws.activeTab == "a")
    }

    @Test func binaryFileNoDocument() async throws {
        let e = Env(); defer { e.cleanup() }
        try Data([0x41, 0, 0x42]).write(to: e.root.appendingPathComponent("b.bin"))
        await e.ws.open("b.bin")
        #expect(e.ws.tabs == ["b.bin"])
        #expect(e.ws.document("b.bin") == nil)
        #expect(e.ws.tabMessages["b.bin"] == "Binary file")
    }

    @Test func nonUTF8ReadOnly() async throws {
        let e = Env(); defer { e.cleanup() }
        try Data([0x61, 0xFF, 0x62]).write(to: e.root.appendingPathComponent("l.txt"))
        await e.ws.open("l.txt")
        let doc = try #require(e.ws.document("l.txt"))
        #expect(doc.state == .readOnly(reason: "File is not valid UTF-8"))
        #expect(doc.buffer.isReadOnly)
    }

    @Test func oversizeFileShowsFirst16MBReadOnly() async throws {
        let e = Env(); defer { e.cleanup() }
        // 16 MB of "é" (2 bytes) plus one byte puts the cut mid-scalar for odd limits; use 3-byte scalars.
        let unit = Data("€".utf8)
        var data = Data(); data.reserveCapacity(Workspace.previewLimit + 8)
        while data.count < Workspace.previewLimit + 3 { data.append(unit) }
        try data.write(to: e.root.appendingPathComponent("big.txt"))
        await e.ws.open("big.txt")
        let doc = try #require(e.ws.document("big.txt"))
        #expect(doc.state == .readOnly(reason: "File is larger than 16 MB"))
        #expect(doc.buffer.snapshot().utf8Count <= Workspace.previewLimit)
        #expect(!doc.buffer.hadInvalidUTF8)
    }

    @Test func openFilePathAliasStillWorks() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.swift", "x")
        e.ws.openFilePath = "a.swift"
        #expect(e.ws.activeTab == "a.swift")
        #expect(e.ws.openFilePath == "a.swift")
        await waitUntil("document") { e.ws.document("a.swift") != nil }
        #expect(e.ws.tabs == ["a.swift"])
    }

    @Test func sessionEditUpdatesCleanBuffer() async throws {
        let e = Env(); defer { e.cleanup() }
        let old = "a\nb\nc\n", new = "a\nB\nc\n"
        e.write("a.txt", old)
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = await e.ws.newSession(name: "A")
        let file = e.root.appendingPathComponent("a.txt")
        e.write("a.txt", new)
        let o = TextLines(old).lines, n = TextLines(new).lines
        let hunk = PatchHunk(oldStart: 1, oldLines: o.count, newStart: 1, newLines: n.count,
                             lines: o.map { "-" + $0 } + n.map { "+" + $0 })
        let t = try #require(e.transports.all.first)
        await t.emit(.assistantBlock(messageID: "m", block: .toolUse(id: "t1", name: "Edit", input: .object([:]))))
        await t.emit(.toolResult(ToolResultMessage(toolUseID: "t1", isError: false, text: "ok",
                                                   result: .edit(filePath: file.path, originalFile: old, hunks: [hunk]))))
        await waitUntil("ledger") { e.ws.ledger.files["a.txt"] != nil }
        await e.ws.settle()
        #expect(doc.buffer.snapshot().text == new)
        #expect(!doc.isDirty)
        #expect(!doc.buffer.canUndo)
    }

    @Test func typingDuringCloseKeepsTabAndText() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "hello")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "1")
        let gate = TestGate()
        e.ws.closeGate = { _ in await gate.hold() }
        let closer = Task { await e.ws.close("a.txt") }
        await gate.waitUntilEntered()
        _ = doc.buffer.replace(0..<0, with: "2")
        await gate.release()
        await closer.value
        #expect(e.ws.tabs == ["a.txt"])
        #expect(doc.buffer.snapshot().text == "21hello")
        #expect(doc.isDirty)
    }

    @Test func concurrentClosesRemoveTheTabOnce() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a", "a"); e.write("b", "b")
        await e.ws.open("a"); await e.ws.open("b")
        _ = try #require(e.ws.document("a")).buffer.replace(0..<0, with: "x")
        let c1 = Task { await e.ws.close("a") }, c2 = Task { await e.ws.close("a") }
        await c1.value; await c2.value
        #expect(e.ws.tabs == ["b"])
        #expect(try String(contentsOf: e.root.appendingPathComponent("a"), encoding: .utf8) == "xa")
    }

    @Test func openDuringCloseKeepsTheTab() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a", "a")
        await e.ws.open("a")
        _ = try #require(e.ws.document("a")).buffer.replace(0..<0, with: "x")
        let gate = TestGate()
        e.ws.closeGate = { _ in await gate.hold() }
        let closer = Task { await e.ws.close("a") }
        await gate.waitUntilEntered()
        await e.ws.open("a")
        await gate.release()
        await closer.value
        #expect(e.ws.tabs == ["a"])
        #expect(e.ws.activeTab == "a")
    }

    @Test func readOnlyDocumentRefreshesFromDisk() async throws {
        let e = Env(); defer { e.cleanup() }
        try Data([0x61, 0xFF, 0x0A, 0x62]).write(to: e.root.appendingPathComponent("l.txt"))
        await e.ws.open("l.txt")
        let doc = try #require(e.ws.document("l.txt"))
        _ = await e.ws.newSession(name: "A")
        try Data([0x61, 0xFF, 0x0A, 0x63]).write(to: e.root.appendingPathComponent("l.txt"))
        let hunk = PatchHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-x", "+y"])
        let t = try #require(e.transports.all.first)
        await t.emit(.assistantBlock(messageID: "m", block: .toolUse(id: "t1", name: "Edit", input: .object([:]))))
        await t.emit(.toolResult(ToolResultMessage(toolUseID: "t1", isError: false, text: "ok",
                                                   result: .edit(filePath: e.root.appendingPathComponent("l.txt").path,
                                                                 originalFile: "x\n", hunks: [hunk]))))
        await waitUntil("ledger") { e.ws.ledger.files["l.txt"] != nil }
        await e.ws.settle()
        #expect(doc.buffer.snapshot().text.hasSuffix("c"))
        #expect(doc.buffer.isReadOnly)
        #expect(!doc.isDirty)
    }

    @Test func olderRefreshCompletingLastDoesNotOverwriteNewerText() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "a\nb\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = await e.ws.newSession(name: "A")
        let t = try #require(e.transports.all.first)
        let file = e.root.appendingPathComponent("a.txt")
        let v1 = "a\nB1\n", v2 = "a\nBB22\n"
        let gate = TestGate()
        e.ws.refreshGate = { _, bytes in if String(decoding: bytes, as: UTF8.self) == v1 { await gate.hold() } }
        func edit(_ id: String, old: String, new: String) async {
            let o = TextLines(old).lines, n = TextLines(new).lines
            let hunk = PatchHunk(oldStart: 1, oldLines: o.count, newStart: 1, newLines: n.count,
                                 lines: o.map { "-" + $0 } + n.map { "+" + $0 })
            await t.emit(.assistantBlock(messageID: "m" + id, block: .toolUse(id: id, name: "Edit", input: .object([:]))))
            await t.emit(.toolResult(ToolResultMessage(toolUseID: id, isError: false, text: "ok",
                                                       result: .edit(filePath: file.path, originalFile: old, hunks: [hunk]))))
        }
        e.write("a.txt", v1)
        await edit("t1", old: "a\nb\n", new: v1)
        await gate.waitUntilEntered()
        e.write("a.txt", v2)
        await edit("t2", old: v1, new: v2)
        await waitUntil("newer applied") { doc.buffer.snapshot().text == v2 }
        let stamp = doc.diskStamp
        #expect(stamp.size == v2.utf8.count)
        await gate.release()
        await e.ws.settle()
        #expect(doc.buffer.snapshot().text == v2)
        #expect(doc.diskStamp == stamp)
        #expect(!doc.isDirty)
    }

    // MARK: replacementEdit

    private func edit(_ old: String, _ new: String) -> (Range<Int>, String)? {
        let snap = CodeBuffer(old).snapshot()
        return Workspace.replacementEdit(old: snap, newBytes: Array(new.utf8)).map { ($0.range, $0.text) }
    }

    @Test func replacementEditIdenticalIsNil() { #expect(edit("abc\n", "abc\n") == nil) }

    @Test func replacementEditEmptyOldInsertsAll() {
        let r = edit("", "hi"); #expect(r?.0 == 0..<0); #expect(r?.1 == "hi")
    }

    @Test func replacementEditEmptyNewDeletesAll() {
        let r = edit("hi", ""); #expect(r?.0 == 0..<2); #expect(r?.1 == "")
    }

    @Test func replacementEditSharedLeadByteStaysOnScalarBoundary() {
        // "é" is C3 A9 and "è" is C3 A8: the common prefix must not split the scalar.
        let r = edit("é", "è"); #expect(r?.0 == 0..<2); #expect(r?.1 == "è")
        let r2 = edit("aé", "aè"); #expect(r2?.0 == 1..<3); #expect(r2?.1 == "è")
    }

    @Test func replacementEditSharedTrailingBytesStayOnScalarBoundary() {
        // "x€" vs "y€" share the whole 3-byte suffix.
        let r = edit("x€", "y€"); #expect(r?.0 == 0..<1); #expect(r?.1 == "y")
        // U+2082 (E2 82 82) vs U+20AC (E2 82 AC): only the last byte differs, nothing shared at the suffix.
        let r2 = edit("\u{2082}", "\u{20AC}"); #expect(r2?.0 == 0..<3); #expect(r2?.1 == "\u{20AC}")
        // Same final byte, different scalar: U+20AC (E2 82 AC) vs U+00AC (C2 AC).
        let r3 = edit("\u{20AC}", "\u{00AC}"); #expect(r3?.0 == 0..<3); #expect(r3?.1 == "\u{00AC}")
    }

    @Test func replacementEditInsertionInTheMiddle() {
        let r = edit("abcd", "abXYcd"); #expect(r?.0 == 2..<2); #expect(r?.1 == "XY")
    }
}
