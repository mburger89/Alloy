@testable import AlloyCore
import Foundation
import Testing

@Suite struct GitHunksTests {
    @Test func addedModifiedDeleted() {
        let base = "a\nb\nc\nd\ne\nf\ng\n"
        let buf = "a\nB\nc\nc2\nd\ne\ng\n"
        let h = GitHunks.compute(base: base, buffer: buf)
        #expect(h.map(\.kind) == [.modified, .added, .deleted])
        #expect(h[0].bufferRows == 1..<2 && h[0].markRow == 1)
        #expect(h[1].bufferRows == 3..<4)
        #expect(h[2].bufferRows == 6..<6 && h[2].markRow == 6)
        #expect(h[0].oldLines == ["b"] && h[0].newLines == ["B"])
        #expect(h[1].oldStart == 3 && h[1].oldCount == 0)
    }

    @Test func deletedAtFirstAndLastLine() {
        let first = GitHunks.compute(base: "a\nb\n", buffer: "b\n")
        #expect(first.count == 1 && first[0].kind == .deleted && first[0].markRow == 0)
        let last = GitHunks.compute(base: "a\nb\n", buffer: "a\n")
        #expect(last[0].kind == .deleted && last[0].markRow == 1)
    }

    @Test func crlfBufferAgainstLFBaseMarksNothing() {
        #expect(GitHunks.compute(base: "a\nb\nc\n", buffer: "a\r\nb\r\nc\r\n").isEmpty)
        let h = GitHunks.compute(base: "a\nb\nc\n", buffer: "a\r\nX\r\nc\r\n")
        #expect(h.count == 1 && h[0].bufferRows == 1..<2)
    }

    @Test func noTrailingNewlineChange() {
        let h = GitHunks.compute(base: "a\nb", buffer: "a\nb\n")
        #expect(h.count == 1 && h[0].kind == .modified && h[0].bufferRows == 1..<2)
        let both = GitHunks.compute(base: "a\nb", buffer: "a\nb")
        #expect(both.isEmpty)
    }

    @Test func emptyBaseAndEmptyBuffer() {
        let a = GitHunks.compute(base: "", buffer: "x\ny\n")
        #expect(a.count == 1 && a[0].kind == .added && a[0].bufferRows == 0..<2)
        let d = GitHunks.compute(base: "x\ny\n", buffer: "")
        #expect(d.count == 1 && d[0].kind == .deleted && d[0].markRow == 0)
    }

    @Test func compareHunksCarryContext() {
        let base = (1...10).map { "l\($0)" }.joined(separator: "\n") + "\n"
        let buf = base.replacingOccurrences(of: "l5\n", with: "X\n")
        let h = GitHunks.compareHunks(base: base, buffer: buf)
        #expect(h.count == 1 && h[0].context == 3 && h[0].kind == .modified)
        #expect(h[0].oldLines.count == 7 && h[0].leadingContext == 3 && h[0].markRow == 4)
    }

    @Test func lfsPointerAndBinaryClassified() {
        #expect(GitBlobKind.classify(Data("version https://git-lfs.github.com/spec/v1\noid sha256:x\n".utf8)) == .lfsPointer)
        #expect(GitBlobKind.classify(Data([0x50, 0x00, 0x51])) == .binary)
        #expect(GitBlobKind.classify(Data("hello".utf8)) == .text)
    }
}
