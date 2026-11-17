@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

struct ApplyFailed: Error { var status: Int32 }

@Suite struct GitPatchTests {
    private let base = (1...12).map { "line\($0)" }.joined(separator: "\n") + "\n"
    private var edited: String {
        base.replacingOccurrences(of: "line2\n", with: "TWO\n").replacingOccurrences(of: "line6\n", with: "line6\nnew6\n")
            .replacingOccurrences(of: "line11\n", with: "")
    }

    private func apply(_ root: URL, _ patch: Data, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["apply"] + args + ["--unidiff-zero", "-"]
        p.currentDirectoryURL = root
        let inPipe = Pipe()
        p.standardInput = inPipe; p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
        try p.run()
        inPipe.fileHandleForWriting.write(patch)
        try inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw ApplyFailed(status: p.terminationStatus) }
    }

    private func patch(_ hunk: GitHunk, path: String = "f.txt", eol: String = "\n", nonl: (Bool, Bool) = (false, false)) -> Data {
        GitPatch.make(path: path, hunk: hunk, lineEnding: eol, noNewlineAtEnd: nonl)
    }

    @Test func eachHunkChecksAndHunkTwoAloneStagesExactlyThat() throws {
        let root = try makeRepo(files: ["f.txt": base])
        defer { try? FileManager.default.removeItem(at: root) }
        let hunks = GitHunks.compute(base: base, buffer: edited)
        #expect(hunks.count == 3)
        for h in hunks { try apply(root, patch(h), ["--cached", "--check"]) }
        try apply(root, patch(hunks[1]), ["--cached"])
        let cached = try git(root, "diff", "--cached", "--unified=0")
        #expect(cached.contains("+new6") && !cached.contains("TWO") && !cached.contains("-line11"))
        // reverse apply clears it
        try apply(root, patch(hunks[1]), ["--cached", "-R"])
        #expect(try git(root, "diff", "--cached").isEmpty)
    }

    @Test func specialNames() throws {
        for name in ["-dash file.txt", "caf\u{e9} x.txt", "a\"q.txt"] {
            let root = try makeRepo(files: [name: base])
            defer { try? FileManager.default.removeItem(at: root) }
            let hunks = GitHunks.compute(base: base, buffer: edited)
            try apply(root, patch(hunks[0], path: name), ["--cached"])
            #expect(try git(root, "diff", "--cached", "--name-only", "-z").contains("TWO") == false)
            #expect(try git(root, "diff", "--cached", "--unified=0").contains("+TWO"))
        }
    }

    @Test func crlfIndexFile() throws {
        let crlf = base.replacingOccurrences(of: "\n", with: "\r\n")
        let root = try makeRepo(files: [:], commit: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(crlf.utf8).write(to: root.appendingPathComponent("f.txt"))
        try git(root, "add", "f.txt"); try git(root, "commit", "-q", "-m", "c")
        let h = GitHunks.compute(base: crlf, buffer: crlf.replacingOccurrences(of: "line3\r\n", with: "X\r\n"))
        let data = patch(h[0], eol: "\r\n")
        #expect(String(decoding: data, as: UTF8.self).contains("+X\r\n"))
        try apply(root, data, ["--cached"])
        #expect(try git(root, "diff", "--cached", "--unified=0").contains("+X"))
    }

    @Test func noNewlineAtEnd() throws {
        let old = "a\nb"
        let root = try makeRepo(files: ["f.txt": old])
        defer { try? FileManager.default.removeItem(at: root) }
        let h = GitHunks.compute(base: old, buffer: "a\nb\n")
        try apply(root, patch(h[0], nonl: (true, false)), ["--cached"])
        #expect(try git(root, "diff", "--cached").contains("\\ No newline"))
    }
}
