import AlloyCore
import Foundation
import Testing
@testable import AlloyACP

@Suite struct HistoryTests {
    private func replay(_ history: ACPHistory) -> (messages: [InboundMessage], skipped: Int) {
        let data = (try? Data(contentsOf: history.url)) ?? Data()
        var out: [InboundMessage] = []
        let skipped = ACPHistory.forEachMessage(in: data) { out.append($0) }
        return (out, skipped)
    }

    @Test func transportAppendsATurnAndItReadsBack() async throws {
        let dir = Scratch()
        let history = ACPHistory(directory: dir.url, sessionID: UUID())
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInitPlain, #"{"expect":"session/new"}"#, hsNew,
            #"{"expect":"session/prompt"}"#,
            upd(#"{"sessionUpdate":"agent_thought_chunk","messageId":"t","content":{"type":"text","text":"hm"}}"#),
            upd(#"{"sessionUpdate":"agent_message_chunk","messageId":"a","content":{"type":"text","text":"Hel"}}"#),
            upd(#"{"sessionUpdate":"agent_message_chunk","messageId":"a","content":{"type":"text","text":"lo"}}"#),
            upd(#"{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Run ls","kind":"execute","status":"in_progress"}"#),
            upd(#"{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"a.txt"}}]}"#),
            upd(#"{"sessionUpdate":"agent_message_chunk","messageId":"b","content":{"type":"text","text":"Done"}}"#),
            turnDone, #"{"sleep":3000}"#,
        ], configure: { $0.history = history })
        #expect(await waitUntil { r.events.hasSystemInit })
        let id = UUID()
        try await r.transport.send(user("list files", id: id))
        #expect(await waitUntil { r.events.results == 1 })
        await r.stop()
        let (messages, skipped) = replay(history)
        #expect(skipped == 0)
        #expect(messages.first == .userEcho(text: "list files", imageCount: 0, uuid: id.uuidString.lowercased(), isReplay: false))
        let blocks = messages.compactMap { m -> String? in
            guard case .assistantBlock(_, let b) = m else { return nil }
            switch b {
            case .thinking(let t): return "thinking:\(t)"
            case .text(let t): return "text:\(t)"
            case .toolUse(let id, let name, _, _): return "tool:\(id):\(name)"
            }
        }
        #expect(blocks == ["thinking:hm", "text:Hello", "tool:c1:Run ls", "text:Done"])
        #expect(messages.contains { if case .toolResult(let t) = $0 { t.toolUseID == "c1" && t.text == "a.txt" } else { false } })
        // Replayed into a transcript it reads as the conversation.
        var transcript = Transcript(projectRoot: dir.url)
        for m in messages { transcript.apply(m) }
        transcript.finishReplay()
        #expect(transcript.blocks.contains { if case .assistantText(_, let t) = $0 { t == "Hello" } else { false } })
        #expect(transcript.blocks.contains { if case .user(_, let t, _, _) = $0 { t == "list files" } else { false } })
    }

    @Test func truncatedHistoryTailIsTolerated() throws {
        let dir = Scratch()
        let history = ACPHistory(directory: dir.url, sessionID: UUID())
        history.append(ACPHistory.encode(.userEcho(text: "q", imageCount: 0, uuid: nil, isReplay: false))!)
        history.append(ACPHistory.encode(.assistantBlock(messageID: "m", block: .text("answer")))!)
        // The app died mid-write.
        let handle = try FileHandle(forWritingTo: history.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"assistant","message":{"id":"m2","content":[{"type":"te"#.utf8))
        try handle.close()
        let (messages, skipped) = replay(history)
        #expect(messages.count == 2 && skipped == 1)
        #expect(history.read().count == 3)
    }

    @Test func missingHistoryFileReadsEmpty() {
        let dir = Scratch()
        let history = ACPHistory(directory: dir.url.appendingPathComponent("none"), sessionID: UUID())
        #expect(history.read().isEmpty)
        #expect(replay(history).messages.isEmpty)
    }

    @Test func noticesAndCompactionSurviveARoundTrip() {
        let dir = Scratch()
        let history = ACPHistory(directory: dir.url, sessionID: UUID())
        for m in [InboundMessage.notice(kind: .warning, text: "careful"), .compactBoundary(preTokens: 10, postTokens: 3)] {
            history.append(ACPHistory.encode(m)!)
        }
        let (messages, _) = replay(history)
        #expect(messages == [.notice(kind: .warning, text: "careful"), .compactBoundary(preTokens: 10, postTokens: 3)])
    }
}
