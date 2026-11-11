import AlloyCore
import Foundation
import Testing

enum ReplayError: Error { case notText }

@Suite struct TranscriptFileTests {
    static func sample() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "transcript-sample", withExtension: "jsonl", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func replay(_ messages: [InboundMessage]) -> Transcript {
        var t = Transcript(projectRoot: URL(fileURLWithPath: "/tmp/alloy-fixture"))
        for m in messages { t.apply(m, now: Date(timeIntervalSince1970: 0)) }
        t.finishReplay()
        return t
    }

    static func kinds(_ t: Transcript) -> [String] {
        t.blocks.map {
            switch $0 {
            case .user: "user"
            case .assistantText: "text"
            case .thinking: "thinking"
            case .tool: "tool"
            case .notice: "notice"
            default: "other"
            }
        }
    }

    @Test func slugMatchesCLI() {
        let u = TranscriptFile.url(cliSessionID: "abc", projectRoot: URL(fileURLWithPath: "/private/tmp/a b/c.d"),
                                   home: URL(fileURLWithPath: "/home/x"))
        #expect(u.path == "/home/x/.claude/projects/-private-tmp-a-b-c-d/abc.jsonl")
    }

    @Test func slugOfAProjectUnderTmpUsesTheRealPrivatePath() throws {
        let dir = URL(fileURLWithPath: "/tmp/alloy-slug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = TranscriptFile.url(cliSessionID: "abc", projectRoot: dir, home: URL(fileURLWithPath: "/home/x"))
        let slug = ("/private" + dir.path).map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        #expect(u.path == "/home/x/.claude/projects/\(slug)/abc.jsonl")
    }

    @Test func lastMessageUUIDIsTheNewestAssistantRecord() throws {
        let data = try Self.sample()
        // Later records are a system line, last-prompt and cost-state; the message before them is the assistant's.
        #expect(TranscriptFile.lastMessageUUID(in: data) == "f77492c0-3a77-401e-b23f-56ffba3b23ac")
        // A user record after the assistant's (a prompt not yet answered) is not a fork point: the assistant's is.
        let trailing = data + Data("{\"type\":\"user\",\"uuid\":\"99999999-0000-0000-0000-000000000000\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n".utf8)
        #expect(TranscriptFile.lastMessageUUID(in: trailing) == "f77492c0-3a77-401e-b23f-56ffba3b23ac")
        #expect(TranscriptFile.lastMessageUUID(in: Data()) == nil)
        #expect(TranscriptFile.lastMessageUUID(in: Data("{\"type\":\"cost-state\"}\n".utf8)) == nil)
    }

    @Test func truncatedStopsAfterTheLineWithThatUUID() throws {
        let data = try Self.sample()
        let cut = try #require(TranscriptFile.truncated(data, after: "a2222f0f-1bed-4753-853a-7882e81dd217"))
        #expect(TranscriptFile.lastMessageUUID(in: cut) == "006886a3-554b-4afc-98a0-7e0d0dffa390")
        let t = Self.replay(TranscriptFile.messages(from: cut).messages)
        #expect(Self.kinds(t).filter { $0 != "notice" } == ["user", "tool"])
        #expect(TranscriptFile.truncated(data, after: "00000000-0000-0000-0000-000000000000") == nil)
        #expect(TranscriptFile.contains(data, uuid: "f77492c0-3a77-401e-b23f-56ffba3b23ac"))
        #expect(!TranscriptFile.contains(data, uuid: "00000000-0000-0000-0000-000000000000"))
    }

    @Test func sampleReplaysBlocks() throws {
        let parsed = TranscriptFile.messages(from: try Self.sample())
        #expect(parsed.skippedLines == 0)
        let t = Self.replay(parsed.messages)
        #expect(Self.kinds(t).filter { $0 != "notice" } == ["user", "tool", "thinking", "text", "user", "thinking", "text"])
        guard case .user(_, let prompt, _, let state) = t.blocks[0] else { Issue.record("no user block"); return }
        #expect(prompt.hasPrefix("Count slowly"))
        #expect(state == .sent)
        let thinking = t.blocks.compactMap { b -> String? in if case .thinking(_, let s, _) = b { return s } else { return nil } }
        #expect(thinking.count == 2 && thinking.allSatisfy { !$0.isEmpty })
        guard case .tool(let tool) = t.blocks[1] else { Issue.record("no tool block"); return }
        #expect(tool.name == "Bash" && tool.status == .succeeded && tool.resultText.hasPrefix("1\n2"))
        #expect(tool.result?["stdout"] != nil)
    }

    @Test func replayedToolTimesComeFromTheRecordTimestamps() throws {
        func replay(_ data: Data) -> ToolBlock? {
            var t = Transcript(projectRoot: URL(fileURLWithPath: "/tmp/alloy-fixture"))
            _ = TranscriptFile.forEachMessage(in: data) { t.apply($0, now: $1) }
            t.finishReplay()
            return t.blocks.compactMap { if case .tool(let x) = $0 { x } else { nil } }.first
        }
        let tool = try #require(replay(try Self.sample()))
        let start = try #require(tool.startedAt), end = try #require(tool.endedAt)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(start == iso.date(from: "2026-11-07T22:34:45.612Z"))
        #expect(end == iso.date(from: "2026-11-07T22:34:46.359Z"))
        // Records without a timestamp leave the times unset, so no chip shows a bogus duration.
        let bare = String(decoding: try Self.sample(), as: UTF8.self)
            .replacingOccurrences(of: #""timestamp":"[^"]*","#, with: "", options: .regularExpression)
        let untimed = try #require(replay(Data(bare.utf8)))
        #expect(untimed.startedAt == nil && untimed.endedAt == nil)
    }

    @Test func truncatedLastLineSkipped() throws {
        let data = try Self.sample()
        let full = TranscriptFile.messages(from: data)
        // Cut the last assistant record in half, dropping everything after it.
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        let lastAssistant = try #require(lines.lastIndex { String(decoding: $0, as: UTF8.self).contains("\"type\":\"assistant\"") })
        var cut = Data()
        for l in lines[..<lastAssistant] { cut.append(contentsOf: l); cut.append(UInt8(ascii: "\n")) }
        cut.append(contentsOf: lines[lastAssistant].prefix(40))
        let parsed = TranscriptFile.messages(from: cut)
        #expect(parsed.skippedLines == 1)
        #expect(parsed.messages == Array(full.messages.dropLast()))
        #expect(Self.kinds(Self.replay(parsed.messages)).filter { $0 != "notice" }.prefix(3) == ["user", "tool", "thinking"])
    }

    /// 3000 turns, each a real user record and a real assistant text record from the fixture.
    static func largeTranscript() throws -> String {
        let lines = try Self.sample().split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        let user = try #require(lines.first { $0.contains("\"type\":\"user\"") && $0.contains("Count slowly") })
        let text = try #require(lines.first { $0.contains("\"type\":\"assistant\"") && $0.contains("\"type\":\"text\"") })
        var out = ""
        for i in 0..<3000 {
            out += user.replacingOccurrences(of: "Count slowly", with: "Turn \(i)")
                .replacingOccurrences(of: "\"uuid\":\"", with: "\"uuid\":\"\(String(format: "%08x", i))-") + "\n"
            out += text.replacingOccurrences(of: "msg_011CgpN8BnZCML4fUeSY6CTQ", with: "msg_\(i)")
                .replacingOccurrences(of: "msg_011CgpN7ysh9bQP2uPwAfYr6", with: "msg_\(i)") + "\n"
        }
        return out
    }

    @Test func largeFileKeepsTail() throws {
        let parsed = TranscriptFile.messages(from: Data(try Self.largeTranscript().utf8))
        #expect(parsed.skippedLines == 0)
        let t = Self.replay(parsed.messages)
        #expect(t.blocks.count == 6000)
        let kept = Array(t.blocks.suffix(2000))
        guard case .assistantText(_, let lastText) = kept.last else { Issue.record("tail is not text"); return }
        let wanted: String
        if case .assistantText(_, let w) = t.blocks[5999] { wanted = w } else { throw ReplayError.notText }
        #expect(lastText == wanted)
        guard case .user(_, let firstKept, _, _) = kept[0] else { Issue.record("tail starts oddly"); return }
        #expect(firstKept.hasPrefix("Turn 2000"))
    }

    /// `turns` x (user, tool_use, tool_result, text) real fixture records with unique ids: 50k records at 12500 turns.
    static func toolHistory(turns: Int) throws -> String {
        let lines = try sample().split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        let user = try #require(lines.first { $0.contains("\"type\":\"user\"") && $0.contains("Count slowly") })
        let use = try #require(lines.first { $0.contains("\"type\":\"assistant\"") && $0.contains("\"tool_use\"") })
        let result = try #require(lines.first { $0.contains("\"tool_result\"") })
        let text = try #require(lines.first { $0.contains("\"type\":\"assistant\"") && $0.contains("\"type\":\"text\"") })
        var out = ""
        out.reserveCapacity(turns * 4000)
        for i in 0..<turns {
            let tool = "toolu_\(i)"
            out += user.replacingOccurrences(of: "\"uuid\":\"", with: "\"uuid\":\"\(String(format: "%08x", i))-") + "\n"
            out += use.replacingOccurrences(of: "toolu_01QkcadU6KBGp83dgayhLFcV", with: tool)
                .replacingOccurrences(of: "msg_011CgpN7siN759HGJh9RJgUd", with: "msg_u\(i)") + "\n"
            out += result.replacingOccurrences(of: "toolu_01QkcadU6KBGp83dgayhLFcV", with: tool) + "\n"
            out += text.replacingOccurrences(of: "msg_011CgpN7ysh9bQP2uPwAfYr6", with: "msg_t\(i)")
                .replacingOccurrences(of: "msg_011CgpN8BnZCML4fUeSY6CTQ", with: "msg_t\(i)") + "\n"
        }
        return out
    }

    /// Parses `turns` turns (4 records each) untimed, then times only applying them to a fresh transcript.
    private static func timedReplay(turns: Int) throws -> (time: Duration, transcript: Transcript, records: Int) {
        let (messages, skipped) = TranscriptFile.messages(from: Data(try toolHistory(turns: turns).utf8))
        #expect(skipped == 0)
        var t = Transcript(projectRoot: URL(fileURLWithPath: "/tmp/alloy-fixture"))
        let date = Date(timeIntervalSince1970: 0)
        let time = ContinuousClock().measure {
            for m in messages { t.apply(m, now: date) }
            t.finishReplay()
        }
        return (time, t, messages.count)
    }

    /// Wall-clock limits are flaky on a loaded machine, so this asserts scaling: 10x the records must cost about
    /// 10x (linear), not 100x (the old rescanning lookup, which took 48 s at 50k).
    @Test func replayScalesLinearly() throws {
        let small = try min(Self.timedReplay(turns: 1_250).time, Self.timedReplay(turns: 1_250).time)   // 5k records
        let large = try Self.timedReplay(turns: 12_500)                                                  // 50k records
        #expect(large.records == 50_000)
        let tools = large.transcript.blocks.compactMap { b -> ToolBlock? in if case .tool(let x) = b { return x } else { return nil } }
        #expect(tools.count == 12_500 && tools.allSatisfy { $0.status == .succeeded })
        let ratio = large.time / small
        #expect(ratio < 30, "10x the records took \(ratio)x as long (\(small) -> \(large.time))")
        #expect(large.time < .seconds(60), "replay took \(large.time)")
    }
}
