@testable import AlloyCore
@testable import AlloyKit
import AlloyHighlight
import Darwin
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("large.rs")
        try FileManager.default.copyItem(at: corpus, to: copy)
        let size = try #require(FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int, "size attribute")
        guard case .text(let bytes, _, let truncated) = Workspace.readForEditing(url: copy) else {
            let fd = open(copy.path, O_RDONLY)
            let why = fd < 0 ? "open failed: errno \(errno) \(String(cString: strerror(errno)))" : "open succeeded; the read or binary check failed"
            if fd >= 0 { close(fd) }
            Issue.record("read result is .text: got something else for \(size) bytes (\(why))")
            return
        }
        #expect(bytes.count == size, "byte count \(bytes.count) for a \(size) byte file")
        #expect(!truncated, "read result truncated a \(size) byte file")
        // One array read straight from the file, not a grown (doubled) one. malloc may hand a large request a bigger
        // cached block, so slack above the file size depends on heap state (3.2 MB for 2.2 MB seen after other suites);
        // doubling growth always reaches twice the size, so that is the deterministic line. A leaked `Data` copy is not
        // visible from here, and the read(2)-into-one-array path no longer creates a `Data`.
        #expect(bytes.capacity < 2 * size,
                "capacity: readForEditing holds \(bytes.capacity) bytes of capacity for \(bytes.count) bytes")
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
