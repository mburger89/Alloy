import Foundation
import Testing
@testable import AlloyCore

private func hunks(_ old: String, _ new: String) -> [PatchHunk] {
    Patch.diff(old: TextLines(old).lines, new: TextLines(new).lines)
}

@Suite struct ProjectLedgerTests {
    let a = UUID(), b = UUID()
    var A: Author { .session(a) }
    var B: Author { .session(b) }
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    }

    private func edit(_ ledger: inout ProjectLedger, _ rel: String, _ old: String, _ new: String, _ author: Author) -> [EditRecord] {
        ledger.record(.edit(filePath: root.appendingPathComponent(rel).path, originalFile: old, hunks: hunks(old, new)),
                      author: author, toolUseID: "t", date: Date(timeIntervalSince1970: 5))
    }

    @Test func recordIgnoresPathsOutsideRoot() {
        var p = ProjectLedger(projectRoot: root)
        let r = p.record(.edit(filePath: "/etc/hosts", originalFile: "a\n", hunks: hunks("a\n", "b\n")),
                         author: A, toolUseID: nil, date: Date())
        #expect(r.isEmpty)
        #expect(p.files.isEmpty)
        #expect(p.record(.message("x"), author: A, toolUseID: nil, date: Date()).isEmpty)
        #expect(p.record(.none, author: A, toolUseID: nil, date: Date()).isEmpty)
    }

    @Test func recordUsesRelativePaths() {
        var p = ProjectLedger(projectRoot: root)
        let r = edit(&p, "Sources/a.swift", "1\n2\n", "1\nX\n", A)
        #expect(r.count == 1)
        #expect(r[0].path == "Sources/a.swift")
        #expect(p.files["Sources/a.swift"]?.text.text == "1\nX\n")
    }

    @Test func writeCreateOwnsEverything() {
        var p = ProjectLedger(projectRoot: root)
        let path = root.appendingPathComponent("new.txt").path
        let r = p.record(.write(filePath: path, isCreate: true, content: "a\nb\n", originalFile: nil, hunks: []),
                         author: A, toolUseID: nil, date: Date())
        #expect(r.count == 1)
        #expect(p.files["new.txt"]?.lineOwners() == [r[0].id, r[0].id])
    }

    @Test func writeUpdateWithTrailingNewlineChangeLeavesOneRecord() {
        var p = ProjectLedger(projectRoot: root)
        let path = root.appendingPathComponent("w.txt").path
        let r = p.record(.write(filePath: path, isCreate: false, content: "a\nb\n", originalFile: "a\nb",
                                hunks: hunks("a\nb", "a\nb\n")),
                         author: A, toolUseID: "tool-1", date: Date())
        #expect(p.files["w.txt"]?.text.text == "a\nb\n")
        #expect(r.count == 1)
        #expect(r[0].toolUseID == "tool-1")
        #expect(p.files["w.txt"]?.edits.count == 1)
        #expect(p.files["w.txt"]?.edits.filter { $0.author == A && $0.toolUseID == "tool-1" }.count == 1)
    }

    @Test func changedFilesListsDistinctAuthorsInOrder() {
        var p = ProjectLedger(projectRoot: root)
        _ = edit(&p, "b.txt", "1\n", "2\n", A)
        _ = edit(&p, "a.txt", "1\n2\n3\n", "1\nX\n3\n", A)
        _ = edit(&p, "a.txt", "1\nX\n3\n", "1\nX\nY\n", B)
        _ = edit(&p, "a.txt", "1\nX\nY\n", "1\nX\nZ\n", A)
        #expect(p.changedFiles() == [ChangedFile(path: "a.txt", authors: [A, B]), ChangedFile(path: "b.txt", authors: [A])])
    }

    @Test func keepRemovesFileFromChangedFiles() {
        var p = ProjectLedger(projectRoot: root)
        let r = edit(&p, "a.txt", "1\n", "2\n", A)
        p.files["a.txt"]!.keep(r[0].id)
        #expect(p.changedFiles().isEmpty)
    }

    @Test func recordFallsBackToDiskOnBadHunks() throws {
        var p = ProjectLedger(projectRoot: root)
        let url = root.appendingPathComponent("Sources/c.swift")
        try "1\nREAL\n3\n".write(to: url, atomically: true, encoding: .utf8)
        let bad = [PatchHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-nope", "+X"])]
        let r = p.record(.edit(filePath: url.path, originalFile: "1\n2\n3\n", hunks: bad), author: A, toolUseID: "t", date: Date())
        #expect(p.files["Sources/c.swift"]?.text.text == "1\nREAL\n3\n")
        #expect(r.last?.author == A)
        #expect(!r.isEmpty)
    }

    @Test func saveLoadRoundTrip() throws {
        var p = ProjectLedger(projectRoot: root)
        _ = edit(&p, "a.txt", "1\n2\n", "1\nX\n", A)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)/ledger.json")
        try p.save(to: url)
        #expect(try ProjectLedger.load(from: url) == p)
        let support = URL(fileURLWithPath: "/tmp/support")
        let s1 = ProjectLedger.storeURL(projectRoot: root, appSupport: support)
        #expect(s1 == ProjectLedger.storeURL(projectRoot: root, appSupport: support))
        #expect(s1 != ProjectLedger.storeURL(projectRoot: root.appendingPathComponent("other"), appSupport: support))
        #expect(s1.lastPathComponent == "ledger.json")
        #expect(s1.deletingLastPathComponent().lastPathComponent.count == 16)
        #expect(s1.path.hasPrefix("/tmp/support/Alloy/Projects/"))
    }

    @Test func saveLoadPreservesIdentity() throws {
        var p = ProjectLedger(projectRoot: root)
        let e = edit(&p, "a.txt", "1\n2\n3\n", "1\nX\n3\n", A)[0].id
        _ = edit(&p, "a.txt", "1\nX\n3\n", "top\n1\nX\n3\n", B)
        let anchor = p.files["a.txt"]!.anchor(atOffset: 6, bias: .right)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)/l.json")
        try p.save(to: url)
        var loaded = try ProjectLedger.load(from: url)
        let direct = p.files["a.txt"]!.revertOutcomeForTest(e)
        let viaDisk = loaded.files["a.txt"]!.revertOutcomeForTest(e)
        #expect(direct == viaDisk)
        guard case .reverted(let text) = direct else { Issue.record("expected revert"); return }
        #expect(text == "top\n1\n2\n3\n")
        #expect(loaded.files["a.txt"]!.offset(of: anchor) == p.files["a.txt"]!.offset(of: anchor))
        _ = loaded.files["a.txt"]!.revert(e, date: Date())
        #expect(loaded.files["a.txt"]!.text.text == text)
    }
}

extension FileLedger {
    fileprivate func revertOutcomeForTest(_ id: UUID) -> RevertOutcome {
        var copy = self
        return copy.revert(id, date: Date(timeIntervalSince1970: 9))
    }
}
