import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

private func json(_ text: String) -> JSONValue { JSONValue.parse(Data(text.utf8))! }

private func location(_ uri: String, line: Int, character: Int = 0) -> String {
    #"{"uri":"\#(uri)","range":{"start":{"line":\#(line),"character":\#(character)},"end":{"line":\#(line),"character":\#(character + 1)}}}"#
}

@MainActor
struct ReferenceParsingTests {
    let root = URL(fileURLWithPath: "/work/proj")

    private func parse(_ text: String, current: String = "cur.rs", snapshot: String = "x\n",
                       read: @escaping (String, Set<Int>) -> [Int: String] = { _, _ in [:] }) -> ReferenceResult {
        ReferenceParsing.parse(json(text), root: root, currentPath: current, currentSnapshot: snap(snapshot), readLines: read)
    }

    @Test func hitsAreSortedAndOutsideRootCounted() {
        let text = "[" + [location("file:///work/proj/b.rs", line: 4), location("file:///usr/lib/std.rs", line: 1),
                          location("file:///work/proj/a.rs", line: 9), location("file:///work/proj/a.rs", line: 2, character: 5),
                          location("file:///work/proj/a.rs", line: 2, character: 1), location("file:///work/proj-x/y.rs", line: 0)]
            .joined(separator: ",") + "]"
        let result = parse(text, read: { path, lines in Dictionary(uniqueKeysWithValues: lines.map { ($0, "  line \(path):\($0)  ") }) })
        #expect(result.hits.map { "\($0.path):\($0.line):\($0.range.start.character)" } == ["a.rs:2:1", "a.rs:2:5", "a.rs:9:0", "b.rs:4:0"])
        #expect(result.outsideRoot == 2)
        #expect(!result.truncated)
        #expect(result.hits[0].preview == "line a.rs:2")
    }

    @Test func currentFilePreviewComesFromTheUnsavedSnapshot() {
        let result = parse("[" + location("file:///work/proj/cur.rs", line: 1) + "]", snapshot: "zero\n   unsaved text\n",
                           read: { _, _ in Issue.record("the current file must not be read"); return [:] })
        #expect(result.hits.first?.preview == "unsaved text")
    }

    @Test func twelveThousandHitsAreCapped() {
        let text = "[" + (0..<12_000).map { location("file:///work/proj/big.rs", line: $0) }.joined(separator: ",") + "]"
        var reads = 0
        let result = ReferenceParsing.parse(json(text), root: root, currentPath: "cur.rs", currentSnapshot: snap("x\n"),
                                            readLines: { _, lines in reads += 1; return Dictionary(uniqueKeysWithValues: lines.map { ($0, "l") }) })
        #expect(result.hits.count == 10_000)
        #expect(result.truncated)
        #expect(result.hits.last?.line == 9_999)
        #expect(reads == 1)
    }

    @Test func previewsAreTrimmedAndCapped() {
        let long = String(repeating: "x", count: 500)
        let result = parse("[" + location("file:///work/proj/a.rs", line: 0) + "]", read: { _, _ in [0: "   \(long)   \r"] })
        #expect(result.hits.first?.preview.count == 200)
    }

    @Test func missingFileGivesEmptyPreview() {
        let result = parse("[" + location("file:///work/proj/gone.rs", line: 3) + "]")
        #expect(result.hits.count == 1)
        #expect(result.hits.first?.preview == "")
    }

    @Test func nullIsEmpty() {
        let result = parse("null")
        #expect(result.hits.isEmpty && result.outsideRoot == 0 && !result.truncated)
    }

    @Test func fileReaderReadsWantedLinesOnlyAndSkipsBinary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-refs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "zero\none\ntwo\nthree".write(to: dir.appendingPathComponent("t.txt"), atomically: true, encoding: .utf8)
        try Data([0x61, 0x00, 0x62, 0x0A]).write(to: dir.appendingPathComponent("bin"))
        #expect(ReferenceParsing.readLines(root: dir, path: "t.txt", lines: [1, 3]) == [1: "one", 3: "three"])
        #expect(ReferenceParsing.readLines(root: dir, path: "bin", lines: [0]).isEmpty)
        #expect(ReferenceParsing.readLines(root: dir, path: "nope", lines: [0]).isEmpty)
    }
}

@Suite
@MainActor
struct ReferenceRequestTests {
    private let main = Rig.config("main", ext: "x")

    private func script(_ replies: String, caps: String = #""referencesProvider":true"#) -> String {
        #"{"capabilities":{"textDocumentSync":2,\#(caps)},"replies":{"textDocument/references":\#(replies)}}"#
    }

    @Test func answeredAndAsksForTheDeclaration() async throws {
        let reply = "[{\"result\":[\(location("file:///elsewhere/q.x", line: 1))]}]"
        try await Rig.run([main], scripts: ["main": script(reply)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            let outcome = await rig.manager.references(path: "a.x", utf8Offset: 1, snapshot: snapshot)
            guard case .answered(let result) = outcome else { Issue.record("not answered: \(outcome)"); return }
            #expect(result.hits.isEmpty && result.outsideRoot == 1)
            #expect(rig.methods("main").contains("textDocument/references"))
        }
    }

    @Test func contentModifiedIsStale() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"error":{"code":-32801,"message":"m"}}]"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.references(path: "a.x", utf8Offset: 1, snapshot: snapshot) == .stale)
        }
    }

    @Test func capabilityAbsentIsUnavailable() async throws {
        try await Rig.run([main], scripts: ["main": script("[]", caps: #""hoverProvider":true"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.references(path: "a.x", utf8Offset: 1, snapshot: snapshot) == .unavailable)
        }
    }
}
