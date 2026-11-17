@testable import AlloyCore
import Testing

@Suite struct GitStatusRollupTests {
    @Test func folderTakesStrongestChild() {
        let r = GitStatusRollup.folders(["a/b/x": .untracked, "a/y": .modified, "a/b/z": .added], ignoredFolders: [])
        #expect(r["a"] == .modified)
        #expect(r["a/b"] == .added)
    }

    @Test func conflictedBeatsAll() {
        let r = GitStatusRollup.folders(["d/a": .modified, "d/b": .conflicted, "d/c": .added], ignoredFolders: [])
        #expect(r["d"] == .conflicted)
    }

    @Test func ignoredNeverColoursParent() {
        let r = GitStatusRollup.folders(["d/a": .ignored], ignoredFolders: ["dist/"])
        #expect(r["d"] == nil)
        #expect(r["dist"] == .ignored)
    }

    @Test func untrackedDirectoryColoursItselfAndParents() {
        let r = GitStatusRollup.folders(["p/new/": .untracked], ignoredFolders: [])
        #expect(r["p/new"] == .untracked && r["p"] == .untracked)
    }

    @Test func changedPaths() {
        let c = GitStatusDiff.changedPaths(old: ["a": .modified, "b": .added, "c": .added], new: ["a": .modified, "b": .modified, "d": .untracked])
        #expect(c == ["b", "c", "d"])
    }
}
