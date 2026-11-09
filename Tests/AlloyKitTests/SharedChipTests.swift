@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SharedChipTests {
    @Test func captionCountsFiles() {
        #expect(UserBubble.sharedCaption(0) == nil)
        #expect(UserBubble.sharedCaption(1) == "shared: 1 file")
        #expect(UserBubble.sharedCaption(3) == "shared: 3 files")
    }

    @Test func sharedChipExpandsToExactLines() async throws {
        let rig = Rig()
        try "one\n".write(to: rig.root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "two\n".write(to: rig.root.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        let me = await rig.workspace.newSession(name: "me")
        let reader = UUID()
        for f in ["a.swift", "b.swift"] {
            let st = try #require(FileStamp.read(rig.root.appendingPathComponent(f).path))
            rig.workspace.readIndex.record(ReadEntry(session: reader, path: f, lines: nil, stamp: st, date: Date(), generation: 0))
        }
        await rig.workspace.send("compare @a.swift and @b.swift", to: me.id)
        guard case .user(let id, "compare @a.swift and @b.swift", _, _)? = me.transcript.blocks.first else {
            Issue.record("no bubble"); return
        }
        let files = try #require(rig.workspace.sharedFiles[id])
        #expect(files.count == 2)
        let window = try alloyWindow(rig.workspace)
        let chip = "user-shared-\(id.uuidString)", detail = "user-shared-detail-\(id.uuidString)"
        try await window.runUntil { (try? window.element(identifier: chip)) != nil }
        #expect(try window.element(identifier: chip).label == "shared: 2 files")
        #expect((try? window.element(identifier: detail)) == nil)
        try window.click(window.element(identifier: chip))
        try await window.runUntil { (try? window.element(identifier: detail)) != nil }
        let shown = try window.element(identifier: detail)
        #expect((shown.value ?? shown.label) == AlreadyRead.text(lines: files.map(\.line)))
        // Collapsing hides it again.
        try window.click(window.element(identifier: chip))
        try await window.runUntil { (try? window.element(identifier: detail)) == nil }
    }
}
