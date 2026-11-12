@testable import AlloyHighlight
import Foundation
import MetalUI
import MetalUITesting
import Testing

private typealias Runs = [(Range<Int>, SyntaxToken)]

private func tokens(_ runs: [(Range<Int>, SyntaxToken)]) -> [String] {
    runs.map { "\($0.0.lowerBound)..<\($0.0.upperBound) \($0.1)" }
}

private func has(_ runs: [(Range<Int>, SyntaxToken)], _ range: Range<Int>, _ token: SyntaxToken) -> Bool {
    runs.contains { $0.0 == range && $0.1 == token }
}

private func same(_ a: [(Range<Int>, SyntaxToken)], _ b: [(Range<Int>, SyntaxToken)]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

@Suite struct EngineTests {
    @Test func swiftKeywordCaptured() async {
        let engine = HighlightEngine()
        let id = UUID()
        await engine.open(id: id, language: .swift, text: "let x = 1", version: 0)
        let runs = await engine.captures(id: id, byteRange: 0..<9).runs
        #expect(has(runs, 0..<3, .keyword), "\(tokens(runs))")
        #expect(has(runs, 8..<9, .number), "\(tokens(runs))")
    }

    @Test func everyLanguageHasQueries() async {
        let samples: [Language: String] = [
            .swift: "let x = 1", .python: "def f(x):\n    return 1\n", .javascript: "const a = 1;\n",
            .typescript: "const a: number = 1;\n", .tsx: "const a = <div>hi</div>;\n", .json: "{\"a\": 1}",
            .markdown: "# Title\n\ntext\n", .bash: "echo \"hi\"\n", .rust: "fn main() { let x = 1; }\n",
            .go: "package main\nfunc main() {}\n", .c: "int main(void) { return 0; }\n",
            .cpp: "class A { int x; };\n", .yaml: "a: 1\n", .html: "<p class=\"a\">x</p>\n", .css: "a { color: red; }\n",
        ]
        let engine = HighlightEngine()
        for language in Language.allCases {
            let text = samples[language] ?? ""
            let id = UUID()
            await engine.open(id: id, language: language, text: text, version: 0)
            let runs = await engine.captures(id: id, byteRange: 0..<text.utf8.count).runs
            #expect(!runs.isEmpty, "no highlights for \(language)")
        }
    }

    /// SplitMix64: the same seed always gives the same edit script, so a red run can be replayed.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Random inserts and deletes (the alphabet has quotes, braces and newlines, so the text spends most of the
    /// script in error states), then every edit is undone and the incrementally maintained highlights must equal a
    /// fresh parse of the original, valid text.
    ///
    /// Why after undoing, not after the last edit: tree-sitter guarantees an incremental reparse equals a fresh
    /// parse only for error-free trees. Inside ERROR/MISSING regions its recovery depends on which subtrees were
    /// reused, and tree-sitter-swift's external scanner (string and comment state) can amplify that. Tree-sitter's
    /// own randomised corpus tests therefore compare after undoing the edits. A divergence here, on valid text,
    /// would be a real engine or scanner bug.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8, 42, 99, 2024, 31337] as [UInt64]) @MainActor func incrementalEditMatchesFullParse(seed: UInt64) async {
        let source = "import Foundation\n\nstruct Point {\n    var x = 1\n    func f(_ a: Int) -> String { \"v\\(a)\" }\n}\n// done\nlet y = [1, 2, 3]\n"
        let buffer = CodeBuffer(source)
        let cursor = buffer.makeEditCursor()
        let engine = HighlightEngine()
        let id = UUID()
        await engine.open(id: id, language: .swift, text: source, version: buffer.version)
        var rng = SplitMix64(state: seed)
        let alphabet = Array("abcxyz 0123{}()\"\n=+")
        var script: [String] = []
        var undo: [(at: Int, inserted: Int, removed: String)] = []
        func apply(_ range: Range<Int>, _ text: String) async -> Bool {
            let removed = String(decoding: buffer.snapshot().utf8(in: range), as: UTF8.self)
            buffer.replace(range, with: text)
            undo.append((range.lowerBound, text.utf8.count, removed))
            guard case .edits(let edits) = cursor.drain() else { Issue.record("seed \(seed): resync"); return false }
            await engine.edit(id: id, edits: edits, newText: buffer.snapshot().text, version: buffer.version)
            return true
        }
        for _ in 0..<50 {
            let count = buffer.utf8Count
            let at = Int.random(in: 0...count, using: &rng)
            let snapshot = buffer.snapshot()
            let isDelete = count > 0 && Bool.random(using: &rng)
            if isDelete, at < count, snapshot.isScalarBoundary(at), snapshot.isScalarBoundary(at + 1) {
                script.append("delete \(at)..<\(at + 1)")
                guard await apply(at..<(at + 1), "") else { return }
            } else {
                let ch = String(alphabet.randomElement(using: &rng)!)
                script.append("insert \(ch.debugDescription) at \(at)")
                guard await apply(at..<at, ch) else { return }
            }
        }
        for step in undo.reversed() {
            buffer.replace(step.at..<(step.at + step.inserted), with: step.removed)
            guard case .edits(let edits) = cursor.drain() else { Issue.record("seed \(seed): resync"); return }
            await engine.edit(id: id, edits: edits, newText: buffer.snapshot().text, version: buffer.version)
        }
        let final = buffer.snapshot().text
        #expect(final == source, "seed \(seed): undo did not restore the text; script \(script)")
        let incremental = await engine.captures(id: id, byteRange: 0..<final.utf8.count).runs
        let fresh = UUID()
        await engine.open(id: fresh, language: .swift, text: final, version: 0)
        let full = await engine.captures(id: fresh, byteRange: 0..<final.utf8.count).runs
        #expect(same(incremental, full), "seed \(seed): \(tokens(incremental)) vs \(tokens(full)); script \(script)")
    }

    @Test func multiByteColumns() async {
        let text = "let s = \"é🙂\"; let y = 2"
        let expected = text.utf8.count - "let y = 2".utf8.count
        let engine = HighlightEngine()
        let id = UUID()
        await engine.open(id: id, language: .swift, text: text, version: 0)
        let runs = await engine.captures(id: id, byteRange: 0..<text.utf8.count).runs
        #expect(expected == 18)
        #expect(has(runs, expected..<(expected + 3), .keyword), "\(expected): \(tokens(runs))")
    }

    @Test func unknownLanguagePlain() {
        #expect(FenceHighlighter.shared.highlight(code: "let x = 1", language: "objc", isClosed: true).isEmpty)
        #expect(FenceHighlighter.shared.highlight(code: "let x = 1", language: nil, isClosed: true).isEmpty)
    }

    @Test func fenceHighlighterSwift() {
        let light = FenceHighlighter.shared.highlight(code: "let x = 1", language: "swift", isClosed: true)
        #expect(light.contains { $0.range == 0..<3 })
        #expect(light.contains { $0.range == 8..<9 })
        #expect(light.first?.style.foreground != nil)
    }

    @Test func fenceCaps() {
        let fence = FenceHighlighter.shared
        // 2000 lines with a trailing newline is 2000 lines; one more is over.
        #expect(!fence.highlight(code: String(repeating: "let x = 1\n", count: 2_000), language: "swift", isClosed: true).isEmpty)
        #expect(fence.highlight(code: String(repeating: "let x = 1\n", count: 2_001), language: "swift", isClosed: true).isEmpty)
        // 64 KB of bytes, however few lines.
        let under = "let s = \"" + String(repeating: "a", count: 60_000) + "\""
        let over = "let s = \"" + String(repeating: "a", count: 70_000) + "\""
        #expect(!fence.highlight(code: under, language: "swift", isClosed: true).isEmpty)
        #expect(fence.highlight(code: over, language: "swift", isClosed: true).isEmpty)
    }

    @Test @MainActor func providerSetsHighlightsAsOf() async throws {
        let text = "let x = 1\nlet y = \"a\"\n// c\n"
        let buffer = CodeBuffer(text)
        let decorations = CodeDecorations(buffer: buffer)
        let engine = HighlightEngine()
        let id = UUID()
        await engine.open(id: id, language: .swift, text: text, version: buffer.version)
        let highlighter = CodeViewHighlighter(engine: engine, documentID: id, decorations: decorations, palette: SyntaxPalette())
        let window = try TestWindow(size: Size(width: Pixels(400), height: Pixels(200))) {
            CodeView(buffer: buffer, decorations: decorations).font(size: 12)
                .frame(width: Pixels(400), height: Pixels(200))
        }
        try await window.runUntil { window.frameWork.contains { $0.codeHighlightRunsVisited > 0 } }
        #expect(window.frameWork.contains { $0.codeHighlightRunsVisited > 0 })
        #expect(highlighter.appliedVersions == [buffer.version], "\(highlighter.appliedVersions) vs \(buffer.version)")
    }


    /// A request whose last row is blank must cover that row's newline byte, or MetalUI keeps the row "missing"
    /// and asks again on every frame.
    @Test @MainActor func requestCoversBlankLastRowNewline() async throws {
        let text = "let x = 1\n\n\nlet y = 2\n"
        let buffer = CodeBuffer(text)
        let decorations = CodeDecorations(buffer: buffer)
        let engine = HighlightEngine()
        let id = UUID()
        await engine.open(id: id, language: .swift, text: text, version: buffer.version)
        let highlighter = CodeViewHighlighter(engine: engine, documentID: id, decorations: decorations, palette: SyntaxPalette())
        let snapshot = buffer.snapshot()
        highlighter.decorations(decorations, needHighlightsForRows: 0..<2, in: snapshot)
        try await settle(highlighter)
        let newline = snapshot.lineRange(1).lowerBound
        let asked = try #require(highlighter.lastRequestedBytes)
        #expect(asked.contains(newline), "asked \(asked), blank row's newline is byte \(newline)")
    }

    /// The engine is ahead of the snapshot that asked (an edit landed between the request and the response): the
    /// runs of the newer text must not be stamped onto the older snapshot; the rows are asked again on the
    /// buffer's newest snapshot.
    @Test @MainActor func staleResultsAreNotApplied() async throws {
        let buffer = CodeBuffer("let x = 1\n")
        let decorations = CodeDecorations(buffer: buffer)
        let engine = HighlightEngine(waitTimeout: .milliseconds(100))
        let id = UUID()
        let old = buffer.snapshot()
        buffer.replace(0..<0, with: "// c\n")
        await engine.open(id: id, language: .swift, text: buffer.snapshot().text, version: buffer.version)
        let highlighter = CodeViewHighlighter(engine: engine, documentID: id, decorations: decorations)
        highlighter.decorations(decorations, needHighlightsForRows: 0..<1, in: old)
        try await settle(highlighter)
        #expect(highlighter.staleCount == 1)
        #expect(highlighter.appliedVersions == [buffer.version])
        // The engine never catches up and the buffer does not move again: the wait times out, the answer is
        // dropped, and nothing is asked again (no spin).
        buffer.replace(0..<0, with: "// d\n")
        highlighter.decorations(decorations, needHighlightsForRows: 0..<1, in: buffer.snapshot())
        try await settle(highlighter)
        #expect(highlighter.staleCount == 2)
        #expect(highlighter.appliedVersions == [buffer.version - 1])
        #expect(await engine.waiterCount == 0)
    }

    /// The edit arrives after the request: the request waits for it and is answered from the new text.
    @Test @MainActor func requestWaitsForTheEngineToCatchUp() async throws {
        let buffer = CodeBuffer("let x = 1\n")
        let cursor = buffer.makeEditCursor()
        let decorations = CodeDecorations(buffer: buffer)
        let engine = HighlightEngine()
        let id = UUID()
        await engine.open(id: id, language: .swift, text: buffer.snapshot().text, version: buffer.version)
        let highlighter = CodeViewHighlighter(engine: engine, documentID: id, decorations: decorations)
        buffer.replace(0..<0, with: "// c\n")
        guard case .edits(let edits) = cursor.drain() else { Issue.record("resync"); return }
        highlighter.decorations(decorations, needHighlightsForRows: 0..<2, in: buffer.snapshot())
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await engine.waiterCount == 1, "the request is waiting")
        #expect(!highlighter.isIdle)
        await engine.edit(id: id, edits: edits, newText: buffer.snapshot().text, version: buffer.version)
        try await settle(highlighter)
        #expect(highlighter.staleCount == 0)
        #expect(highlighter.appliedVersions == [buffer.version])
        #expect(await engine.waiterCount == 0)
    }

    @Test func captureWaitsForAnEditThenAnswersItsVersion() async {
        let engine = HighlightEngine()
        let id = UUID()
        await engine.open(id: id, language: .swift, text: "let x = 1", version: 0)
        let waiting = Task { await engine.captures(id: id, byteRange: 0..<20, minVersion: 1) }
        while await engine.waiterCount == 0 { await Task.yield() }
        let edit = CodeEdit(version: 1, transaction: CodeTransactionID(rawValue: 1), origin: .programmatic, range: 9..<9,
                            scalarRange: 9..<9, startPoint: CodePoint(row: 0, column: 9), oldEndPoint: CodePoint(row: 0, column: 9),
                            newEndPoint: CodePoint(row: 0, column: 12), newText: "000")
        await engine.edit(id: id, edits: [edit], newText: "let x = 1000", version: 1)
        let answer = await waiting.value
        #expect(answer.version == 1)
        #expect(has(answer.runs, 8..<12, .number), "\(tokens(answer.runs))")
    }

    @Test func waitTimesOutWithTheCurrentVersion() async {
        let engine = HighlightEngine(waitTimeout: .milliseconds(100))
        let id = UUID()
        await engine.open(id: id, language: .swift, text: "let x = 1", version: 0)
        let answer = await engine.captures(id: id, byteRange: 0..<9, minVersion: 5)
        #expect(answer.version == 0)
        #expect(has(answer.runs, 0..<3, .keyword))
        #expect(await engine.waiterCount == 0)
    }

    @Test func closeEndsWaitsWithUnknownVersion() async {
        let engine = HighlightEngine()
        let id = UUID()
        await engine.open(id: id, language: .swift, text: "let x = 1", version: 0)
        let a = Task { await engine.captures(id: id, byteRange: 0..<9, minVersion: 3) }
        let b = Task { await engine.captures(id: id, byteRange: 0..<9, minVersion: 4) }
        while await engine.waiterCount < 2 { await Task.yield() }
        await engine.close(id: id)
        #expect(await a.value.version == HighlightEngine.unknownVersion)
        #expect(await b.value.version == HighlightEngine.unknownVersion)
        #expect(await engine.waiterCount == 0)
    }

    @Test @MainActor func newerRequestsSupersedeAndCoalesce() async throws {
        let text = (0..<200).map { "let v\($0) = \($0)\n" }.joined()
        let buffer = CodeBuffer(text)
        let decorations = CodeDecorations(buffer: buffer)
        let engine = HighlightEngine()
        let id = UUID()
        await engine.open(id: id, language: .swift, text: text, version: buffer.version)
        let highlighter = CodeViewHighlighter(engine: engine, documentID: id, decorations: decorations)
        let snapshot = buffer.snapshot()
        highlighter.decorations(decorations, needHighlightsForRows: 0..<10, in: snapshot)   // goes out
        highlighter.decorations(decorations, needHighlightsForRows: 10..<20, in: snapshot)  // queued
        highlighter.decorations(decorations, needHighlightsForRows: 20..<30, in: snapshot)  // merged into the queue
        try await settle(highlighter)
        // The first answer was older than the latest request and was dropped; the merged request was applied once.
        #expect(highlighter.supersededCount == 1)
        #expect(highlighter.appliedVersions == [snapshot.version])
    }

    @Test @MainActor func multiByteAndMultipleEditsMatchFullParse() async {
        let source = "let s = \"é\"\nlet y = 2\n"
        let buffer = CodeBuffer(source)
        let cursor = buffer.makeEditCursor()
        let engine = HighlightEngine()
        let id = UUID()
        await engine.open(id: id, language: .swift, text: source, version: buffer.version)
        // Several edits in one call, in order, with 2-, 4- and 1-byte text; later edits are in the
        // coordinates left by the earlier ones.
        buffer.transaction { b in
            b.replace(11..<11, with: "🙂")
            b.replace(0..<0, with: "// 世界\n")
            b.replace(b.utf8Count..<b.utf8Count, with: "let z = \"ü\"\n")
        }
        guard case .edits(let edits) = cursor.drain() else { Issue.record("resync"); return }
        #expect(edits.count == 3)
        await engine.edit(id: id, edits: edits, newText: buffer.snapshot().text, version: buffer.version)
        let text = buffer.snapshot().text
        let incremental = await engine.captures(id: id, byteRange: 0..<text.utf8.count)
        let fresh = UUID()
        await engine.open(id: fresh, language: .swift, text: text, version: buffer.version)
        let full = await engine.captures(id: fresh, byteRange: 0..<text.utf8.count)
        #expect(incremental.version == buffer.version)
        #expect(same(incremental.runs, full.runs), "\(tokens(incremental.runs)) vs \(tokens(full.runs))")
        let secondLet = text.utf8.count - "let z = \"ü\"\n".utf8.count - "let y = 2\n".utf8.count
        #expect(has(incremental.runs, secondLet..<(secondLet + 3), .keyword), "\(tokens(incremental.runs))")
    }

    @MainActor private func settle(_ highlighter: CodeViewHighlighter) async throws {
        for _ in 0..<2_000 where !highlighter.isIdle { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(highlighter.isIdle)
    }

    @Test func largeFileParsesOffMain() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Bench/Corpus/large.rs")
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        #expect(data.count > 1_000_000)
        let ticks = Ticker()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks.count += 1
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let engine = HighlightEngine(windowedThreshold: .max)   // the whole-file parse is what must stay off main
        let id = UUID()
        await engine.open(id: id, language: .rust, text: text, version: 0)
        let runs = await engine.captures(id: id, byteRange: 0..<4096).runs
        ticker.cancel()
        let seen = await MainActor.run { ticks.count }
        #expect(!runs.isEmpty)
        #expect(seen >= 10, "main actor advanced \(seen) times during the parse")
    }
}

@MainActor private final class Ticker { var count = 0 }
