import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// While a reply streams, only the streaming row's bodies run: the rows above it replay (`.equatable()`).
@MainActor
@Suite struct TranscriptRowRerunTests {
    static let names = ["ChatBlockView", "AssistantText", "MarkdownText", "TranscriptView", "UserBubble", "ThinkingRow", "NoticeRow", "SessionMessageRow", "PermissionCard", "ToolBlockView", "BlockChrome"]

    struct Run { var rerun: [String: Int] = [:]; var requests = 0; var prepaints = 0; var deltas = 0 }

    /// 22 mixed blocks (user, markdown, thinking, tools), then an assistant block streamed in `deltas` pieces.
    private func scenario(deltas: Int = 30) async throws -> (Rig, Session, TestWindow, Run) {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let t = rig.transports[0]
        for i in 0..<5 {
            await rig.workspace.send(OutgoingMessage(text: "question \(i)", images: [], priority: .later), to: session.id)
            await t.emit(.assistantBlock(messageID: "th\(i)", block: .thinking("thinking about \(i)")))
            await t.emit(.assistantBlock(messageID: "tl\(i)", block: .toolUse(id: "tool\(i)", name: "Read", input: .object(["file_path": .string("/tmp/f\(i).txt")]))))
            await t.emit(.assistantBlock(messageID: "a\(i)", block: .text("Answer **\(i)** with `code`\n\nsecond paragraph")))
        }
        await t.emit(.controlRequest(ControlRequest(requestID: "pend", kind: .canUseTool(
            toolName: "Bash", input: .object([:]), description: "ls", toolUseID: nil, suggestions: []))))
        try await acpUntil { session.transcript.blocks.count >= 20 }
        let window = try alloyWindow(rig.workspace)
        for _ in 0..<30 { window.tick(); await Task.yield() }
        var run = Run()
        var text = "streaming"
        for i in 0..<deltas {
            text += " word\(i)"
            await t.emit(.assistantBlock(messageID: "stream", block: .text(text)))
            for _ in 0..<5 { await Task.yield() }
            window.resetFrameWork()
            let before = Self.names.map(BodyProbe.count)
            window.tick()
            for (k, n) in Self.names.enumerated() { run.rerun[n, default: 0] += BodyProbe.count(n) - before[k] }
            run.requests += window.frameWork.map(\.elementRequests).reduce(0, +)
            run.prepaints += window.frameWork.map(\.elementPrepaints).reduce(0, +)
            run.deltas += 1
        }
        return (rig, session, window, run)
    }

    @Test func measureStreamingRows() async throws {
        let (_, session, _, run) = try await scenario()
        let d = Double(run.deltas)
        print("ROWS ALL " + Self.names.map { "\($0)=\(Double(run.rerun[$0]!) / d)" }.joined(separator: " "))
        print("ROWS blocks=\(session.transcript.blocks.count) per-delta chat=\(Double(run.rerun["ChatBlockView"]!) / d) assistant=\(Double(run.rerun["AssistantText"]!) / d) markdown=\(Double(run.rerun["MarkdownText"]!) / d) transcript=\(Double(run.rerun["TranscriptView"]!) / d) requests=\(Double(run.requests) / d) prepaints=\(Double(run.prepaints) / d)")
    }

    /// Before: 23.9 ChatBlockView, 17.9 AssistantText, 17.9 MarkdownText, 1.4 UserBubble, 1.8 ThinkingRow, 2.0 ToolBlockView and
    /// 0.8 PermissionCard bodies per delta (every visible row). After: 1 each of the first three (the streaming row), 0 of the rest.
    @Test func onlyTheStreamingRowRerunsPerDelta() async throws {
        let (_, _, _, run) = try await scenario()
        let d = Double(run.deltas)
        print("ROWS per-delta chat=\(Double(run.rerun["ChatBlockView"]!) / d) assistant=\(Double(run.rerun["AssistantText"]!) / d) markdown=\(Double(run.rerun["MarkdownText"]!) / d) requests=\(Double(run.requests) / d) prepaints=\(Double(run.prepaints) / d)")
        #expect(run.rerun["ChatBlockView"]! <= run.deltas, "ChatBlockView \(run.rerun["ChatBlockView"]!)")
        #expect(run.rerun["AssistantText"]! <= run.deltas)
        #expect(run.rerun["MarkdownText"]! <= run.deltas)
    }

    private func visibleText(_ window: TestWindow, _ id: String) -> String {
        guard let block = try? window.element(identifier: "block-\(id)") else { return "" }
        return descendants(of: block, in: window).compactMap { $0.value ?? $0.label }.joined(separator: "\n")
    }

    @Test func collapsingStillWorksAfterReplayedFrames() async throws {
        let (rig, session, window, _) = try await scenario(deltas: 12)
        let thinking = try #require(session.transcript.blocks.last { if case .thinking = $0 { true } else { false } })
        func thinkingShown() -> Bool { (try? window.element(label: "thinking about 4")) != nil }
        func shellShown() -> Bool { (try? window.element(label: "shell-out-line")) != nil }
        // A thinking row starts collapsed (text follows it), then expands and collapses on its header.
        #expect(!thinkingShown())
        try window.click(window.element(identifier: "block-header-\(thinking.id)"))
        try await window.runUntil { thinkingShown() }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        try window.click(window.element(identifier: "block-header-\(thinking.id)"))
        try await window.runUntil { !thinkingShown() }
        // A shell tool row (expanded by default) collapses and expands again, after more replayed frames.
        await rig.transports[0].emit(.assistantBlock(messageID: "shm", block: .toolUse(
            id: "sh9", name: "Bash", input: .object(["command": .string("echo")]))))
        await rig.transports[0].emit(.toolResult(ToolResultMessage(toolUseID: "sh9", isError: false, text: "shell-out-line", result: .none)))
        try await window.runUntil { shellShown() }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        try window.click(window.element(identifier: "block-header-sh9"))
        try await window.runUntil { !shellShown() }
        try window.click(window.element(identifier: "block-header-sh9"))
        try await window.runUntil { shellShown() }
    }

    @Test func aThinkingRowCollapsesWhenTextFollowsIt() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.assistantBlock(messageID: "t", block: .thinking("pondering the login")))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(label: "pondering the login")) != nil }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        await rig.transports[0].emit(.assistantBlock(messageID: "a", block: .text("done")))
        try await window.runUntil { session.transcript.blocks.count == 2 && (try? window.element(label: "pondering the login")) == nil }
    }

    @Test func aPermissionCardStillShowsItsState() async throws {
        let (rig, _, window, _) = try await scenario(deltas: 12)
        await rig.transports[0].emit(.controlRequest(ControlRequest(requestID: "r1", kind: .canUseTool(
            toolName: "Bash", input: .object([:]), description: "ls", toolUseID: nil, suggestions: []))))
        try await window.runUntil { (try? window.element(identifier: "approve-r1")) != nil }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        try window.click(window.element(identifier: "approve-r1"))
        try await window.runUntil { (try? window.element(label: "Allowed")) != nil }
        #expect((try? window.element(identifier: "approve-r1")) == nil)
    }
}
