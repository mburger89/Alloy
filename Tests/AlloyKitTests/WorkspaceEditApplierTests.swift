import AlloyCore
import AlloyLSP
@testable import AlloyKit
import Foundation
import MetalUICodeBuffer
import Testing

@MainActor
struct WorkspaceEditApplierTests {
    private func write(_ rig: Rig, _ name: String, _ text: String) throws {
        let url = rig.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ rig: Rig, _ name: String) -> String {
        (try? String(contentsOf: rig.root.appendingPathComponent(name), encoding: .utf8)) ?? "<missing>"
    }

    private func edits(_ path: String, version: Int? = nil, _ list: [(Range<Int>, String)]) -> FileEdits {
        FileEdits(path: path, version: version, edits: list.map { ByteEdit(range: $0.0, text: $0.1) })
    }

    @Test func anOpenDocumentIsEditedAsOneUndoStepAndSavedAsTheUser() async throws {
        let rig = Rig()
        try write(rig, "a.txt", "hello world\n")
        await rig.workspace.open("a.txt")
        let doc = try #require(rig.workspace.document("a.txt"))
        let applier = WorkspaceEditApplier(workspace: rig.workspace, coordinator: nil)
        let out = await applier.apply([edits("a.txt", [(0..<5, "HELLO"), (6..<11, "WORLD")])],
                                      baseVersions: ["a.txt": doc.buffer.version], label: "Format")
        #expect(out.message == nil)
        #expect(out.applied == ["a.txt"])
        #expect(read(rig, "a.txt") == "HELLO WORLD\n")
        let record = try #require(rig.workspace.ledger.files["a.txt"]?.edits.last)
        #expect(record.author == .user)
        #expect(record.group == out.group)
        let state = try #require(rig.workspace.selectionState(for: "a.txt", in: rig.workspace.defaultPane))
        #expect(state.undo())
        #expect(String(decoding: doc.buffer.snapshot().utf8(in: 0..<doc.buffer.snapshot().utf8Count), as: UTF8.self) == "hello world\n")
    }

    @Test func aClosedFileIsRewrittenKeepingItsModeWithoutOpeningATab() async throws {
        let rig = Rig()
        try write(rig, "c.txt", "one two\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: rig.root.appendingPathComponent("c.txt").path)
        try write(rig, "o.txt", "open\n")
        await rig.workspace.open("o.txt")
        let doc = try #require(rig.workspace.document("o.txt"))
        let tabs = rig.workspace.tabs(in: rig.workspace.defaultPane)
        rig.workspace.startWatching()
        let applier = WorkspaceEditApplier(workspace: rig.workspace, coordinator: nil)
        let out = await applier.apply([edits("c.txt", [(0..<3, "1"), (4..<7, "2")]), edits("o.txt", [(0..<4, "OPEN")])],
                                      baseVersions: ["o.txt": doc.buffer.version], label: "Format")
        #expect(out.message == nil)
        #expect(Set(out.applied) == ["c.txt", "o.txt"])
        #expect(read(rig, "c.txt") == "1 2\n")
        let mode = try FileManager.default.attributesOfItem(atPath: rig.root.appendingPathComponent("c.txt").path)[.posixPermissions] as? Int
        #expect(mode == 0o751)
        #expect(rig.workspace.document("c.txt") == nil)
        #expect(rig.workspace.tabs(in: rig.workspace.defaultPane) == tabs)
        let closed = try #require(rig.workspace.ledger.files["c.txt"]?.edits)
        #expect(closed.count == 1 && closed[0].author == .user && closed[0].group == out.group)
        #expect(rig.workspace.ledger.files["o.txt"]?.edits.last?.group == out.group)
        // The watcher seeing the write attributes nothing to anyone else.
        rig.changes.send([rig.root.appendingPathComponent("c.txt").path])
        for _ in 0..<100_000 where rig.clock.pendingSleepers == 0 { await Task.yield() }
        #expect(rig.clock.pendingSleepers > 0)   // the watcher's coalescing window is open
        rig.clock.advance(by: 0.15)
        await rig.workspace.settle()
        #expect(rig.workspace.ledger.files["c.txt"]?.edits.allSatisfy { $0.author == .user } == true)
    }

    @Test func aBufferThatMovedChangesNothingAnywhere() async throws {
        let rig = Rig()
        try write(rig, "a.txt", "aaa\n")
        try write(rig, "b.txt", "bbb\n")
        await rig.workspace.open("a.txt")
        let doc = try #require(rig.workspace.document("a.txt"))
        let base = doc.buffer.version
        _ = doc.buffer.replace(0..<0, with: "x")
        let applier = WorkspaceEditApplier(workspace: rig.workspace, coordinator: nil)
        let out = await applier.apply([edits("b.txt", [(0..<3, "B")]), edits("a.txt", [(0..<3, "A")])],
                                      baseVersions: ["a.txt": base], label: "Format")
        #expect(out.message == "File changed, Format not applied")
        #expect(out.applied.isEmpty)
        #expect(read(rig, "b.txt") == "bbb\n")
        #expect(read(rig, "a.txt") == "aaa\n")
    }

    @Test func aClosedFileChangedAfterValidationChangesNothing() async throws {
        let rig = Rig()
        try write(rig, "a.txt", "aaa\n")
        try write(rig, "b.txt", "bbb\n")
        await rig.workspace.open("a.txt")
        let doc = try #require(rig.workspace.document("a.txt"))
        let applier = WorkspaceEditApplier(workspace: rig.workspace, coordinator: nil)
        applier.afterValidation = { try? "bbbb\n".write(to: rig.root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8) }
        let out = await applier.apply([edits("a.txt", [(0..<3, "A")]), edits("b.txt", [(0..<3, "B")])],
                                      baseVersions: ["a.txt": doc.buffer.version], label: "Format")
        #expect(out.message == "File changed, Format not applied")
        #expect(read(rig, "a.txt") == "aaa\n")
        #expect(read(rig, "b.txt") == "bbbb\n")
        #expect(!doc.isDirty)
    }

    @Test func partialFailureReportsAndKeepsWhatWasApplied() async throws {
        let rig = Rig()
        try write(rig, "ok.txt", "aaa\n")
        try write(rig, "ro/x.txt", "xxx\n")
        try write(rig, "ro/y.txt", "yyy\n")
        let dir = rig.root.appendingPathComponent("ro").path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        let applier = WorkspaceEditApplier(workspace: rig.workspace, coordinator: nil)
        let out = await applier.apply([edits("ok.txt", [(0..<3, "A")]), edits("ro/x.txt", [(0..<3, "X")]),
                                       edits("ro/y.txt", [(0..<3, "Y")])], baseVersions: [:], label: "Rename")
        #expect(out.applied == ["ok.txt"])
        #expect(Set(out.failed.keys) == ["ro/x.txt", "ro/y.txt"])
        let message = try #require(out.message)
        #expect(message.hasPrefix("Rename applied to 1 of 3 files; 2 failed: "))
        #expect(read(rig, "ok.txt") == "A\n")
        #expect(read(rig, "ro/x.txt") == "xxx\n")
    }
}
