@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// While a reply streams, only the streaming row's bodies run: the rows above it replay (`.equatable()`).
@MainActor
@Suite struct TranscriptRowRerunTests {
    static let names = ["ChatBlockView", "AssistantText", "MarkdownText", "TranscriptView", "UserBubble", "ThinkingRow", "NoticeRow", "SessionMessageRow", "PermissionCard", "ToolBlockView", "BlockChrome", "QuestionCard", "PlanCard", "MarkdownTopBlock"]

    struct Run { var rerun: [String: Int] = [:]; var requests = 0; var prepaints = 0; var deltas = 0 }

    /// 22 mixed blocks (user, markdown, thinking, tools), then an assistant block streamed in `deltas` pieces.
    private func fixture(_ name: String) throws -> [Data] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
    }

    /// `extras` adds a command-output notice, a session message, a pending question and a pending plan before the
    /// streamed block.
    /// `streamed` makes the reply one block that really streams (a block start, then a text delta per step): it takes the
    /// delta's index and returns the text to append. Without it each step emits a new block, as the older benchmarks do.
    private func scenario(deltas: Int = 30, extras: Bool = false, streamed: ((Int) -> String)? = nil) async throws -> (Rig, Session, TestWindow, Run) {
        let rig = Rig()
        let other = extras ? await rig.workspace.newSession(name: "Bea") : nil
        let session = await rig.workspace.newSession(name: "A")
        let t = rig.transports[extras ? 1 : 0]
        for i in 0..<(extras ? 2 : 5) {
            await rig.workspace.send(OutgoingMessage(text: "question \(i)", images: [], priority: .later), to: session.id)
            await t.emit(.assistantBlock(messageID: "th\(i)", block: .thinking("thinking about \(i)")))
            await t.emit(.assistantBlock(messageID: "tl\(i)", block: .toolUse(id: "tool\(i)", name: "Read", input: .object(["file_path": .string("/tmp/f\(i).txt")]))))
            await t.emit(.assistantBlock(messageID: "a\(i)", block: .text("Answer **\(i)** with `code`\n\nsecond paragraph")))
        }
        await t.emit(.controlRequest(ControlRequest(requestID: "pend", kind: .canUseTool(
            toolName: "Bash", input: .object([:]), description: "ls", toolUseID: nil, suggestions: []))))
        if let other {
            await t.emit(.notice(kind: .commandOutput, text: "notice-out **bold**"))
            if case .failure(let e) = rig.workspace.deliverSessionMessage(from: other.id, to: session.id, text: "hello A") { Issue.record("\(e)") }
            let plan = try fixture("plan-allow").filter { String(decoding: $0, as: UTF8.self).contains("control_request") }
            await t.emit(fixture: try fixture("ask-question") + plan)
        }
        try await acpUntil {
            session.transcript.blocks.count >= (extras ? 8 : 20)
                && (!extras || (session.transcript.blocks.contains { if case .plan = $0 { true } else { false } }
                    && session.transcript.blocks.contains { if case .sessionMessage = $0 { true } else { false } }))
        }
        rig.workspace.selectedSessionID = session.id
        // A tall window, so the notice, the message, the question and the plan are all on screen at once.
        let window = try alloyWindow(rig.workspace, height: extras ? 3000 : 800)
        for _ in 0..<30 { window.tick(); await Task.yield() }
        var run = Run()
        var text = "streaming"
        if streamed != nil { await t.emit(.delta(.blockStart(index: 0, kind: "text"))) }
        for i in 0..<deltas {
            if let streamed { await t.emit(.delta(.text(index: 0, streamed(i)))) } else {
                text += " word\(i)"
                await t.emit(.assistantBlock(messageID: "stream", block: .text(text)))
            }
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

    /// About 25 KB of Markdown in about 150 top-level blocks (paragraphs, three fences, a list and a table).
    static func longReply() -> String {
        var parts: [String] = []
        for i in 0..<150 {
            switch i {
            case 30, 80, 130: parts.append("```swift\nlet value\(i) = compute(\(i))\nprint(value\(i))\n```")
            case 50: parts.append((0..<6).map { "- item \($0) of the list" }.joined(separator: "\n"))
            case 100: parts.append("| name | value |\n| --- | --- |\n| alpha | 1 |\n| beta | 2 |\n| gamma | 3 |")
            default: parts.append("Paragraph \(i) of the long reply with **bold** and `code`, then plain words to fill a line or two of the transcript so the block wraps. " + String(repeating: "more words ", count: 3))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// `longReply()` cut into `count` consecutive chunks.
    static func longReplyChunks(_ count: Int) -> [String] {
        let characters = Array(longReply())
        let size = (characters.count + count - 1) / count
        return stride(from: 0, to: characters.count, by: size).map { String(characters[$0..<min($0 + size, characters.count)]) }
    }

    /// The long reply streamed in 30 deltas at the bottom, then scrolled from the bottom to the top in 20 equal steps.
    @Test func measureLongReply() async throws {
        let chunks = Self.longReplyChunks(30)
        let (_, _, window, run) = try await scenario(deltas: chunks.count) { chunks[$0] }
        let d = Double(run.deltas)
        print("LONG per-delta requests=\(Double(run.requests) / d) prepaints=\(Double(run.prepaints) / d) markdownTopBlock=\(Double(run.rerun["MarkdownTopBlock"]!) / d)")
        let centre = Point(x: Pixels(400), y: Pixels(300))
        var requests = 0, prepaints = 0
        let steps = 20
        for _ in 0..<steps {
            window.resetFrameWork()
            window.scroll(at: centre, byDeltaX: 0, deltaY: 500)
            await Task.yield()
            requests += window.frameWork.map(\.elementRequests).reduce(0, +)
            prepaints += window.frameWork.map(\.elementPrepaints).reduce(0, +)
        }
        print("LONG per-scroll-step requests=\(Double(requests) / Double(steps)) prepaints=\(Double(prepaints) / Double(steps))")
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

    /// Mean per-delta counts over 3 runs with the notice, session message, question and plan rows in the transcript.
    @Test func measureWithTheOtherRowTypes() async throws {
        var total = Run()
        for _ in 0..<3 {
            let (_, _, _, run) = try await scenario(extras: true)
            total.rerun.merge(run.rerun, uniquingKeysWith: +)
            total.requests += run.requests; total.prepaints += run.prepaints; total.deltas += run.deltas
        }
        let d = Double(total.deltas)
        print("ROWS2 " + Self.names.map { "\($0)=\(Double(total.rerun[$0]!) / d)" }.joined(separator: " ")
              + " requests=\(Double(total.requests) / d) prepaints=\(Double(total.prepaints) / d)")
    }

    /// Each of the four rows (notice, session message, question, plan) stays out of every delta's frame work.
    @Test func settledNoticeMessageQuestionAndPlanDoNotRerun() async throws {
        let (_, _, _, run) = try await scenario(extras: true)
        for n in ["NoticeRow", "SessionMessageRow", "QuestionCard", "PlanCard"] {
            #expect(run.rerun[n]! == 0, "\(n) re-ran \(run.rerun[n]!) times in \(run.deltas) deltas")
        }
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

    @Test func noticeAndSessionMessageRenderAfterReplayedFrames() async throws {
        let (_, session, window, _) = try await scenario(deltas: 12, extras: true)
        let notice = try #require(session.transcript.blocks.first { if case .notice(_, .commandOutput, _) = $0 { true } else { false } })
        let message = try #require(session.transcript.blocks.first { if case .sessionMessage = $0 { true } else { false } })
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(visibleText(window, notice.id).contains("notice-out"))
        let text = try window.element(identifier: "session-message-text-\(message.id)")
        #expect((text.value ?? text.label) == "hello A")
    }

    private func click(_ window: TestWindow, _ identifier: String) throws {
        try window.click(window.element(identifier: identifier))
        window.tick()
    }

    @Test func aQuestionTakesTypedAndPickedAnswersThenAnswers() async throws {
        let (_, _, window, _) = try await scenario(deltas: 12, extras: true)
        let rid = "40ef1a1e-119b-4077-9cb6-577187fdfd95"
        try await window.runUntil { (try? window.element(identifier: "q-submit-\(rid)")) != nil }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        try window.typeText("Rust", into: window.element(identifier: "q-other-\(rid)-0"))
        window.tick()
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect((try window.element(identifier: "q-other-\(rid)-0")).value == "Rust")
        try click(window, "q-opt-\(rid)-1-0")
        for _ in 0..<5 { window.tick(); await Task.yield() }
        try window.typeText("black", into: window.element(identifier: "q-other-\(rid)-1"))
        window.tick()
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect((try window.element(identifier: "q-other-\(rid)-1")).value == "black")
        try click(window, "q-submit-\(rid)")
        // Submit is enabled only when both questions carry a pick, so answering proves the picks showed in state.
        try await window.runUntil { (try? window.element(label: "pytest, black")) != nil }
        #expect((try? window.element(label: "Rust")) != nil)
        #expect((try? window.element(identifier: "q-submit-\(rid)")) == nil)
    }

    @Test func aPlanTakesFeedbackAfterReplayedFrames() async throws {
        let (_, _, window, _) = try await scenario(deltas: 12, extras: true)
        let rid = "d259011a-7e47-48b0-9946-6fb1ff6ad28e"
        try await window.runUntil { (try? window.element(identifier: "plan-sendback-\(rid)")) != nil }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        try click(window, "plan-sendback-\(rid)")
        try await window.runUntil { (try? window.element(identifier: "plan-feedback-\(rid)")) != nil }
        try window.typeText("add tests", into: window.element(identifier: "plan-feedback-\(rid)"))
        window.tick()
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect((try window.element(identifier: "plan-feedback-\(rid)")).value == "add tests")
    }
}
