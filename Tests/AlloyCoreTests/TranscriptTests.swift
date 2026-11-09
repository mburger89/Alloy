import Foundation
import Testing
@testable import AlloyCore

@Suite struct TranscriptTests {
    static let root = URL(fileURLWithPath: "/tmp/alloy-fixture")

    func replay(_ name: String, root: URL = TranscriptTests.root, hook: ((InboundMessage, inout Transcript) -> Void)? = nil) -> Transcript {
        var t = Transcript(projectRoot: root)
        for line in Fixture.lines(name) {
            let m = InboundDecoder.decode(line)
            t.apply(m)
            hook?(m, &t)
        }
        return t
    }

    func tools(_ t: Transcript) -> [ToolBlock] {
        t.blocks.compactMap { if case .tool(let b) = $0 { return b } else { return nil } }
    }
    func permissions(_ t: Transcript) -> [PermissionBlock] {
        t.blocks.compactMap { if case .permission(let b) = $0 { return b } else { return nil } }
    }
    func notices(_ t: Transcript, _ k: NoticeKind) -> [String] {
        t.blocks.compactMap { if case .notice(_, k, let s) = $0 { return s } else { return nil } }
    }

    @Test func streamingTextGrowsOneBlock() {
        var t = Transcript(projectRoot: URL(fileURLWithPath: "/proj"))
        t.apply(.delta(.blockStart(index: 0, kind: "text")))
        t.apply(.delta(.text(index: 0, "Hel")))
        t.apply(.delta(.text(index: 0, "lo ")))
        t.apply(.delta(.text(index: 0, "world")))
        let streamedID = t.blocks[0].id
        #expect(t.blocks == [.assistantText(id: streamedID, text: "Hello world")])
        t.apply(.assistantBlock(messageID: "msg_1", block: .text("Hello world!")))
        #expect(t.blocks == [.assistantText(id: streamedID, text: "Hello world!")])
    }

    @Test func editTurnProducesToolBlockSucceeded() {
        let t = replay("edit-turn")
        let edit = tools(t).first { $0.kind == .edit }
        #expect(edit?.summary == "login.swift")
        #expect(edit?.status == .succeeded)
    }

    @Test func permissionLifecycle() throws {
        var sawPendingBeforeTool = false
        var t = replay("permission-allow") { m, t in
            if case .controlRequest = m {
                sawPendingBeforeTool = permissions(t).last?.state == .pending
                    && tools(t).allSatisfy { $0.status != .succeeded }
            }
        }
        #expect(sawPendingBeforeTool)
        let p = try #require(permissions(t).first)
        t.resolvePermission(requestID: p.requestID, allowed: true)
        #expect(permissions(t).first?.state == .allowed)

        var c = Transcript(projectRoot: URL(fileURLWithPath: "/proj"))
        c.apply(.controlRequest(ControlRequest(requestID: "r1", kind: .canUseTool(
            toolName: "Bash", input: .object(["command": .string("ls")]), description: nil, toolUseID: "tu1", suggestions: []))))
        #expect(permissions(c).first?.state == .pending)
        c.apply(.controlCancel(requestID: "r1"))
        #expect(permissions(c).first?.state == .cancelled)
    }

    @Test func deniedAndFailedTools() {
        let d = replay("permission-deny") { m, t in
            if case .controlRequest(let r) = m { t.resolvePermission(requestID: r.requestID, allowed: false) }
        }
        #expect(tools(d).contains { $0.status == .denied })
        #expect(!tools(d).contains { $0.status == .failed })
        let f = replay("failed-tool")
        let failed = tools(f).first { $0.status == .failed }
        #expect(failed != nil)
        #expect(failed?.resultText.hasPrefix("Error") == true)
    }

    @Test func interruptAddsNotice() {
        let t = replay("interrupt")
        #expect(!notices(t, .interrupted).isEmpty)
        #expect(!tools(t).contains { $0.status == .running })
        #expect(tools(t).contains { $0.status == .interrupted })
    }

    @Test func compactAddsNotice() {
        let t = replay("compact")
        let n = notices(t, .compacted)
        #expect(n.count == 1)
        let raw = Fixture.lines("compact").map(InboundDecoder.decode)
        guard case .compactBoundary(let pre?, let post?)? = raw.first(where: { if case .compactBoundary = $0 { return true } else { return false } }) else {
            Issue.record("no compact boundary with counts"); return
        }
        #expect(n[0].contains(String(pre)) && n[0].contains(String(post)))
    }

    @Test func replayEchoDoesNotDuplicateUser() {
        var t = Transcript(projectRoot: URL(fileURLWithPath: "/proj"))
        t.appendUser(text: "hi", id: UUID())
        t.apply(.userEcho(text: "hi", imageCount: 0, uuid: nil, isReplay: true))
        #expect(t.blocks.filter { if case .user = $0 { return true } else { return false } }.count == 1)
    }

    @Test func thinkingSummarizedShowsText() {
        let t = replay("thinking-summarized")
        let th: [(String, Int)] = t.blocks.compactMap { if case .thinking(_, let s, let n) = $0 { return (s, n) } else { return nil } }
        #expect(th.count == 1)
        #expect(th.first?.0.isEmpty == false)
    }

    @Test func thinkingTokensAccumulate() {
        var t = Transcript(projectRoot: URL(fileURLWithPath: "/proj"))
        t.apply(.delta(.blockStart(index: 0, kind: "thinking")))
        t.apply(.delta(.thinking(index: 0, "a", estimatedTokens: 5)))
        t.apply(.thinkingTokens(7))
        t.apply(.assistantBlock(messageID: "m", block: .thinking("abc")))
        #expect(t.blocks == [.thinking(id: "m1#0", text: "abc", estimatedTokens: 12)])
    }

    @Test func attachAndPathsOutsideRoot() {
        var t = Transcript(projectRoot: URL(fileURLWithPath: "/proj"))
        t.apply(.assistantBlock(messageID: "m", block: .toolUse(id: "tu", name: "Read", input: .object(["file_path": .string("/etc/hosts")]))))
        let id = UUID()
        t.attach(editIDs: [id], toToolUseID: "tu")
        #expect(tools(t).first?.summary == "/etc/hosts")
        #expect(tools(t).first?.editIDs == [id])
    }

    @Test func classifyTable() {
        let table: [(String, ToolKind)] = [
            ("Read", .read), ("NotebookRead", .read), ("Grep", .search), ("Glob", .search), ("LS", .search),
            ("Bash", .shell), ("BashOutput", .shell), ("KillShell", .shell),
            ("Edit", .edit), ("MultiEdit", .edit), ("NotebookEdit", .edit), ("Write", .write),
            ("WebFetch", .web), ("WebSearch", .web), ("Agent", .subagent), ("Task", .subagent),
            ("TodoWrite", .todo), ("AskUserQuestion", .question), ("ExitPlanMode", .plan),
            ("mcp__alloy__send_message", .mcp), ("Whatever", .other),
        ]
        for (name, kind) in table { #expect(ToolKind.classify(name) == kind, "\(name)") }
    }

    @Test func summaries() {
        let root = URL(fileURLWithPath: "/proj")
        func s(_ n: String, _ i: [String: JSONValue]) -> String { ToolSummary.line(toolName: n, input: .object(i), projectRoot: root) }
        #expect(s("Bash", ["command": .string(String(repeating: "x", count: 200))]).count == 120)
        #expect(s("Grep", ["pattern": .string("foo"), "path": .string("/proj/src")]) == "foo in src")
        #expect(s("Grep", ["pattern": .string("foo")]) == "foo")
        #expect(s("Glob", ["pattern": .string("*.swift")]) == "*.swift")
        #expect(s("WebFetch", ["url": .string("https://a.b")]) == "https://a.b")
        #expect(s("WebSearch", ["query": .string("q")]) == "q")
        #expect(s("Agent", ["description": .string("d")]) == "d")
        #expect(s("TodoWrite", [:]) == "TodoWrite")
        #expect(s("Write", ["file_path": .string("/proj/a/b.swift")]) == "a/b.swift")
    }

    static let proj = URL(fileURLWithPath: "/proj")
    static func aborted() -> InboundMessage {
        .result(TurnResult(subtype: "error_during_execution", isError: true, costUSD: 0, inputTokens: 0,
                           outputTokens: 0, sessionID: "s", terminalReason: "aborted_tools"))
    }

    @Test func abortedResultKeepsNonEmptyStreamedBlock() {
        var t = Transcript(projectRoot: Self.proj)
        t.apply(.delta(.blockStart(index: 0, kind: "text")))
        t.apply(.delta(.text(index: 0, "partial")))
        t.apply(Self.aborted())
        let texts = t.blocks.compactMap { if case .assistantText(_, let s) = $0 { return s } else { return nil } }
        #expect(texts == ["partial"])
    }

    @Test func finalizeDropsEmptyStreamedBlock() {
        var t = Transcript(projectRoot: Self.proj)
        t.apply(.delta(.blockStart(index: 0, kind: "text")))
        t.finalizeStreaming()
        #expect(t.blocks.isEmpty)
    }

    @Test func nonAbortedErrorResultAddsErrorNotice() {
        var t = Transcript(projectRoot: Self.proj)
        t.apply(.result(TurnResult(subtype: "error_max_turns", isError: true, costUSD: 0, inputTokens: 0,
                                   outputTokens: 0, sessionID: "s", terminalReason: nil)))
        #expect(notices(t, .error) == ["Reached the turn limit"])
        #expect(notices(t, .interrupted).isEmpty)
    }

    @Test func nonAbortedErrorResultFailsRunningTools() {
        var t = Transcript(projectRoot: Self.proj)
        t.apply(.assistantBlock(messageID: "m", block: .toolUse(id: "tu", name: "Bash", input: .object([:]))))
        t.apply(.result(TurnResult(subtype: "error_max_turns", isError: true, costUSD: 0, inputTokens: 0,
                                   outputTokens: 0, sessionID: "s", terminalReason: nil)))
        guard case .tool(let tb)? = t.blocks.first(where: { if case .tool = $0 { return true } else { return false } }) else {
            Issue.record("no tool block"); return
        }
        #expect(tb.status == .failed)
    }

    @Test func cancelPendingPermissionsAndNotice() {
        var t = Transcript(projectRoot: Self.proj)
        t.apply(.controlRequest(ControlRequest(requestID: "r", kind: .canUseTool(toolName: "Bash", input: .object([:]), description: nil, toolUseID: nil, suggestions: []))))
        t.cancelPendingPermissions()
        t.appendNotice(kind: .exited, text: "bye")
        #expect(t.blocks.contains { if case .permission(let p) = $0 { return p.state == .cancelled } else { return false } })
        #expect(notices(t, .exited) == ["bye"])
    }

    @Test func multiTurnIDsAreUnique() {
        var t = Transcript(projectRoot: Self.proj)
        let ok = InboundMessage.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                  outputTokens: 0, sessionID: "s", terminalReason: nil))
        for mid in ["msg_a", "msg_b"] {
            t.apply(.delta(.blockStart(index: 0, kind: "text")))
            t.apply(.delta(.text(index: 0, "x")))
            t.apply(.assistantBlock(messageID: mid, block: .text("x")))
            t.apply(ok)
        }
        // Second message without streaming, in a third turn.
        t.apply(.assistantBlock(messageID: "msg_c", block: .text("y")))
        let ids = t.blocks.map(\.id)
        #expect(ids.count == 3)
        #expect(Set(ids).count == 3)
    }

    @Test func twoMessagesInOneTurnGetDistinctIDs() {
        var t = Transcript(projectRoot: Self.proj)
        for mid in ["msg_a", "msg_b"] {
            t.apply(.delta(.blockStart(index: 0, kind: "text")))
            t.apply(.assistantBlock(messageID: mid, block: .text("x")))
        }
        #expect(Set(t.blocks.map(\.id)).count == 2)
    }

    @Test func interleavedBlocksStayInOrder() {
        var t = Transcript(projectRoot: Self.proj)
        t.apply(.delta(.blockStart(index: 0, kind: "thinking")))
        t.apply(.delta(.thinking(index: 0, "hm", estimatedTokens: 1)))
        t.apply(.assistantBlock(messageID: "m1", block: .thinking("hm")))
        t.apply(.delta(.blockStart(index: 1, kind: "text")))
        t.apply(.delta(.text(index: 1, "hi")))
        t.apply(.assistantBlock(messageID: "m1", block: .text("hi")))
        t.apply(.delta(.blockStart(index: 2, kind: "tool_use")))
        t.apply(.assistantBlock(messageID: "m1", block: .toolUse(id: "tu", name: "Bash", input: .object(["command": .string("ls")]))))
        guard t.blocks.count == 3,
              case .thinking(_, "hm", _) = t.blocks[0],
              case .assistantText(_, "hi") = t.blocks[1],
              case .tool(let tb) = t.blocks[2] else { Issue.record("wrong shape: \(t.blocks)"); return }
        #expect(tb.toolUseID == "tu" && tb.kind == .shell)
    }

    @Test func kindMismatchAppendsInsteadOfOverwriting() {
        var t = Transcript(projectRoot: Self.proj)
        t.apply(.delta(.blockStart(index: 0, kind: "text")))
        t.apply(.delta(.text(index: 0, "streamed")))
        t.apply(.assistantBlock(messageID: "m1", block: .thinking("t")))
        #expect(t.blocks.count == 2)
        #expect(Set(t.blocks.map(\.id)).count == 2)
    }

    @Test func staleEchoClearedAtResult() {
        var t = Transcript(projectRoot: Self.proj)
        t.appendUser(text: "go", id: UUID())
        t.apply(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                   outputTokens: 0, sessionID: "s", terminalReason: nil)))
        t.appendUser(text: "go", id: UUID())
        t.apply(.userEcho(text: "go", imageCount: 0, uuid: nil, isReplay: false))   // consumes only the new pending entry
        #expect(t.blocks.filter { if case .user = $0 { return true } else { return false } }.count == 2)
    }

    @Test func errorResultsReadAsWords() {
        func text(_ subtype: String) -> [String] {
            var t = Transcript(projectRoot: Self.proj)
            t.apply(.result(TurnResult(subtype: subtype, isError: true, costUSD: 0, inputTokens: 0, outputTokens: 0,
                                       sessionID: "s", terminalReason: nil)))
            return notices(t, .error)
        }
        #expect(text("error_during_execution") == ["Claude stopped with an error"])
        #expect(text("error_max_turns") == ["Reached the turn limit"])
        #expect(text("error_budget") == ["Claude reported an error (error_budget)"])
    }

    @Test func slashCommandEchoesBecomeNoticesNotUserBubbles() {
        var t = Transcript(projectRoot: Self.proj)
        for line in Fixture.lines("compact") { t.apply(InboundDecoder.decode(line)) }
        #expect(notices(t, .commandOutput) == ["Compacted"])
        let echoes = t.blocks.filter { if case .user(_, let text, _, _) = $0 { return text.contains("<local-command-stdout>") } else { return false } }
        #expect(echoes.isEmpty, "\(echoes)")
        t.apply(.userEcho(text: "<command-name>/cost</command-name>\n<command-args></command-args>", imageCount: 0, uuid: nil, isReplay: false))
        t.apply(.userEcho(text: "<local-command-stdout></local-command-stdout>", imageCount: 0, uuid: nil, isReplay: false))
        #expect(notices(t, .commandOutput) == ["Compacted", "/cost"])
    }

    @Test func emptyToolUseIDsGetUniqueFallbackIDs() {
        var t = Transcript(projectRoot: Self.proj)
        t.apply(.assistantBlock(messageID: "m1", block: .toolUse(id: "", name: "Bash", input: .object([:]))))
        t.apply(.assistantBlock(messageID: "m2", block: .toolUse(id: "", name: "Read", input: .object([:]))))
        let ids = t.blocks.compactMap { b -> String? in if case .tool(let tb) = b { return tb.toolUseID } else { return nil } }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(ids.allSatisfy { !$0.isEmpty })
        #expect(Set(t.blocks.map(\.id)).count == t.blocks.count)
    }

    // MARK: - Plan 3 task 2

    func questions(_ t: Transcript) -> [QuestionBlock] {
        t.blocks.compactMap { if case .question(let b) = $0 { return b } else { return nil } }
    }
    func plans(_ t: Transcript) -> [PlanBlock] {
        t.blocks.compactMap { if case .plan(let b) = $0 { return b } else { return nil } }
    }
    func users(_ t: Transcript) -> [(id: UUID, text: String, state: UserState)] {
        t.blocks.compactMap { if case .user(let id, let text, _, let state) = $0 { return (id, text, state) } else { return nil } }
    }

    @Test func askQuestionBecomesQuestionCard() {
        let t = replay("ask-question")
        #expect(permissions(t).isEmpty)
        let q = questions(t)
        #expect(q.count == 1)
        #expect(q.first?.state == .pending)
        #expect(q.first?.toolUseID == "toolu_01WV4Q8BpFWerPwrtSibM5PK")
        #expect(q.first?.questions.map(\.question) == ["Which language?", "Which toolchains?"])
        #expect(q.first?.questions.first?.header == "Language")
        #expect(q.first?.questions.first?.options.map(\.label) == ["Python", "Swift"])
        #expect(q.first?.questions.first?.options.first?.description == "Python toolchain and project setup")
        #expect(q.first?.questions.map(\.multiSelect) == [false, true])
        #expect(t.blocks.contains { $0.id == "q-40ef1a1e-119b-4077-9cb6-577187fdfd95" })
    }

    @Test func resolveQuestionRecordsAnswers() {
        var t = replay("ask-question")
        let rid = questions(t)[0].requestID
        t.resolveQuestion(requestID: rid, answers: ["Which language?": "Swift"])
        #expect(questions(t)[0].state == .answered)
        #expect(questions(t)[0].answers == ["Which language?": "Swift"])
        // A second resolve does not overwrite.
        t.resolveQuestion(requestID: rid, answers: ["Which language?": "Python"])
        #expect(questions(t)[0].answers == ["Which language?": "Swift"])
    }

    @Test func exitPlanModeBecomesPlanCard() {
        var t = Transcript(projectRoot: Self.root)
        var statesBeforeResolve: [CardState] = []
        for line in Fixture.lines("plan-allow") {
            let m = InboundDecoder.decode(line)
            t.apply(m)
            if case .controlRequest = m { statesBeforeResolve = plans(t).map(\.state) }
        }
        #expect(permissions(t).isEmpty)
        #expect(statesBeforeResolve == [.pending])
        let p = plans(t)
        #expect(p.count == 1)
        #expect(p.first?.plan.isEmpty == false)
        #expect(p.first?.planFilePath?.isEmpty == false)
        #expect(p.first?.toolUseID == "toolu_01GS8bJErh58CpqQq7X94hos")
        #expect(t.blocks.contains { $0.id == "plan-d259011a-7e47-48b0-9946-6fb1ff6ad28e" })
        t.resolvePlan(requestID: "d259011a-7e47-48b0-9946-6fb1ff6ad28e", approved: true, feedback: nil)
        #expect(plans(t)[0].state == .answered)
    }

    @Test func planRevisionAddsSecondCard() {
        // plan-deny.jsonl holds the first (denied) plan; the revised plan is the real ExitPlanMode
        // request line from plan-allow.jsonl.
        var t = Transcript(projectRoot: Self.root)
        for line in Fixture.lines("plan-deny") {
            let m = InboundDecoder.decode(line)
            t.apply(m)
            if case .controlRequest(let req) = m {
                t.resolvePlan(requestID: req.requestID, approved: false, feedback: "x")
            }
        }
        for line in Fixture.lines("plan-allow") {
            let m = InboundDecoder.decode(line)
            if case .controlRequest = m { t.apply(m) }
        }
        let p = plans(t)
        #expect(p.count == 2)
        #expect(p[0].state == .sentBack)
        #expect(p[0].feedback == "x")
        #expect(p[1].state == .pending)
        #expect(p[1].feedback == nil)
    }

    @Test func controlCancelCancelsCards() {
        var t = replay("ask-question")
        t.apply(.controlCancel(requestID: questions(t)[0].requestID))
        #expect(questions(t)[0].state == .cancelled)
        var t2 = Transcript(projectRoot: Self.root)
        for line in Fixture.lines("plan-allow") {
            let m = InboundDecoder.decode(line)
            if case .controlRequest = m { t2.apply(m) }
        }
        t2.apply(.controlCancel(requestID: plans(t2)[0].requestID))
        #expect(plans(t2)[0].state == .cancelled)
    }

    /// A queued `.next` message shows as queued, then flips to sent on its echo (matched by the id we
    /// passed to appendUser); the CLI's second echo of the same text (a different uuid) adds nothing.
    @Test func queuedMessageShowsUntilEchoed() throws {
        let queuedID = try #require(UUID(uuidString: "e719d33c-e08b-4d68-a809-47a7914b35ac"))
        var states: [UserState] = []
        var appended = false
        var t = Transcript(projectRoot: Self.root)
        for line in Fixture.lines("queue-next") {
            let m = InboundDecoder.decode(line)
            t.apply(m)
            if case .userEcho = m, !appended {
                appended = true
                t.appendUser(text: "PRIO-NEXT: reply with just the word BRAVO.", id: queuedID, queued: .next)
                states.append(users(t).last!.state)
            }
        }
        #expect(states == [.queued(.next)])
        let bravo = users(t).filter { $0.text.hasPrefix("PRIO-NEXT") }
        #expect(bravo.count == 1)
        #expect(bravo.first?.id == queuedID)
        #expect(bravo.first?.state == .sent)
        #expect(users(t).count == 2)
    }

    @Test func queueLaterRunsAsOwnTurn() throws {
        let queuedID = try #require(UUID(uuidString: "8cd64481-0ae5-477f-9225-6159000dddb1"))
        var t = Transcript(projectRoot: Self.root)
        var appended = false
        var stateAtFirstResult: UserState?
        var stateAfter: UserState?
        for line in Fixture.lines("queue-later") {
            let m = InboundDecoder.decode(line)
            t.apply(m)
            if case .userEcho = m, !appended {
                appended = true
                t.appendUser(text: "PRIO-LATER: reply with just the word DELTA.", id: queuedID, queued: .later)
            }
            if case .result = m, stateAtFirstResult == nil {
                stateAtFirstResult = users(t).first { $0.id == queuedID }?.state
            }
        }
        stateAfter = users(t).first { $0.id == queuedID }?.state
        #expect(stateAtFirstResult == .queued(.later))
        #expect(stateAfter == .sent)
        #expect(users(t).filter { $0.text.hasPrefix("PRIO-LATER") }.count == 1)
    }

    @Test func echoMatchesByUUIDBeforeText() {
        var t = Transcript(projectRoot: Self.root)
        let a = UUID(), b = UUID()
        t.appendUser(text: "same", id: a, queued: .next)
        t.appendUser(text: "same", id: b, queued: .next)
        t.apply(.userEcho(text: "same", imageCount: 0, uuid: b.uuidString.lowercased(), isReplay: true))
        #expect(users(t).map(\.state) == [.queued(.next), .sent])
        #expect(users(t).count == 2)
    }

    @Test func userBlockKeepsImageCount() {
        var t = Transcript(projectRoot: Self.root)
        let id = UUID()
        t.appendUser(text: "look", imageCount: 2, id: id, queued: nil)
        guard case .user(_, _, let n, let state)? = t.blocks.first else { Issue.record("no user block"); return }
        #expect(n == 2)
        #expect(state == .sent)
    }

    @Test func localCommandOutputIsNotice() {
        let t = replay("slash-local")
        let n = notices(t, .commandOutput)
        #expect(n.count == 1)
        #expect(n.first?.contains("subscription") == true)
        #expect(!t.blocks.contains { if case .assistantText = $0 { return true } else { return false } })
    }

    @Test func conversationResetAddsNotice() {
        var t = Transcript(projectRoot: Self.root)
        t.apply(.conversationReset(newSessionID: "abc"))
        #expect(notices(t, .reset) == ["Conversation cleared"])
    }

    @Test func toolBlockKeepsInputAndTiming() {
        var t = Transcript(projectRoot: Self.root)
        var clock = Date(timeIntervalSince1970: 1_000)
        for line in Fixture.lines("interrupt") {
            t.apply(InboundDecoder.decode(line), now: clock)
            clock = clock.addingTimeInterval(1)
        }
        let bash = tools(t).first { $0.name == "Bash" }
        #expect(bash?.input["command"]?.stringValue?.isEmpty == false)
        #expect(bash?.startedAt != nil)
        #expect(bash?.endedAt != nil)
        if let s = bash?.startedAt, let e = bash?.endedAt { #expect(e > s) }
        #expect(bash?.result != nil)
    }

    @Test func streamInterruptMarksTurn() {
        let t = replay("interrupt-stream")
        #expect(notices(t, .interrupted) == ["Interrupted"])
        // No block is left empty/streaming; the cut-off essay text stays as final.
        #expect(!t.blocks.contains { if case .assistantText(_, let s) = $0 { return s.isEmpty } else { return false } })
    }

    @Test func reechoDroppedEvenWhenAnotherBlockFollows() throws {
        // Two quick `.next` sends. Echo order in queue-next.jsonl: RUN, BRAVO, then BRAVO again after
        // the tool result, while RUN's block is already the last user block.
        let bravoID = try #require(UUID(uuidString: "e719d33c-e08b-4d68-a809-47a7914b35ac"))
        let runID = try #require(UUID(uuidString: "966c5a77-e19c-4e69-9cb4-458a9775a12a"))
        let bravo = "PRIO-NEXT: reply with just the word BRAVO."
        let run = "Run the Bash command `sleep 12` then reply DONE1."
        var t = Transcript(projectRoot: Self.root)
        t.appendUser(text: bravo, id: bravoID, queued: .next)
        t.appendUser(text: run, id: runID, queued: .next)
        for line in Fixture.lines("queue-next") { t.apply(InboundDecoder.decode(line)) }
        #expect(users(t).filter { $0.text == bravo }.count == 1)
        #expect(users(t).filter { $0.text == run }.count == 1)
        #expect(users(t).count == 2)
        #expect(users(t).allSatisfy { $0.state == .sent })
    }

    @Test func deliberateRepeatedMessageKeepsBothBubbles() {
        var t = Transcript(projectRoot: Self.root)
        let result = TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0, outputTokens: 0,
                                sessionID: "s", terminalReason: "completed")
        for _ in 0..<2 {
            let id = UUID()
            t.appendUser(text: "again", id: id)
            t.apply(.userEcho(text: "again", imageCount: 0, uuid: id.uuidString.lowercased(), isReplay: true))
            t.apply(.result(result))
        }
        // A third, CLI-originated send of the same text in its own turn also shows.
        t.apply(.userEcho(text: "again", imageCount: 0, uuid: UUID().uuidString.lowercased(), isReplay: false))
        #expect(users(t).map(\.text) == ["again", "again", "again"])
    }

    // MARK: CLI-generated user lines

    private func userCount(_ t: Transcript) -> Int {
        t.blocks.filter { if case .user = $0 { true } else { false } }.count
    }

    @Test(arguments: ["interrupt-stream", "interrupt", "compact"])
    func cliGeneratedUserLinesAreNotBubbles(fixture: String) throws {
        var live = Transcript(projectRoot: Self.root)
        for line in Fixture.lines(fixture) { live.apply(InboundDecoder.decode(line)) }
        // One real prompt each; the interrupt markers and the compaction summary are not user bubbles.
        #expect(userCount(live) == 1)
        let data = Data(Fixture.lines(fixture).map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n").utf8)
        var replayed = Transcript(projectRoot: Self.root)
        for m in TranscriptFile.messages(from: data).messages { replayed.apply(m) }
        #expect(userCount(replayed) == 1)
        let texts = live.blocks.compactMap { b -> String? in if case .user(_, let t, _, _) = b { t } else { nil } }
        #expect(!texts.contains { $0.hasPrefix("[Request interrupted") || $0.hasPrefix("This session is being continued") })
    }

    @Test func compactSummaryRecordShowsOneNotice() {
        let summary = #"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued from a previous conversation."}}"#
        let boundary = #"{"type":"system","subtype":"compact_boundary","compactMetadata":{"preTokens":10,"postTokens":2}}"#
        // With the boundary record first the summary adds nothing; alone it adds a plain notice.
        var withBoundary = Transcript(projectRoot: Self.root)
        for m in TranscriptFile.messages(from: Data((boundary + "\n" + summary).utf8)).messages { withBoundary.apply(m) }
        #expect(userCount(withBoundary) == 0)
        #expect(withBoundary.blocks.count == 1)
        var alone = Transcript(projectRoot: Self.root)
        for m in TranscriptFile.messages(from: Data(summary.utf8)).messages { alone.apply(m) }
        guard case .notice(_, .compacted, "Conversation compacted")? = alone.blocks.first, alone.blocks.count == 1 else {
            Issue.record("expected one compacted notice, got \(alone.blocks)"); return
        }
    }
}
