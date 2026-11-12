import AlloyCore
import AlloyHighlight
@preconcurrency import Benchmark
import Foundation
import MetalUICodeBuffer

/// The Bench corpus (`Bench/Corpus/{small,medium,large}.rs`), located relative to this file.
private func corpus(_ name: String) -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { url.deleteLastPathComponent() }   // AlloyHotPaths, Benchmarks, Benchmarks, <repo root>
    let file = url.appendingPathComponent("Bench/Corpus/\(name).rs")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { fatalError("missing corpus file \(file.path)") }
    return text
}

private let small = corpus("small")
private let medium = corpus("medium")
private let large = corpus("large")

private func openAndViewport(_ text: String) async {
    let engine = HighlightEngine()
    let id = UUID()
    await engine.open(id: id, language: .rust, text: text, version: 1)
    let end = min(text.utf8.count, 8_000)
    blackHole(await engine.captures(id: id, byteRange: 0..<end))
    await engine.close(id: id)
}

/// A `CodeBuffer` (main-actor isolated) plus the cursor that reports its edits.
@MainActor private final class TypingRig {
    let buffer: CodeBuffer
    let cursor: CodeEditCursor

    init(_ text: String) {
        buffer = CodeBuffer(text)
        cursor = buffer.makeEditCursor()
    }

    var version: UInt64 { buffer.snapshot().version }

    /// Inserts `text` at `offset` and returns the edit events with the new text and version.
    func type(_ text: String, at offset: Int) -> (edits: [CodeEdit], text: String, version: UInt64) {
        _ = buffer.replace(offset..<offset, with: text, origin: .typing)
        let snapshot = buffer.snapshot()
        guard case .edits(let edits) = cursor.drain() else { return ([], snapshot.text, snapshot.version) }
        return (edits, snapshot.text, snapshot.version)
    }

    /// Inserts `count` characters starting at `offset`, taking a snapshot after each.
    func typeAndSnapshot(count: Int, at offset: Int) {
        for i in 0..<count {
            _ = buffer.replace((offset + i)..<(offset + i), with: "x", origin: .typing)
            blackHole(buffer.snapshot())
        }
    }
}

/// A baseline check fails when p50 wall clock or p50 peak resident memory is more than 10% above the baseline.
private func thresholds() -> [BenchmarkMetric: BenchmarkThresholds] { [
    .wallClock: .init(relative: [.p50: 10.0]),
    .peakMemoryResident: .init(relative: [.p50: 10.0]),
] }

/// `memory: false` drops peak resident memory for a benchmark whose per-iteration garbage makes the process peak jump
/// around (it only ever grows within a run), which would make a 10% memory threshold flaky.
private func configuration(maxIterations: Int = 50, memory: Bool = true) -> Benchmark.Configuration { Benchmark.Configuration(
    metrics: memory ? [.wallClock, .peakMemoryResident] : [.wallClock],
    warmupIterations: 1,
    maxDuration: .seconds(10),
    maxIterations: maxIterations,
    thresholds: thresholds()
) }

// MARK: AlloyCore fixtures

/// Repo-relative file (the test fixtures live in `Tests/AlloyCoreTests/Fixtures`).
private func repoFile(_ path: String) -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { url.deleteLastPathComponent() }
    return url.appendingPathComponent(path)
}

private func fixtureData(_ name: String) -> Data {
    guard let data = try? Data(contentsOf: repoFile("Tests/AlloyCoreTests/Fixtures/\(name).jsonl")) else { fatalError("missing fixture \(name)") }
    return data
}

private func fixtureLines(_ names: [String]) -> [Data] {
    names.flatMap { fixtureData($0).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) } }
}

/// 10,000 stream-json lines, cycling through the recorded wire fixtures.
private let wireLines: [Data] = {
    let base = fixtureLines(["edit-turn", "write-create", "write-update", "failed-tool", "thinking-summarized", "permission-allow"])
    return (0..<10_000).map { base[$0 % base.count] }
}()

/// A 5,000-record transcript: 2,500 turns, each a real user record and a real assistant text record from the fixture.
private let transcriptData: Data = {
    let lines = fixtureData("transcript-sample").split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        .map { String(decoding: $0, as: UTF8.self) }
    guard let user = lines.first(where: { $0.contains("\"type\":\"user\"") && $0.contains("Count slowly") }),
          let text = lines.first(where: { $0.contains("\"type\":\"assistant\"") && $0.contains("\"type\":\"text\"") })
    else { fatalError("transcript-sample.jsonl has no user/text records") }
    var out = ""
    for i in 0..<2_500 {
        out += user.replacingOccurrences(of: "Count slowly", with: "Turn \(i)")
            .replacingOccurrences(of: "\"uuid\":\"", with: "\"uuid\":\"\(String(format: "%08x", i))-") + "\n"
        out += text.replacingOccurrences(of: "msg_011CgpN8BnZCML4fUeSY6CTQ", with: "msg_\(i)")
            .replacingOccurrences(of: "msg_011CgpN7ysh9bQP2uPwAfYr6", with: "msg_\(i)") + "\n"
    }
    return Data(out.utf8)
}()

/// 500 single-line replacements by one Claude session on `text`, applied to a fresh ledger.
private func ledgerWithEdits(_ text: String, session: UUID) -> FileLedger {
    var ledger = FileLedger(path: "medium.rs", baseline: text)
    var lines = TextLines(text).lines
    for i in 0..<500 {
        let at = (i * 9) % lines.count   // 0-based
        let new = "let edited\(i) = \(i);"
        let hunk = PatchHunk(oldStart: at + 1, oldLines: 1, newStart: at + 1, newLines: 1, lines: ["-" + lines[at], "+" + new])
        ledger.applyPatch(author: .session(session), originalFile: nil, hunks: [hunk], toolUseID: "t\(i)", date: Date(timeIntervalSince1970: Double(i)))
        lines[at] = new
    }
    return ledger
}

/// The `OverlapIndexTests` large-file setup: a 5,000-line file with 200 edits split between two sessions.
@MainActor private final class OverlapRig {
    let session: UUID
    let index: OverlapIndex

    init() {
        let a = UUID(), b = UUID()
        let big = (1...5_000).map { "let value\($0) = \($0)\n" }.joined()
        var ledger = FileLedger(path: "big.swift", baseline: big)
        var lines = TextLines(big).lines
        for i in 0..<200 {
            let at = 10 + i * 24 - 1
            let new = "let edited\(i) = 0"
            let hunk = PatchHunk(oldStart: at + 1, oldLines: 1, newStart: at + 1, newLines: 1, lines: ["-" + lines[at], "+" + new])
            ledger.applyPatch(author: .session(i % 2 == 0 ? a : b), originalFile: nil, hunks: [hunk], toolUseID: nil, date: Date(timeIntervalSince1970: 1_000))
            lines[at] = new
        }
        let final = ledger
        index = OverlapIndex(ledger: { $0 == "big.swift" ? final : nil }, document: { _ in nil })
        session = a
    }

    func query(_ count: Int) {
        for i in 0..<count {
            let start = 2 + (i * 7) % 4_900
            blackHole(index.overlaps(for: session, range: LineRange(path: "big.swift", lines: start...(start + 1))))
        }
    }
}

let benchmarks: @Sendable () -> Void = {
    Benchmark("HighlightEngine open+viewport small", configuration: configuration()) { _ in await openAndViewport(small) }
    Benchmark("HighlightEngine open+viewport medium", configuration: configuration()) { _ in await openAndViewport(medium) }
    // 2.2 MB is over the engine's windowed threshold, so this exercises the windowed path.
    Benchmark("HighlightEngine open+viewport large", configuration: configuration()) { _ in await openAndViewport(large) }

    // One edit plus a viewport read, 100 times per iteration (per 100 keystrokes; divide by 100).
    Benchmark(
        "HighlightEngine keystroke medium",
        configuration: configuration()
    ) { benchmark in
        let rig = await TypingRig(medium)
        let engine = HighlightEngine()
        let id = UUID()
        await engine.open(id: id, language: .rust, text: medium, version: rig.version)
        let middle = medium.utf8.count / 2
        benchmark.startMeasurement()
        for i in 0..<100 {
            let typed = await rig.type("x", at: middle + i)
            await engine.edit(id: id, edits: typed.edits, newText: typed.text, version: typed.version)
            blackHole(await engine.captures(id: id, byteRange: (middle - 2_000)..<(middle + 2_000), minVersion: typed.version))
        }
        benchmark.stopMeasurement()
        await engine.close(id: id)
    }

    Benchmark("CodeBuffer typing", configuration: configuration()) { benchmark in
        let rig = await TypingRig(large)
        let middle = large.utf8.count / 2
        benchmark.startMeasurement()
        await rig.typeAndSnapshot(count: 1_000, at: middle)
        benchmark.stopMeasurement()
    }

    Benchmark("EditHistory apply", configuration: configuration(maxIterations: 5)) { benchmark in
        let session = UUID()
        benchmark.startMeasurement()
        let ledger = ledgerWithEdits(medium, session: session)
        blackHole(ledger.lineOwners())   // line attribution for every line
        benchmark.stopMeasurement()
    }

    Benchmark("OverlapIndex query", configuration: configuration(maxIterations: 15)) { benchmark in
        let rig = await OverlapRig()
        benchmark.startMeasurement()
        await rig.query(1_000)
        benchmark.stopMeasurement()
    }

    Benchmark("Wire decode", configuration: configuration(maxIterations: 30)) { benchmark in
        benchmark.startMeasurement()
        for line in wireLines { blackHole(InboundDecoder.decode(line)) }
        benchmark.stopMeasurement()
    }

    Benchmark("Transcript replay", configuration: configuration(maxIterations: 20, memory: false)) { benchmark in
        benchmark.startMeasurement()
        var transcript = Transcript(projectRoot: URL(fileURLWithPath: "/tmp/alloy-bench"))
        _ = TranscriptFile.forEachMessage(in: transcriptData) { transcript.apply($0, now: $1) }
        transcript.finishReplay()
        blackHole(transcript.blocks.count)
        benchmark.stopMeasurement()
    }
}
