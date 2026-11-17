@testable import AlloyCore
@testable import AlloyKit
import AlloyHighlight
import Darwin
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// Regression probes for the `memory` parity metric (large file open, docs/parity.md). Heavy: they open the 100k-line
/// corpus file, so they run only with ALLOY_MEMPROBE=1. Run one probe per process for clean numbers, e.g.
/// `ALLOY_MEMPROBE=1 swift test --filter MemoryProbeTests/fullOpen`. Each prints `MEMPROBE <stage> <MiB>` deltas of
/// the process's phys_footprint; they assert nothing but a loose ceiling, since the numbers are the point.
enum Footprint {
    static var mib: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

private struct Marks {
    var last = Footprint.mib
    let start = Footprint.mib
    mutating func mark(_ stage: String) {
        let now = Footprint.mib
        print(String(format: "MEMPROBE %-28@ delta %8.2f MiB   total-since-start %8.2f MiB", stage as NSString, now - last, now - start))
        last = now
    }
}

private let corpusLarge = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Bench/Corpus/large.rs")
private let corpusLanguage: Language = .rust

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ALLOY_MEMPROBE"] == "1"))
struct MemoryProbeTests {
    /// The document model alone: bytes read, rope buffer, EditorDocument (saved snapshot).
    @Test func documentModel() async throws {
        var m = Marks()
        let result = Workspace.readForEditing(url: corpusLarge)
        guard case .text(let bytes, let stamp, _) = result else { Issue.record("unreadable"); return }
        m.mark("readForEditing bytes")
        let buffer = CodeBuffer(utf8: bytes)
        m.mark("CodeBuffer(utf8:)")
        let doc = EditorDocument(path: "large.rs", buffer: buffer, language: "rust", state: .editable, diskStamp: stamp)
        m.mark("EditorDocument")
        let snap = buffer.snapshot(); _ = snap.lineCount; _ = snap.line(50_000)
        m.mark("snapshot + line lookup")
        withExtendedLifetime((bytes, doc)) {}
    }

    /// The tree-sitter engine alone, fed like OpenDocumentView does (snapshot.text String, then bytes).
    /// Baseline: a whole-file tree (`windowedThreshold: .max` turns the windowed mode off) and a whole-file query.
    @Test func highlightEngineOpen() async throws {
        var m = Marks()
        guard case .text(let bytes, _, _) = Workspace.readForEditing(url: corpusLarge) else { return }
        let buffer = CodeBuffer(utf8: bytes)
        let snap = buffer.snapshot()
        m.mark("bytes+buffer (setup)")
        let engine = HighlightEngine(windowedThreshold: .max)
        let id = UUID()
        let text = snap.text
        m.mark("snapshot.text String")
        await engine.open(id: id, language: corpusLanguage, text: text, version: snap.version)
        m.mark("engine.open (parse tree)")
        let all = await engine.captures(id: id, byteRange: 0..<snap.utf8Count)
        m.mark("captures whole file (\(all.runs.count) runs)")
        let window = await engine.captures(id: id, byteRange: 0..<4000)
        m.mark("captures first 4000 bytes (\(window.runs.count))")
        await engine.close(id: id)
        m.mark("engine.close")
        withExtendedLifetime((bytes, text)) {}
    }

    /// The default engine (windowed above 1 MiB): open, then one viewport of captures, like the app does.
    @Test func highlightEngineOpenWindowed() async throws {
        var m = Marks()
        guard case .text(let bytes, _, _) = Workspace.readForEditing(url: corpusLarge) else { return }
        let buffer = CodeBuffer(utf8: bytes)
        let snap = buffer.snapshot()
        let text = snap.text
        m.mark("bytes+buffer+text (setup)")
        let before = Footprint.mib
        let engine = HighlightEngine()
        let id = UUID()
        await engine.open(id: id, language: corpusLanguage, text: text, version: snap.version)
        m.mark("engine.open (no parse)")
        let window = await engine.captures(id: id, byteRange: 0..<4000)
        m.mark("captures first 4000 bytes (\(window.runs.count))")
        let middle = snap.utf8Count / 2
        let mid = await engine.captures(id: id, byteRange: middle..<(middle + 4000))
        m.mark("captures middle 4000 bytes (\(mid.runs.count))")
        let grown = Footprint.mib - before
        print(String(format: "MEMPROBE windowed engine total growth %.2f MiB", grown))
        #expect(!window.runs.isEmpty)
        #expect(grown < 40, "windowed engine grew \(grown) MiB")
        await engine.close(id: id)
        withExtendedLifetime((bytes, text)) {}
    }

    /// The real app path: Workspace.open, root view in a headless window, run until painted and highlighted.
    /// `ALLOY_MEMPROBE_NAME` (default large.rs) renames the copied corpus file: `large.txt` has no grammar, so the
    /// difference to `large.rs` is the highlight engine's share.
    @Test func fullOpen() async throws {
        var m = Marks()
        let name = ProcessInfo.processInfo.environment["ALLOY_MEMPROBE_NAME"] ?? "large.rs"
        let rig = Rig()
        try FileManager.default.copyItem(at: corpusLarge, to: rig.root.appendingPathComponent(name))
        rig.workspace.openFilePath = name
        let window = try alloyWindow(rig.workspace)
        m.mark("window + rig (no file yet)")
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        m.mark("code-view exists")
        for _ in 0..<20 { window.tick(); try await Task.sleep(for: .milliseconds(50)) }
        m.mark("20 more ticks / 1 s settle")
        try await Task.sleep(for: .seconds(3))
        window.tick()
        m.mark("3 s settle")
        let doc = try #require(rig.workspace.document(name))
        print("MEMPROBE lines=\(doc.buffer.snapshot().lineCount) ledgerHasFile=\(rig.workspace.ledger.files[name] != nil)")
        withExtendedLifetime((window, rig)) {}
    }

    /// `fullOpen` in Code mode: the same file in the one editor group. Run in its own process after `fullOpen`'s, and pass
    /// Chat's `total-since-start` as `ALLOY_MEMPROBE_CHAT_MIB` to assert the spec's anti-goal: resident growth within 1.05x
    /// of Chat's. Without it the number is only printed.
    @Test func codeModeFullOpen() async throws {
        var m = Marks()
        let name = ProcessInfo.processInfo.environment["ALLOY_MEMPROBE_NAME"] ?? "large.rs"
        let rig = Rig()
        try FileManager.default.copyItem(at: corpusLarge, to: rig.root.appendingPathComponent(name))
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let group = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open(name, in: .group(group))
        let window = try alloyWindow(rig.workspace)
        m.mark("window + rig (file open)")
        let id = "code-view-\(group.uuidString)"
        try await window.runUntil { (try? window.element(identifier: id)) != nil }
        m.mark("code view exists")
        for _ in 0..<20 { window.tick(); try await Task.sleep(for: .milliseconds(50)) }
        m.mark("20 more ticks / 1 s settle")
        try await Task.sleep(for: .seconds(3))
        window.tick()
        m.mark("3 s settle")
        let total = Footprint.mib - m.start
        print(String(format: "MEMPROBE code-mode total growth %.2f MiB", total))
        if let chat = ProcessInfo.processInfo.environment["ALLOY_MEMPROBE_CHAT_MIB"].flatMap(Double.init) {
            #expect(total <= chat * 1.05, "Code mode grew \(total) MiB, Chat \(chat) MiB")
        }
        withExtendedLifetime((window, rig)) {}
    }

    /// `codeModeFullOpen` with 1,000 folds closed on the large file: the fold state and the placeholders must not move
    /// resident growth past Chat's (when `ALLOY_MEMPROBE_CHAT_MIB` is given) and stay a few MiB. Run in its own process.
    @Test func foldsThousand() async throws {
        var m = Marks()
        let name = ProcessInfo.processInfo.environment["ALLOY_MEMPROBE_NAME"] ?? "large.rs"
        let rig = Rig()
        try FileManager.default.copyItem(at: corpusLarge, to: rig.root.appendingPathComponent(name))
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let group = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open(name, in: .group(group))
        let window = try alloyWindow(rig.workspace)
        let id = "code-view-\(group.uuidString)"
        try await window.runUntil { (try? window.element(identifier: id)) != nil }
        for _ in 0..<20 { window.tick(); try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .seconds(3))
        window.tick()
        m.mark("code view settled, no folds")
        let before = Footprint.mib - m.start
        // 1,000 folds over the file's lines, set through the same path the coordinator uses.
        let doc = try #require(rig.workspace.document(name))
        let lines = doc.buffer.snapshot().lineCount
        let step = max(3, lines / 1000)
        let ranges = (0..<1000).map { FoldRange(startLine: $0 * step, endLine: $0 * step + 1) }.filter { $0.endLine + 1 < lines }
        rig.workspace.applyFoldRanges(path: name, choice: FoldChoice(source: .indentation, ranges: ranges), version: doc.buffer.version)
        let state = try #require(rig.workspace.foldState(for: name, in: .group(group)))
        state.folded = state.foldableRanges
        for _ in 0..<20 { window.tick(); try await Task.sleep(for: .milliseconds(50)) }
        m.mark("\(state.folded.count) folds")
        let total = Footprint.mib - m.start
        print(String(format: "MEMPROBE folds total growth %.2f MiB (folds added %.2f MiB)", total, total - before))
        #expect(total - before < 16, "1,000 folds added \(total - before) MiB")
        if let chat = ProcessInfo.processInfo.environment["ALLOY_MEMPROBE_CHAT_MIB"].flatMap(Double.init) {
            #expect(total <= chat * 1.05, "Code mode with folds grew \(total) MiB, Chat \(chat) MiB")
        }
        withExtendedLifetime((window, rig)) {}
    }
}
