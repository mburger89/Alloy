@testable import AlloyCore
@testable import AlloyKit
import AlloyHighlight
import Foundation
import MetalUI
import MetalUICodeBuffer
import Testing

private let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Bench/Corpus/large.rs")

/// The open file's bytes are held once (the buffer's rope), not once per consumer. Corpus `large.rs` is 2.17 MiB;
/// before the fix, reading it held 2x the file (a leaked `Data` beside the array) and the highlight engine kept a
/// whole second copy of a windowed document. Assertions are structural (array capacity, bytes the engine owns), not
/// process-wide heap deltas, which raced with suites allocating in parallel.
@MainActor
@Suite(.serialized)
struct ByteCopiesTests {
    @Test func readHoldsOneCopy() throws {
        let size = try #require(FileManager.default.attributesOfItem(atPath: corpus.path)[.size] as? Int)
        guard case .text(let bytes, _, let truncated) = Workspace.readForEditing(url: corpus) else { Issue.record("unreadable"); return }
        #expect(bytes.count == size && !truncated)
        // The result is one array sized from the file (plus the hint's spare byte), not a grown or doubled one. A
        // second, leaked `Data` copy is not visible from here; it is what the process-wide heap delta used to catch,
        // but that raced with parallel suites, and the read(2)-into-one-array path no longer creates a `Data`.
        #expect(bytes.capacity < size + size / 10, "readForEditing holds \(bytes.capacity) bytes of capacity for a \(size) byte file")
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
        let id = UUID()
        await engine.open(id: id, language: .rust, snapshot: snapshot, version: snapshot.version)
        // Opening a windowed document parses nothing and copies nothing: the rope is shared with the buffer.
        let opened = await engine.retainedByteCount(id: id)
        #expect(opened == 0, "open copied \(opened) bytes of a \(size) byte file")
        let first = await engine.captures(id: id, byteRange: 0..<4000)
        #expect(!first.runs.isEmpty)
        // After a capture the engine owns one window (64 KiB margins by default, a little more when snapped to a
        // top-level line), never the file. Before the fix it also held `bytes` = the whole file.
        let retained = await engine.retainedByteCount(id: id)
        #expect(retained > 0, "no window bytes after a capture")
        #expect(retained <= 4 * 65_536 && retained < size / 4,
                "the engine retained \(retained) bytes beside a \(size) byte buffer; expected only its window")
        await engine.close(id: id)
        let closed = await engine.retainedByteCount(id: id)
        #expect(closed == 0)
        withExtendedLifetime(buffer) {}
    }
}
