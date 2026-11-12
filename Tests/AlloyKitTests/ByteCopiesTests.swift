@testable import AlloyCore
@testable import AlloyKit
import AlloyHighlight
import Darwin
import Foundation
import MetalUI
import MetalUICodeBuffer
import Testing

/// Live malloc bytes over all zones: a retained copy of a file shows up here exactly, where `phys_footprint` is noisy.
enum Heap {
    static var bytes: Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }
}

private let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Bench/Corpus/large.rs")

/// The open file's bytes are held once (the buffer's rope), not once per consumer. Corpus `large.rs` is 2.17 MiB;
/// before the fix, reading it held 2x the file (a leaked `Data` beside the array) and the highlight engine kept a
/// whole second copy of a windowed document. Other suites allocate in parallel, so each probe takes the smallest of
/// a few attempts.
@MainActor
@Suite(.serialized)
struct ByteCopiesTests {
    private static func smallest(_ attempts: Int = 4, _ body: () async throws -> Int) async rethrows -> Int {
        var best = Int.max
        for _ in 0..<attempts { best = min(best, try await body()) }
        return best
    }

    @Test func readHoldsOneCopy() async throws {
        let size = try #require(FileManager.default.attributesOfItem(atPath: corpus.path)[.size] as? Int)
        let held = await Self.smallest {
            let before = Heap.bytes
            let result = Workspace.readForEditing(url: corpus)
            let delta = Heap.bytes - before
            guard case .text(let bytes, _, let truncated) = result else { Issue.record("unreadable"); return 0 }
            #expect(bytes.count == size && !truncated)
            return delta
        }
        // One array of the file's bytes (plus the hint's spare byte), not two.
        #expect(held < size + size / 10, "readForEditing retained \(held) bytes for a \(size) byte file")
    }

    @Test func readMatchesFile() throws {
        let direct = try Data(contentsOf: corpus)
        guard case .text(let bytes, _, _) = Workspace.readForEditing(url: corpus) else { Issue.record("unreadable"); return }
        #expect(Data(bytes) == direct)
    }

    @Test func windowedEngineKeepsNoSecondCopy() async throws {
        guard case .text(let bytes, _, _) = Workspace.readForEditing(url: corpus) else { Issue.record("unreadable"); return }
        let buffer = CodeBuffer(utf8: bytes)
        let snapshot = buffer.snapshot()
        let size = snapshot.utf8Count
        let engine = HighlightEngine()
        let retained = await Self.smallest { () -> Int in
            let id = UUID()
            let before = Heap.bytes
            await engine.open(id: id, language: .rust, snapshot: snapshot, version: snapshot.version)
            let first = await engine.captures(id: id, byteRange: 0..<4000)
            #expect(!first.runs.isEmpty)
            let delta = Heap.bytes - before
            await engine.close(id: id)
            return delta
        }
        // One window's tree-sitter tree (about 2.9 MB for the default 128 KiB window) and its bytes. Before the fix the
        // engine also held every byte of the file (5.1 MB measured), so 1.4x the file sits between the two.
        #expect(retained < size * 14 / 10, "the engine retained \(retained) bytes beside a \(size) byte buffer")
        withExtendedLifetime(buffer) {}
    }
}
