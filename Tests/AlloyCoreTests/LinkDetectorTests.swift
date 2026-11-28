import Foundation
import AlloyTestSupport
import Testing
@testable import AlloyCore

@Suite struct LinkDetectorTests {
    private func file(_ l: TerminalLink) -> (String, Int?, Int?)? {
        if case let .file(p, line, col) = l.kind { return (p, line, col) }
        return nil
    }

    @Test func detectsAllFourForms() {
        let a = LinkDetector.candidates(in: "Sources/A/B.swift:12:3: error: x")
        #expect(a.count == 1)
        #expect(file(a[0])! == ("Sources/A/B.swift", 12, 3))
        #expect(a[0].range == 0..<"Sources/A/B.swift:12:3".count)

        let b = LinkDetector.candidates(in: "B.swift(12,3)")
        #expect(b.count == 1)
        #expect(file(b[0])! == ("B.swift", 12, 3))

        let c = LinkDetector.candidates(in: "x.py, line 7")
        #expect(c.count == 1)
        #expect(file(c[0])! == ("x.py", 7, nil))
        let c2 = LinkDetector.candidates(in: "File \"x.py\", line 7")
        #expect(c2.count == 1)
        #expect(file(c2[0])! == ("x.py", 7, nil))

        let d = LinkDetector.candidates(in: "a.swift:9")
        #expect(d.count == 1)
        #expect(file(d[0])! == ("a.swift", 9, nil))
    }

    @Test func trailingPunctuationIsNotPartOfTheLink() {
        let a = LinkDetector.candidates(in: "foo.swift:12:3:")
        #expect(a.count == 1)
        #expect(a[0].range == 0..<"foo.swift:12:3".count)
        #expect(file(a[0])! == ("foo.swift", 12, 3))
        let b = LinkDetector.candidates(in: "(foo.swift:12)")
        #expect(b.count == 1)
        #expect(b[0].range == 1..<"(foo.swift:12".count)
        #expect(file(b[0])! == ("foo.swift", 12, nil))
    }

    @Test func urlsAreNotPaths() {
        let a = LinkDetector.candidates(in: "http://localhost:8080/x")
        #expect(a.count == 1)
        #expect(a[0].kind == .url("http://localhost:8080/x"))
        let b = LinkDetector.candidates(in: "see https://e.com/a.")
        #expect(b.count == 1)
        #expect(b[0].kind == .url("https://e.com/a"))
    }

    @Test func windowsDriveIsNotALine() {
        let a = LinkDetector.candidates(in: "C:\\src\\x.swift:3")
        #expect(a.count == 1)
        #expect(file(a[0])! == ("C:\\src\\x.swift", 3, nil))
    }

    @Test func bareWordsAndPlainNumbersAreNotLinks() {
        #expect(LinkDetector.candidates(in: "error: 12:30 elapsed").isEmpty)
        #expect(LinkDetector.candidates(in: "foo.swift without a line").isEmpty)
    }

    @Test func linkAtColumnHitTests() {
        let row = "ab a.swift:9 cd"
        #expect(LinkDetector.link(at: 3, in: row)?.range == 3..<12)
        #expect(LinkDetector.link(at: 11, in: row) != nil)
        #expect(LinkDetector.link(at: 12, in: row) == nil)
        #expect(LinkDetector.link(at: 0, in: row) == nil)
    }

    @Test func resolveTriesOscCwdThenSpawnThenRoot() {
        var calls: [String] = []
        let r = LinkDetector.resolve("a.swift", bases: ["/p/osc", "/p/spawn", "/p"], projectRoot: "/p") { path in
            calls.append(path); return path == "/p/a.swift"
        }
        #expect(r == "a.swift")
        #expect(calls == ["/p/osc/a.swift", "/p/spawn/a.swift", "/p/a.swift"])

        calls = []
        let r2 = LinkDetector.resolve("a.swift", bases: ["/p/osc", "/p/spawn", "/p"], projectRoot: "/p") { path in
            calls.append(path); return path == "/p/osc/a.swift"
        }
        #expect(r2 == "osc/a.swift")
        #expect(calls == ["/p/osc/a.swift"])
    }

    @Test func resolveRejectsOutsideProject() {
        var calls = 0
        let r = LinkDetector.resolve("../secret.txt", bases: ["/p/sub"], projectRoot: "/p") { _ in calls += 1; return true }
        #expect(r == "secret.txt")
        #expect(LinkDetector.resolve("../../secret.txt", bases: ["/p/sub"], projectRoot: "/p") { _ in true } == nil)
        #expect(LinkDetector.resolve("/etc/hosts", bases: ["/p"], projectRoot: "/p") { _ in true } == nil)
        #expect(LinkDetector.resolve("/p/x/y.swift", bases: ["/p"], projectRoot: "/p") { _ in true } == "x/y.swift")
        #expect(LinkDetector.resolve("../p2/x", bases: ["/p"], projectRoot: "/p") { _ in true } == nil)
    }

    @Test func resolveRejectsMissingFile() {
        #expect(LinkDetector.resolve("a.swift", bases: ["/p"], projectRoot: "/p") { _ in false } == nil)
    }

    @Test func wideCharactersKeepCharacterOffsets() {
        let row = "🙂👍 a.swift:4"
        let a = LinkDetector.candidates(in: row)
        #expect(a.count == 1)
        #expect(a[0].range == 3..<12)
        #expect(file(a[0])! == ("a.swift", 4, nil))
    }

    @Test func resolveRejectsASymlinkThatLeavesTheProject() throws {
        let fm = FileManager.default
        let base = TempFiles.url("ld")
        let project = base.appendingPathComponent("p"), outside = base.appendingPathComponent("out")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try "x".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: project.appendingPathComponent("real.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: project.appendingPathComponent("link.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("good.txt"), withDestinationURL: project.appendingPathComponent("real.txt"))
        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        #expect(LinkDetector.resolve("link.txt", bases: [project.path], projectRoot: project.path, fileExists: exists) == nil)
        #expect(LinkDetector.resolve("good.txt", bases: [project.path], projectRoot: project.path, fileExists: exists) == "good.txt")
    }
}
