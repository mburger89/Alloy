@testable import AlloyCore
import Foundation
import Testing

@Suite struct GitStatusParserTests {
    private func parse(_ fields: [String], prefix: String = "") -> GitStatus {
        GitStatusParser.parse(Data((fields.joined(separator: "\0") + "\0").utf8), prefix: prefix)
    }

    private let h = "1111111111111111111111111111111111111111"
    private let i = "2222222222222222222222222222222222222222"

    @Test func ordinaryEntry() {
        let s = parse(["1 .M N... 100644 100644 100644 \(h) \(i) a.txt"])
        let e = s.entries["a.txt"]
        #expect(e?.worktree == "M" && e?.index == ".")
        #expect(e?.display == .modified && e?.isStaged == false && e?.hasWorktreeChange == true)
        #expect(e?.headOID == h && e?.indexOID == i && e?.worktreeMode == "100644")
    }

    @Test func renameTakesOriginalFromNextField() {
        let s = parse(["2 R. N... 100644 100644 100644 \(h) \(i) R100 new name.txt", "old.txt", "? z"])
        let e = s.entries["new name.txt"]
        #expect(e?.origPath == "old.txt" && e?.kind == .renamed && e?.display == .renamed && e?.isStaged == true)
        #expect(s.entries["z"]?.kind == .untracked)
    }

    @Test func unmergedUntrackedIgnored() {
        let s = parse(["u UU N... 100644 100644 100644 100644 \(h) \(h) \(i) c.txt", "? -dash file.txt", "! build/"])
        #expect(s.entries["c.txt"]?.display == .conflicted)
        #expect(s.entries["-dash file.txt"]?.display == .untracked)
        #expect(s.entries["build/"]?.display == .ignored)
    }

    @Test func unicodeNamesAndSubmodule() {
        let s = parse(["1 .M S.M. 160000 160000 160000 \(h) \(h) sub", "? caf\u{e9} \u{1F600}.txt"])
        #expect(s.entries["sub"]?.isSubmodule == true)
        #expect(s.entries["caf\u{e9} \u{1F600}.txt"] != nil)
    }

    @Test func addedWithWorktreeEditIsAdded() {
        let s = parse(["1 AM N... 000000 100644 100644 \(h) \(i) n.txt"])
        #expect(s.entries["n.txt"]?.display == .added)
    }

    @Test func branchHeaders() {
        var s = parse(["# branch.oid abc", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1"])
        #expect(s.branch == "main" && s.oid == "abc" && s.upstream == "origin/main" && s.ahead == 2 && s.behind == 1)
        s = parse(["# branch.oid abc", "# branch.head (detached)"])
        #expect(s.branch == nil && s.upstream == nil && s.ahead == nil && s.behind == nil)
        s = parse(["# branch.oid (initial)", "# branch.head main"])
        #expect(s.isUnborn && s.oid == nil)
    }

    @Test func prefixIsStrippedAndOutsideEntriesDropped() {
        let s = parse(["? sub/a", "? other/b"], prefix: "sub/")
        #expect(Set(s.entries.keys) == ["a"])
    }

    @Test func operationDetected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GitOperation.detect(gitDir: dir) == nil)
        try Data().write(to: dir.appendingPathComponent("MERGE_HEAD"))
        #expect(GitOperation.detect(gitDir: dir) == .merge)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("rebase-merge"), withIntermediateDirectories: true)
        #expect(GitOperation.detect(gitDir: dir) == .rebase)
    }
}
