import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// An assistant reply is one lazy transcript row per top-level Markdown block.
@MainActor
@Suite struct TranscriptRowSplitTests {
    private func paragraphs(_ n: Int) -> String { (0..<n).map { "paragraph number \($0) of the reply" }.joined(separator: "\n\n") }

    private func replyID(_ session: Session) throws -> String {
        try #require(session.transcript.blocks.last { if case .assistantText = $0 { true } else { false } }?.id)
    }

    private func settle(_ window: TestWindow, _ n: Int = 10) async {
        for _ in 0..<n { window.tick(); await Task.yield() }
    }

    private func reply(_ text: String, height: Double = 800) async throws -> (Rig, Session, TestWindow, String) {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.assistantBlock(messageID: "m", block: .text(text)))
        try await acpUntil { session.transcript.blocks.count == 1 }
        let window = try alloyWindow(rig.workspace, height: height)
        await settle(window)
        return (rig, session, window, try replyID(session))
    }

    private func frame(_ window: TestWindow, _ identifier: String) throws -> (minY: Float, maxY: Float) {
        let f = try window.element(identifier: identifier).frame
        return (f.origin.y.value, f.origin.y.value + f.size.height.value)
    }

    @Test func replySplitsIntoOneRowPerTopLevelBlock() async throws {
        let (_, _, window, id) = try await reply("one\n\ntwo\n\nthree\n\n```swift\nlet a = 1\n```")
        let ys = try ["block-\(id)", "block-\(id)-md1", "block-\(id)-md2", "block-\(id)-md3"].map { try frame(window, $0).minY }
        #expect(ys == ys.sorted() && Set(ys).count == 4, "\(ys)")
    }

    @Test func emptyReplyStillHasItsRow() async throws {
        let (_, _, window, id) = try await reply("")
        _ = try window.element(identifier: "block-\(id)")
    }

    @Test func offscreenPiecesHaveNoElements() async throws {
        let (_, _, window, id) = try await reply(paragraphs(200))
        #expect((try? window.element(identifier: "block-\(id)-md199")) != nil)
        #expect((try? window.element(identifier: "block-\(id)-md5")) == nil)
    }

    @Test func spacingBetweenPiecesIsTen() async throws {
        let (_, _, window, id) = try await reply(paragraphs(3))
        let first = try frame(window, "block-\(id)"), second = try frame(window, "block-\(id)-md1")
        #expect(second.minY - first.maxY == 10, "\(first) \(second)")
    }

    @Test func copyButtonIdentifiersUnchanged() async throws {
        let (_, _, window, id) = try await reply("intro\n\n```swift\nlet a = 1\n```")
        _ = try window.element(identifier: "copy-code-\(id)-1-0")
    }

    /// A reply that streams as one block: a block start, then text deltas.
    private func streamingReply(_ initial: String) async throws -> (Rig, Session, TestWindow) {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.delta(.blockStart(index: 0, kind: "text")))
        await rig.transports[0].emit(.delta(.text(index: 0, initial)))
        try await acpUntil { session.transcript.blocks.count == 1 }
        let window = try alloyWindow(rig.workspace)
        await settle(window, 30)
        return (rig, session, window)
    }

    private func delta(_ rig: Rig, _ window: TestWindow, _ text: String) async {
        await rig.transports[0].emit(.delta(.text(index: 0, text)))
        for _ in 0..<5 { await Task.yield() }
        window.tick()
    }

    @Test func onlyTheLastPieceRerunsPerDelta() async throws {
        let (rig, _, window) = try await streamingReply(paragraphs(20))
        let before = BodyProbe.count("MarkdownTopBlock")
        var created = 0
        let deltas = 30
        for i in 0..<deltas {
            if i % 5 == 4 { created += 1; await delta(rig, window, "\n\nnew paragraph \(i)") } else { await delta(rig, window, " word\(i)") }
        }
        let ran = BodyProbe.count("MarkdownTopBlock") - before
        #expect(ran <= deltas + created, "\(ran) bodies over \(deltas) deltas and \(created) new blocks")
    }

    @Test func rewrittenReplyDropsStalePieces() async throws {
        let (rig, session, window) = try await streamingReply(paragraphs(5))
        let id = try replyID(session)
        _ = try window.element(identifier: "block-\(id)-md3")
        // The complete message replaces the streamed text, which is not an extension of it.
        await rig.transports[0].emit(.assistantBlock(messageID: "m", block: .text("something else\n\nentirely")))
        try await window.runUntil { (try? window.element(identifier: "block-\(id)-md3")) == nil }
        _ = try window.element(identifier: "block-\(id)-md1")
        #expect((try? window.element(identifier: "block-\(id)-md2")) == nil)
    }

    @Test func showInChatReachesASplitReply() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        for i in 0..<60 {
            await rig.transports[0].emit(.assistantBlock(messageID: "m\(i)", block: .text("reply \(i) first\n\nreply \(i) second\n\nreply \(i) third")))
        }
        try await acpUntil { session.transcript.blocks.count == 60 }
        let ui = SessionUIStore().entry(for: session, workspace: rig.workspace)
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            VStack(spacing: 0) { TranscriptView(workspace: rig.workspace, session: session, ui: ui).equatable() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        await settle(window)
        let target = session.transcript.blocks[3].id
        #expect((try? window.element(identifier: "block-\(target)")) == nil)
        ui.scrollTarget = target
        try await window.runUntil {
            guard let e = try? frame(window, "block-\(target)") else { return false }
            return e.minY >= 0 && e.maxY <= 800
        }
    }

    @Test func streamingNewBlocksKeepsTheBottomPinned() async throws {
        let (rig, session, window) = try await streamingReply(paragraphs(30))
        let id = try replyID(session)
        for i in 0..<12 {
            await delta(rig, window, "\n\nstreamed paragraph \(i)")
            try await window.runUntil { (try? window.element(identifier: "block-\(id)-md\(30 + i)")) != nil }
            await settle(window, 3)
            let last = try frame(window, "block-\(id)-md\(30 + i)")
            #expect(last.maxY <= 800 && last.minY >= 0, "delta \(i): \(last)")
        }
    }
}
