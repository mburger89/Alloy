import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct ChatStyleTests {
    @Test func everyKindHasDistinctIconAndTint() {
        let kinds: [BlockKind] = [.thinking, .read, .shell, .edit, .web, .error, .question]
        let tints = kinds.map { BlockStyle.style($0).tint }
        #expect(Set(tints).count == kinds.count)
        for kind in BlockKind.allCases { #expect(!BlockStyle.style(kind).icon.isEmpty, "\(kind)") }
        #expect(BlockKind.allCases.count == 18)
        // Icons are distinct except where kinds deliberately share a family (none do).
        #expect(Set(BlockKind.allCases.map { BlockStyle.style($0).icon }).count == BlockKind.allCases.count)
    }

    @Test func thinkingCollapsesAfterText() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let t = rig.transports[0]
        await t.emit(.delta(.blockStart(index: 0, kind: "thinking")))
        await t.emit(.delta(.thinking(index: 0, "weighing the options", estimatedTokens: nil)))
        try await settle { session.transcript.blocks.count == 1 }
        let window = try alloyWindow(rig.workspace)
        guard case .thinking(let id, _, _) = session.transcript.blocks[0] else { Issue.record("no thinking"); return }
        try await window.runUntil { (try? window.element(label: "weighing the options")) != nil }
        await t.emit(.delta(.blockStart(index: 1, kind: "text")))
        await t.emit(.delta(.text(index: 1, "the answer")))
        try await window.runUntil { (try? window.element(label: "the answer")) != nil }
        #expect((try? window.element(identifier: "block-header-\(id)")) != nil)
        #expect((try? window.element(label: "weighing the options")) == nil)
    }

    @Test func clickHeaderExpands() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let t = rig.transports[0]
        await t.emit(.assistantBlock(messageID: "m1", block: .toolUse(id: "r1", name: "Read",
                                                                      input: .object(["file_path": .string("/x/a.swift")]))))
        await t.emit(.toolResult(ToolResultMessage(toolUseID: "r1", isError: false, text: "file body text", result: .none)))
        try await settle { session.transcript.blocks.contains { if case .tool(let b) = $0 { b.resultText == "file body text" } else { false } } }
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "block-header-r1")) != nil }
        #expect((try? window.element(label: "file body text")) == nil)
        try window.click(window.element(identifier: "block-header-r1"))
        try await window.runUntil { (try? window.element(label: "file body text")) != nil }
        // Collapsing again hides it, and the state survives a re-render.
        try window.click(window.element(identifier: "block-header-r1"))
        try await window.runUntil { (try? window.element(label: "file body text")) == nil }
    }

    @Test func transcriptFollowsBottom() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        for i in 0..<200 { await rig.transports[0].emit(.localCommandOutput(text: "notice \(i)")) }
        try await settle { session.transcript.blocks.count == 200 }
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(label: "notice 199")) != nil }
        let last = try window.element(label: "notice 199")
        #expect(last.frame.origin.y >= 0)
        #expect(last.frame.origin.y + last.frame.size.height <= Pixels(800), "\(last.frame)")
    }
}

@MainActor
private func settle(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<20_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("timed out")
    throw CancellationError()
}
