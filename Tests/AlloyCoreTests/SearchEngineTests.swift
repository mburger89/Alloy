import Foundation
import AlloyTestSupport
import MetalUICodeBuffer
import Testing

@testable import AlloyCore

private actor Probe {
    var entered: [String] = []
    var released = false
    func enter(_ p: String) { entered.append(p) }
    func release() { released = true }
    func waitUntil(timeout: Duration = .seconds(5), _ cond: @Sendable ([String]) -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if cond(entered) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
    func waitReleased() async {
        while !released, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

private func makeProject(_ files: [String: Data]) throws -> URL {
    let root = TempFiles.url("alloy-search")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (name, data) in files {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    return root
}

private func text(_ s: String) -> Data { Data(s.utf8) }

private func collect(_ stream: AsyncStream<SearchBatch>) async -> (batches: [SearchBatch], files: [SearchFileResult], facts: SearchSummaryFacts?) {
    var batches: [SearchBatch] = []
    for await b in stream { batches.append(b) }
    return (batches, batches.flatMap(\.files), batches.last?.finished)
}

@Suite struct SearchEngineTests {
    private func search(_ engine: SearchEngine, _ q: SearchQuery, paths: [String], truncated: Bool = false,
                        overlays: [String: CodeSnapshot] = [:], max: Int = 10_000) async -> AsyncStream<SearchBatch> {
        await engine.run(q, paths: paths, indexTruncated: truncated, overlays: overlays, extraExclude: [], maxResults: max)
    }

    @Test func productLimits() {
        let l = SearchLimits()
        #expect(l.maxFileBytes == Workspace.previewLimit)
        #expect(l.workers == 4 && l.reorderWindow == 256 && l.maxFiles == 2_000 && l.flushMatches == 500)
        #expect(l.largeFileBytes == 4 * 1024 * 1024 && l.binaryProbe == 8 * 1024)
    }

    @Test func resultsArriveInIndexOrderWhenALaterFileFinishesFirst() async throws {
        var files: [String: Data] = [:]
        let paths = (0..<8).map { "f\($0).txt" }
        for p in paths { files[p] = text("needle in \(p)\n") }
        let root = try makeProject(files)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SearchEngine(root: root)
        let probe = Probe()
        await engine.setScanGate { path in
            await probe.enter(path)
            if path == "f0.txt" { _ = await probe.waitUntil { $0.contains("f3.txt") } }
        }
        let r = await collect(await search(engine, SearchQuery(text: "needle"), paths: paths))
        #expect(r.files.map(\.path) == paths)
        #expect(r.files.map(\.index) == Array(0..<8))
        #expect(r.facts?.totalFiles == 8)
    }

    @Test func workersPauseWhenTheHeadFileIsHeld() async throws {
        var files: [String: Data] = [:]
        let paths = (0..<100).map { "f\($0).txt" }
        for p in paths { files[p] = text("needle\n") }
        let root = try makeProject(files)
        defer { try? FileManager.default.removeItem(at: root) }
        var limits = SearchLimits()
        limits.reorderWindow = 8
        let engine = SearchEngine(root: root, limits: limits)
        let probe = Probe()
        await engine.setScanGate { path in
            await probe.enter(path)
            if path == "f0.txt" { await probe.waitReleased() }
        }
        let stream = await search(engine, SearchQuery(text: "needle"), paths: paths)
        let consumer = Task { await collect(stream) }
        _ = await probe.waitUntil { $0.count >= 8 }
        try await Task.sleep(for: .milliseconds(300))
        let held = await probe.entered.count
        #expect(held <= 8, "workers ran \(held) files ahead of the held head")
        await probe.release()
        let r = await consumer.value
        #expect(r.files.map(\.index) == Array(0..<100))
    }

    @Test func matchCapStopsAndFlags() async throws {
        let body = String(repeating: "needle\n", count: 100)
        var files: [String: Data] = [:]
        let paths = (0..<5).map { "f\($0).txt" }
        for p in paths { files[p] = text(body) }
        let root = try makeProject(files)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = await collect(await search(SearchEngine(root: root), SearchQuery(text: "needle"), paths: paths, max: 250))
        #expect(r.facts?.cappedMatches == true)
        #expect(r.facts?.totalMatches == 250)
        #expect(r.files.reduce(0) { $0 + $1.matches.count } == 250)
        #expect(r.facts?.cappedFiles == false)
    }

    @Test func fileCapStopsAndFlags() async throws {
        var files: [String: Data] = [:]
        let paths = (0..<2_100).map { "f\($0).txt" }
        for p in paths { files[p] = text("needle\n") }
        let root = try makeProject(files)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = await collect(await search(SearchEngine(root: root), SearchQuery(text: "needle"), paths: paths))
        #expect(r.facts?.cappedFiles == true)
        #expect(r.facts?.totalFiles == 2_000)
        #expect(r.files.count == 2_000)
    }

    @Test func skipsBinaryHugeAndLongRegexLines() async throws {
        var binary = Data("needle\n".utf8)
        binary.append(0)
        let long = String(repeating: "x", count: 70_000) + " needle\n"
        let root = try makeProject([
            "a.bin": binary, "b.txt": Data(repeating: UInt8(ascii: "n"), count: 3_000), "c.txt": text(long),
            "d.txt": text("needle\n"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        var limits = SearchLimits()
        limits.maxFileBytes = 2_000
        limits.largeFileBytes = 1_000_000
        // c.txt is over the shrunk limit too, so check the regex long-line skip with the product size limit separately.
        let r = await collect(await search(SearchEngine(root: root, limits: limits), SearchQuery(text: "needle"),
                                           paths: ["a.bin", "b.txt", "c.txt", "d.txt"]))
        #expect(r.files.map(\.path) == ["d.txt"])
        #expect(r.facts?.skipped == 3)

        let r2 = await collect(await search(SearchEngine(root: root), SearchQuery(text: "need\\w+", regex: true),
                                            paths: ["c.txt", "d.txt"]))
        #expect(r2.files.map(\.path) == ["d.txt"])
        #expect(r2.facts?.skipped == 1)
    }

    @MainActor @Test func overlayWinsOverDisk() async throws {
        let root = try makeProject(["f.txt": text("disk only\n"), "g.txt": text("needle on disk\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let overlay = CodeBuffer(utf8: Array("é😀\nunsaved needle\n".utf8)).snapshot()
        let r = await collect(await search(SearchEngine(root: root), SearchQuery(text: "needle"),
                                           paths: ["f.txt", "g.txt"], overlays: ["f.txt": overlay, "g.txt": CodeBuffer(utf8: []).snapshot()]))
        #expect(r.files.map(\.path) == ["f.txt"])
        let m = try #require(r.files.first?.matches.first)
        #expect(m.line == 2)
        #expect(overlay.text(in: m.range) == "needle")
    }

    @Test func invalidUTF8IsSearchedAndFlagged() async throws {
        var bytes = Data("needle ".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE])
        let root = try makeProject(["bad.txt": bytes, "ok.txt": text("needle\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let r = await collect(await search(SearchEngine(root: root), SearchQuery(text: "needle"), paths: ["bad.txt", "ok.txt"]))
        #expect(r.files.map(\.isUTF8) == [false, true])
    }

    @Test func cancellingTheConsumerStopsScanning() async throws {
        var files: [String: Data] = [:]
        let paths = (0..<300).map { "f\($0).txt" }
        for p in paths { files[p] = text("needle\n") }
        let root = try makeProject(files)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SearchEngine(root: root)
        let probe = Probe()
        await engine.setScanGate { path in
            await probe.enter(path)
            try? await Task.sleep(for: .milliseconds(10))
        }
        let stream = await search(engine, SearchQuery(text: "needle"), paths: paths)
        let first = Probe()
        let consumer = Task {
            for await b in stream where !b.files.isEmpty { await first.enter("batch") }
        }
        _ = await first.waitUntil { !$0.isEmpty }
        consumer.cancel()   // cancelling the consuming task terminates the stream
        _ = await consumer.value
        try await Task.sleep(for: .milliseconds(200))
        let a = await probe.entered.count
        try await Task.sleep(for: .milliseconds(300))
        let b = await probe.entered.count
        #expect(a == b, "scanning continued after the consumer left")
        #expect(b < 300)
    }

    @Test func indexTruncatedPassesThrough() async throws {
        let root = try makeProject(["f.txt": text("needle\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let r = await collect(await search(SearchEngine(root: root), SearchQuery(text: "needle"), paths: ["f.txt"], truncated: true))
        #expect(r.facts?.indexTruncated == true)
    }

    @Test func flushesAtFiveHundredMatches() async throws {
        let body = String(repeating: "needle\n", count: 300)
        let root = try makeProject(["a.txt": text(body), "b.txt": text(body), "c.txt": text(body)])
        defer { try? FileManager.default.removeItem(at: root) }
        let r = await collect(await search(SearchEngine(root: root), SearchQuery(text: "needle"), paths: ["a.txt", "b.txt", "c.txt"]))
        #expect(r.batches.count >= 2)
        #expect(r.batches.dropLast().allSatisfy { $0.finished == nil })
        #expect(r.facts?.totalMatches == 900)
        #expect(r.batches.dropLast().first.map { $0.files.reduce(0) { $0 + $1.matches.count } >= 500 } == true)
    }

    @Test func excludeAndInvalidQueries() async throws {
        let root = try makeProject(["a.txt": text("needle\n"), "dist/b.txt": text("needle\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SearchEngine(root: root)
        let r = await collect(await engine.run(SearchQuery(text: "needle"), paths: ["a.txt", "dist/b.txt"], indexTruncated: false,
                                               overlays: [:], extraExclude: ["dist"], maxResults: 100))
        #expect(r.files.map(\.path) == ["a.txt"])
        let bad = await collect(await search(engine, SearchQuery(text: "("), paths: ["a.txt"]))
        #expect(bad.files.isEmpty)
        #expect(bad.facts != nil)
    }

    @Test func onlyEmptyRegexMatchesAreReported() async throws {
        let root = try makeProject(["a.txt": text("b\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let r = await collect(await search(SearchEngine(root: root), SearchQuery(text: "a*", regex: true), paths: ["a.txt"]))
        #expect(r.files.isEmpty)
        #expect(r.facts?.onlyEmptyMatches == true)
    }
}
