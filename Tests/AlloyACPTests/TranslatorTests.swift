import AlloyCore
import Foundation
import Testing
@testable import AlloyACP

private func update(_ json: String) -> ACPSessionUpdate {
    (try? JSONDecoder().decode(ACPSessionUpdate.self, from: Data(json.utf8))) ?? .unknown("undecodable")
}

private final class Disk: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String] = [:]
    func set(_ path: String, _ text: String?) { lock.withLock { files[path] = text } }
    func get(_ path: String) -> String? { lock.withLock { files[path] } }
}

private let root = URL(fileURLWithPath: "/tmp/alloy-translator-project")

private func translator(_ disk: Disk = Disk()) -> ACPTranslator {
    ACPTranslator(projectRoot: root, readFile: { disk.get($0) })
}

@Suite struct TranslatorTests {
    @Test func agentMessageChunkBecomesDelta() {
        var t = translator()
        let a = t.translate(update(#"{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"Hel"}}"#))
        let b = t.translate(update(#"{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"lo"}}"#))
        let c = t.translate(update(#"{"sessionUpdate":"agent_message_chunk","messageId":"m2","content":{"type":"text","text":"Next"}}"#))
        #expect(a == [.delta(.blockStart(index: 0, kind: "text")), .delta(.text(index: 0, "Hel"))])
        #expect(b == [.delta(.text(index: 0, "lo"))])
        #expect(c == [.delta(.blockStart(index: 0, kind: "text")), .delta(.text(index: 0, "Next"))])
    }

    @Test func thoughtChunkBecomesThinkingDelta() {
        var t = translator()
        let a = t.translate(update(#"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"hmm"}}"#))
        let b = t.translate(update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ok"}}"#))
        #expect(a == [.delta(.blockStart(index: 0, kind: "thinking")), .delta(.thinking(index: 0, "hmm", estimatedTokens: nil))])
        #expect(b == [.delta(.blockStart(index: 0, kind: "text")), .delta(.text(index: 0, "ok"))])
    }

    @Test func toolCallKindsMapEachKind() {
        let expected: [(String, ToolKind)] = [
            ("read", .read), ("edit", .edit), ("delete", .edit), ("move", .edit), ("search", .search),
            ("execute", .shell), ("fetch", .web), ("think", .other), ("other", .other),
        ]
        var t = translator()
        for (i, (kind, tool)) in expected.enumerated() {
            let out = t.translate(update(#"{"sessionUpdate":"tool_call","toolCallId":"t\#(i)","title":"Do \#(kind)","kind":"\#(kind)","status":"in_progress"}"#))
            guard case .assistantBlock(_, .toolUse(let id, let name, let input, _)) = out.first else {
                Issue.record("no tool block for \(kind)"); continue
            }
            #expect(id == "t\(i)")
            #expect(name == "Do \(kind)")
            #expect(input["acpKind"]?.stringValue == kind)
            #expect(ToolKind(acpKind: kind) == tool)
        }
        #expect(ToolKind(acpKind: "nonsense") == nil)
    }

    @Test func toolCallStatusesMapToResults() {
        var t = translator()
        _ = t.translate(update(#"{"sessionUpdate":"tool_call","toolCallId":"a","title":"Run","kind":"execute","status":"pending","rawInput":{"command":"ls"}}"#))
        let ok = t.translate(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"a","status":"completed","content":[{"type":"content","content":{"type":"text","text":"out"}}]}"#))
        guard case .toolResult(let r) = ok.first else { Issue.record("no result"); return }
        #expect(r.toolUseID == "a" && !r.isError && r.text == "out")
        _ = t.translate(update(#"{"sessionUpdate":"tool_call","toolCallId":"b","title":"Run","kind":"execute","status":"in_progress"}"#))
        let bad = t.translate(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"b","status":"failed"}"#))
        guard case .toolResult(let f) = bad.first else { Issue.record("no result"); return }
        #expect(f.isError)
        // A repeat of a finished call adds nothing.
        #expect(t.translate(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"a","status":"completed"}"#)).isEmpty)
    }

    @Test func completedDiffEmitsWholeFileWriteResult() {
        let disk = Disk()
        let path = root.appendingPathComponent("a.txt").path
        disk.set(path, "first\nsecond line\n")
        var t = translator(disk)
        let start = t.translate(update(#"{"sessionUpdate":"tool_call","toolCallId":"e1","title":"Edit a.txt","kind":"edit","status":"in_progress","locations":[{"path":"\#(path)"}],"content":[{"type":"diff","path":"\#(path)","oldText":"second line\n","newText":"second line\nthird line\n"}]}"#))
        #expect(start.count == 1)   // the block only; nothing is attributed before it completes
        disk.set(path, "first\nsecond line\nthird line\n")
        let done = t.translate(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"e1","status":"completed"}"#))
        guard case .toolResult(let r) = done.first else { Issue.record("no result"); return }
        #expect(r.result == .write(filePath: path, isCreate: false, content: "first\nsecond line\nthird line\n",
                                   originalFile: "first\nsecond line\n", hunks: []))
    }

    @Test func creationDiffIsACreate() {
        let disk = Disk()
        let path = root.appendingPathComponent("new.txt").path
        var t = translator(disk)
        _ = t.translate(update(#"{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Create","kind":"edit","status":"in_progress","content":[{"type":"diff","path":"\#(path)","oldText":null,"newText":"hello\n"}]}"#))
        disk.set(path, "hello\n")
        let done = t.translate(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed"}"#))
        guard case .toolResult(let r) = done.first else { Issue.record("no result"); return }
        #expect(r.result == .write(filePath: path, isCreate: true, content: "hello\n", originalFile: nil, hunks: []))
    }

    @Test func snippetDiffRebuildsWholeFileFromDisk() {
        // The file already shows the edit when the call is first seen: the original is rebuilt from the snippet.
        let disk = Disk()
        let path = root.appendingPathComponent("b.txt").path
        disk.set(path, "one\ntwo changed\nthree\n")
        var t = translator(disk)
        _ = t.translate(update(#"{"sessionUpdate":"tool_call","toolCallId":"e2","title":"Edit","kind":"edit","status":"in_progress","content":[{"type":"diff","path":"\#(path)","oldText":"two\n","newText":"two changed\n"}]}"#))
        let done = t.translate(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"e2","status":"completed"}"#))
        guard case .toolResult(let r) = done.first else { Issue.record("no result"); return }
        #expect(r.result == .write(filePath: path, isCreate: false, content: "one\ntwo changed\nthree\n",
                                   originalFile: "one\ntwo\nthree\n", hunks: []))
    }

    @Test func editWithoutDiffIsAttributedFromDiskChange() {
        // OpenCode: no diff, only a path on the update.
        let disk = Disk()
        let path = root.appendingPathComponent("c.txt").path
        disk.set(path, "old\n")
        var t = translator(disk)
        _ = t.translate(update(#"{"sessionUpdate":"tool_call","toolCallId":"w1","title":"write","kind":"edit","status":"pending"}"#))
        _ = t.translate(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"w1","status":"in_progress","locations":[{"path":"\#(path)"}],"rawInput":{"path":"\#(path)","content":"new\n"}}"#))
        disk.set(path, "new\n")
        let done = t.translate(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"w1","status":"completed"}"#))
        guard case .toolResult(let r) = done.first else { Issue.record("no result"); return }
        #expect(r.result == .write(filePath: path, isCreate: false, content: "new\n", originalFile: "old\n", hunks: []))
    }

    @Test func pathsOutsideTheProjectAreNeverRead() {
        let called = Disk()
        var t = ACPTranslator(projectRoot: root, readFile: { called.set($0, "x"); return "x" })
        _ = t.translate(update(#"{"sessionUpdate":"tool_call","toolCallId":"o","title":"Edit","kind":"edit","status":"in_progress","locations":[{"path":"/etc/hosts"}]}"#))
        let done = t.translate(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"o","status":"completed"}"#))
        #expect(called.get("/etc/hosts") == nil)
        guard case .toolResult(let r) = done.first else { Issue.record("no result"); return }
        #expect(r.result == .none)
    }

    @Test func planReplacesFullList() {
        var t = translator()
        let a = t.translate(update(#"{"sessionUpdate":"plan","entries":[{"content":"A","priority":"high","status":"in_progress"},{"content":"B","priority":"low","status":"pending"}]}"#))
        let b = t.translate(update(#"{"sessionUpdate":"plan","entries":[{"content":"A","status":"completed"}]}"#))
        guard case .assistantBlock(_, .toolUse(let id1, "TodoWrite", let input1, _)) = a.first,
              case .assistantBlock(_, .toolUse(let id2, "TodoWrite", let input2, _)) = b.first else {
            Issue.record("no plan blocks"); return
        }
        #expect(id1 != id2)
        #expect(input1["todos"]?.arrayValue?.count == 2)
        #expect(input2["todos"]?.arrayValue?.count == 1)
        #expect(input2["todos"]?.arrayValue?.first?["status"]?.stringValue == "completed")
        #expect(a.count == 2 && b.count == 2)   // block and its result
    }

    @Test func commandsUpdateSetsSlashCommands() {
        var t = translator()
        let out = t.translate(update(#"{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"review","description":"Review code","input":{"hint":"scope"}},{"name":"init","description":"Init","input":null}]}"#))
        #expect(out == [.commandsChanged([
            SlashCommandInfo(name: "review", description: "Review code", argumentHint: "scope"),
            SlashCommandInfo(name: "init", description: "Init", argumentHint: nil),
        ])])
    }

    @Test func usageUpdateFillsSessionUsage() {
        var t = translator()
        let a = t.translate(update(#"{"sessionUpdate":"usage_update","used":1200,"size":200000,"cost":{"amount":0.25,"currency":"USD"}}"#))
        let b = t.translate(update(#"{"sessionUpdate":"usage_update","used":5,"size":10}"#))
        #expect(a == [.agentState(.usage(SessionUsage(used: 1200, size: 200000, cost: 0.25, currency: "USD")))])
        #expect(b == [.agentState(.usage(SessionUsage(used: 5, size: 10, cost: nil, currency: nil)))])
    }

    @Test func modesAndModelsComeFromConfigOptions() {
        var t = translator()
        let out = t.translate(update(#"{"sessionUpdate":"config_option_update","configOptions":[{"id":"mode","category":"mode","type":"select","currentValue":"build","options":[{"value":"build","name":"Build"},{"value":"plan","name":"Plan"}]},{"id":"model","category":"model","currentValue":"a/b","options":[{"value":"a/b","name":"B"}]}]}"#))
        #expect(out == [
            .agentState(.modes(current: "build", available: [AgentChoice(id: "build", name: "Build"), AgentChoice(id: "plan", name: "Plan")])),
            .agentState(.models(current: "a/b", available: [AgentChoice(id: "a/b", name: "B")])),
        ])
        // The same state again produces nothing (an idle agent re-sends it).
        let again = t.translate(update(#"{"sessionUpdate":"config_option_update","configOptions":[{"id":"mode","category":"mode","currentValue":"build","options":[{"value":"build","name":"Build"},{"value":"plan","name":"Plan"}]}]}"#))
        #expect(again.isEmpty)
        let mode = t.translate(update(#"{"sessionUpdate":"current_mode_update","currentModeId":"plan"}"#))
        #expect(mode.first == .statusChanged(permissionMode: "plan"))
    }

    @Test func compactionBumpsBoundary() {
        var t = translator()
        let out = t.translate(update(#"{"sessionUpdate":"compaction_update","preTokens":9000,"postTokens":1200}"#))
        #expect(out == [.compactBoundary(preTokens: 9000, postTokens: 1200)])
        let notice = t.translate(update(#"{"sessionUpdate":"notice","level":"warning","message":"Rate limited"}"#))
        #expect(notice == [.notice(kind: .warning, text: "Rate limited")])
    }

    @Test func stopReasonsMapToResultAndNotices() {
        func run(_ reason: String) -> [InboundMessage] {
            var t = translator()
            return t.result(for: ACPPromptResult(stopReason: reason, usage: ACPTokenUsage(inputTokens: 3, outputTokens: 4)), sessionID: "s")
        }
        func result(_ m: [InboundMessage]) -> TurnResult? { if case .result(let r)? = m.last { r } else { nil } }
        let end = run("end_turn")
        #expect(end.count == 1)
        #expect(result(end)?.terminalReason == nil && result(end)?.inputTokens == 3 && result(end)?.outputTokens == 4)
        let cancelled = run("cancelled")
        #expect(cancelled.count == 1 && result(cancelled)?.terminalReason == "aborted_streaming")
        for reason in ["refusal", "max_tokens", "max_turn_requests"] {
            let m = run(reason)
            #expect(m.count == 2, "\(reason)")
            if case .notice(.warning, _) = m.first { } else { Issue.record("no warning for \(reason)") }
            #expect(result(m)?.terminalReason == nil)
        }
    }

    @Test func replayChunksAreIsReplay() {
        var t = translator()
        #expect(t.translate(update(#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"hi"}}"#)).isEmpty)
        t.isReplaying = true
        let out = t.translate(update(#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"hi"}}"#))
        #expect(out == [.userEcho(text: "hi", imageCount: 0, uuid: nil, isReplay: true)])
    }

    @Test func unknownUpdateIgnored() {
        var t = translator()
        #expect(t.translate(update(#"{"sessionUpdate":"brand_new_thing","x":1}"#)).isEmpty)
        #expect(t.translate(update(#"{"sessionUpdate":"session_info_update","title":"T"}"#)).isEmpty)
    }
}
