@testable import AlloyHighlight
import Foundation
import MetalUI
import MetalUICodeBuffer
import Testing

private typealias Runs = [(Range<Int>, SyntaxToken)]

private func same(_ a: Runs, _ b: Runs) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

/// A realistic multi-thousand-line source: top-level items with nested bodies, strings, comments and numbers.
private func source(_ language: Language, items: Int = 400) -> String {
    var s = ""
    for i in 0..<items {
        switch language {
        case .rust:
            s += "// item \(i)\nstruct S\(i) {\n    a: i32,\n    b: String,\n}\n\nimpl S\(i) {\n    fn run(&self, x: i32) -> i32 {\n        let s = \"v\(i)\";\n        if x > \(i) { return x + \(i); }\n        x * 2\n    }\n}\n\n"
        default:
            s += "// item \(i)\nstruct S\(i) {\n    var a: Int = \(i)\n    func run(_ x: Int) -> String {\n        let s = \"v\\(x)\"\n        if x > \(i) { return s }\n        return \"none\"\n    }\n}\n\n"
        }
    }
    return s
}

/// Byte offsets of the starts of top-level items (lines starting with `// item`).
private func itemStarts(_ text: String) -> [Int] {
    let bytes = Array(text.utf8)
    let needle = Array("// item".utf8)
    var out: [Int] = []
    var i = 0
    while i + needle.count <= bytes.count {
        if (i == 0 || bytes[i - 1] == 10), Array(bytes[i..<(i + needle.count)]) == needle { out.append(i) }
        i += 1
    }
    return out
}

private func windowed() -> HighlightEngine { HighlightEngine(windowedThreshold: 10_000, windowMargin: 2_000) }
private func full() -> HighlightEngine { HighlightEngine(windowedThreshold: .max) }

private func viewport(_ starts: [Int], _ index: Int, _ count: Int) -> Range<Int> {
    let a = starts[index], b = starts[min(index + 4, starts.count - 1)]
    return a..<min(b, count)
}

@Suite struct WindowedEngineTests {
    @Test(arguments: [Language.swift, .rust]) func windowedMatchesFullParse(language: Language) async {
        let text = source(language)
        let count = text.utf8.count
        #expect(count > 10_000 * 5)
        let starts = itemStarts(text)
        let w = windowed(), f = full()
        let wid = UUID(), fid = UUID()
        await w.open(id: wid, language: language, text: text, version: 0)
        await f.open(id: fid, language: language, text: text, version: 0)
        for index in [0, 1, starts.count / 2, starts.count / 2 + 7, starts.count - 5] {
            let range = viewport(starts, index, count)
            let a = await w.captures(id: wid, byteRange: range).runs
            let b = await f.captures(id: fid, byteRange: range).runs
            #expect(!b.isEmpty)
            #expect(same(a, b), "\(language) item \(index): \(a.count) vs \(b.count) runs")
        }
    }

    @Test func scrollingFarRebuildsTheWindow() async {
        let text = source(.swift)
        let starts = itemStarts(text)
        let w = windowed(), f = full()
        let wid = UUID(), fid = UUID()
        await w.open(id: wid, language: .swift, text: text, version: 0)
        await f.open(id: fid, language: .swift, text: text, version: 0)
        let count = text.utf8.count
        for index in [0, starts.count - 5, 0, starts.count / 2] {
            let range = viewport(starts, index, count)
            let a = await w.captures(id: wid, byteRange: range).runs
            let b = await f.captures(id: fid, byteRange: range).runs
            #expect(same(a, b), "item \(index)")
        }
    }

    /// Applies a replacement through a CodeBuffer so the engine gets real `CodeEdit`s.
    @MainActor private func apply(_ buffer: CodeBuffer, _ cursor: CodeEditCursor, _ engine: HighlightEngine, _ id: UUID,
                                  _ range: Range<Int>, _ text: String) async {
        buffer.replace(range, with: text)
        guard case .edits(let edits) = cursor.drain() else { Issue.record("resync"); return }
        await engine.edit(id: id, edits: edits, newText: buffer.snapshot().text, version: buffer.version)
    }

    @Test @MainActor func editsInsideAndOutsideTheWindow() async {
        let text = source(.swift)
        let starts = itemStarts(text)
        let buffer = CodeBuffer(text)
        let cursor = buffer.makeEditCursor()
        let w = windowed()
        let id = UUID()
        await w.open(id: id, language: .swift, text: text, version: buffer.version)
        let mid = starts.count / 2
        _ = await w.captures(id: id, byteRange: viewport(starts, mid, text.utf8.count))   // builds the window

        // Inside: turn a number literal in the viewport into a keyword-bearing line, with a newline.
        let at = starts[mid + 1]
        await apply(buffer, cursor, w, id, at..<at, "let inserted = 42\n")
        var now = buffer.snapshot().text
        var newStarts = itemStarts(now)
        var range = viewport(newStarts, mid, now.utf8.count)
        var a = await w.captures(id: id, byteRange: range)
        let f1 = full(), fid1 = UUID()
        await f1.open(id: fid1, language: .swift, text: now, version: 0)
        var b = await f1.captures(id: fid1, byteRange: range)
        #expect(same(a.runs, b.runs), "inside edit")
        #expect(a.version == buffer.version)

        // Outside: edit near the start of the file, then ask for the old viewport and the start.
        await apply(buffer, cursor, w, id, 0..<0, "let top = 1\n")
        now = buffer.snapshot().text
        newStarts = itemStarts(now)
        for index in [mid, 0, newStarts.count - 5] {
            range = viewport(newStarts, index, now.utf8.count)
            a = await w.captures(id: id, byteRange: range)
            let f = full(), fid = UUID()
            await f.open(id: fid, language: .swift, text: now, version: 0)
            b = await f.captures(id: fid, byteRange: range)
            #expect(same(a.runs, b.runs), "outside edit, item \(index)")
        }
    }

    @Test @MainActor func minVersionWaitsForLargeDocuments() async {
        let text = source(.swift)
        let buffer = CodeBuffer(text)
        let cursor = buffer.makeEditCursor()
        let w = HighlightEngine(waitTimeout: .seconds(5), windowedThreshold: 10_000, windowMargin: 2_000)
        let id = UUID()
        await w.open(id: id, language: .swift, text: text, version: buffer.version)
        _ = await w.captures(id: id, byteRange: 0..<500)
        buffer.replace(0..<0, with: "let a = 1\n")
        let target = buffer.version
        guard case .edits(let edits) = cursor.drain() else { Issue.record("resync"); return }
        let newText = buffer.snapshot().text
        async let pending = w.captures(id: id, byteRange: 0..<10, minVersion: target)
        while await w.waiterCount == 0 { await Task.yield() }
        await w.edit(id: id, edits: edits, newText: newText, version: target)
        let result = await pending
        #expect(result.version == target)
        #expect(result.runs.contains { $0.0 == 0..<3 && $0.1 == .keyword })
        await w.close(id: id)
        let gone = await w.captures(id: id, byteRange: 0..<10)
        #expect(gone.version == HighlightEngine.unknownVersion)
    }
}
