import AlloyCore
import Foundation
import Testing

private func decodeAll(_ name: String) -> [InboundMessage] {
    Fixture.lines(name).map(InboundDecoder.decode)
}

/// Drops the high-volume messages most tests do not care about.
private func significant(_ name: String) -> [InboundMessage] {
    decodeAll(name).filter {
        switch $0 {
        case .delta, .systemInit, .ignored: false
        default: true
        }
    }
}

@Suite struct InboundDecoderTests {
    @Test func editTurnDecodesToolUseThenEditResult() throws {
        let msgs = significant("edit-turn")
        let toolUseIdx = try #require(msgs.firstIndex {
            if case .assistantBlock(_, .toolUse(_, "Edit", _, _)) = $0 { true } else { false }
        })
        let resultIdx = try #require(msgs.firstIndex {
            if case .toolResult(let r) = $0, case .edit = r.result { true } else { false }
        })
        let doneIdx = try #require(msgs.firstIndex {
            if case .result(let r) = $0, r.costUSD > 0 { true } else { false }
        })
        #expect(toolUseIdx < resultIdx)
        #expect(resultIdx < doneIdx)
        guard case .toolResult(let r) = msgs[resultIdx],
              case .edit(let path, let original, let hunks) = r.result else {
            Issue.record("not an edit"); return
        }
        #expect(!hunks.isEmpty)
        #expect(original != nil)
        #expect(path.hasSuffix("login.swift"))
        #expect(!r.isError)
    }

    @Test func writeCreateHasNilOriginalAndContent() throws {
        let results = decodeAll("write-create").compactMap { m -> ToolResultMessage? in
            if case .toolResult(let r) = m { r } else { nil }
        }
        let write = try #require(results.first {
            if case .write = $0.result { true } else { false }
        })
        guard case .write(_, let isCreate, let content, let original, let hunks) = write.result else { return }
        #expect(isCreate)
        #expect(original == nil)
        #expect(hunks.isEmpty)
        #expect(!content.isEmpty)
    }

    @Test func writeUpdateHasOriginalAndHunks() throws {
        let results = decodeAll("write-update").compactMap { m -> ToolResultMessage? in
            if case .toolResult(let r) = m { r } else { nil }
        }
        let write = try #require(results.first {
            if case .write = $0.result { true } else { false }
        })
        guard case .write(_, let isCreate, _, let original, let hunks) = write.result else { return }
        #expect(!isCreate)
        #expect(original != nil)
        #expect(!hunks.isEmpty)
    }

    @Test func failedToolResultIsStringForm() throws {
        let r = try #require(decodeAll("failed-tool").compactMap { m -> ToolResultMessage? in
            if case .toolResult(let r) = m { r } else { nil }
        }.first)
        #expect(r.isError)
        guard case .message(let text) = r.result else { Issue.record("not message form"); return }
        #expect(text.hasPrefix("Error"))
    }

    @Test func canUseToolDecodes() throws {
        let msgs = decodeAll("permission-allow")
        let req = try #require(msgs.compactMap { m -> ControlRequest? in
            if case .controlRequest(let c) = m { c } else { nil }
        }.first)
        #expect(!req.requestID.isEmpty)
        guard case .canUseTool(let tool, let input, _, let toolUseID, let suggestions) = req.kind else {
            Issue.record("not canUseTool"); return
        }
        #expect(tool == "Edit")
        #expect(input["file_path"]?.stringValue != nil)
        #expect(toolUseID != nil)
        #expect(!suggestions.isEmpty)
        #expect(msgs.contains(.ignored(type: "control_response")))
    }

    @Test func interruptEndsWithAbortedTools() throws {
        let msgs = decodeAll("interrupt")
        #expect(msgs.contains { if case .controlCancel = $0 { true } else { false } })
        let r = try #require(msgs.compactMap { m -> TurnResult? in
            if case .result(let r) = m { r } else { nil }
        }.last)
        #expect(r.terminalReason == "aborted_tools")
        #expect(r.isError)
    }

    @Test func unknownAndMalformedLinesNeverThrow() {
        let msgs = decodeAll("unknown-lines")
        #expect(msgs.count == 4)
        if case .assistantBlock = msgs[0] {} else { Issue.record("line 0: \(msgs[0])") }
        #expect(msgs[1] == .unknown(type: "brand_new_thing"))
        #expect(msgs[2] == .unknown(type: "<malformed>"))
        if case .result = msgs[3] {} else { Issue.record("line 3: \(msgs[3])") }
    }

    @Test func systemInitEveryTurnIsDecodedEachTime() throws {
        let msgs = decodeAll("compact")
        let inits = msgs.compactMap { m -> SystemInit? in
            if case .systemInit(let s) = m { s } else { nil }
        }
        #expect(inits.count == 2)
        #expect(!inits[0].sessionID.isEmpty)
        #expect(!inits[0].tools.isEmpty)
        let boundary = try #require(msgs.compactMap { m -> Int?? in
            if case .compactBoundary(let pre, _) = m { .some(pre) } else { nil }
        }.first)
        #expect(boundary != nil)
    }

    @Test func thinkingSummarizedHasText() {
        let msgs = decodeAll("thinking-summarized")
        let has = msgs.contains {
            switch $0 {
            case .delta(.thinking(_, let t, _)): !t.isEmpty
            case .assistantBlock(_, .thinking(let t)): !t.isEmpty
            default: false
            }
        }
        #expect(has)
    }

    @Test func thinkingTokensAndUserEchoDecode() {
        let msgs = decodeAll("permission-allow")
        #expect(msgs.contains { if case .thinkingTokens(let n) = $0 { n > 0 } else { false } })
        let echoes = decodeAll("edit-turn").compactMap { m -> Bool? in
            if case .userEcho(_, _, _, let replay) = m { replay } else { nil }
        }
        #expect(echoes == [true])
    }

    @Test func wrongTypesFallBackWithoutCrashing() {
        let lines = [
            #"{"type":"result","is_error":"yes","total_cost_usd":"x","usage":[1]}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":5}]},"tool_use_result":7}"#,
            #"{"type":"control_request","request":"nope"}"#,
            #"[1,2,3]"#,
            #"{"type":42}"#,
            ""
        ]
        for l in lines { _ = InboundDecoder.decode(Data(l.utf8)) }
        #expect(InboundDecoder.decode(Data(lines[3].utf8)) == .unknown(type: "<malformed>"))
        #expect(InboundDecoder.decode(Data(lines[4].utf8)) == .unknown(type: "<malformed>"))
        #expect(InboundDecoder.decode(Data(lines[2].utf8)) == .unknown(type: "control_request"))
        if case .result(let r) = InboundDecoder.decode(Data(lines[0].utf8)) {
            #expect(r.isError == false)
            #expect(r.costUSD == 0)
            #expect(r.inputTokens == 0)
        } else { Issue.record("result line did not decode to .result") }
        if case .toolResult(let t) = InboundDecoder.decode(Data(lines[1].utf8)) {
            #expect(t.toolUseID == "")
            #expect(t.result == .other(.number(7)))
        } else { Issue.record("user line did not decode to .toolResult") }
    }

    @Test func permissionDeniedDecodes() {
        let line = #"{"type":"system","subtype":"permission_denied","tool_name":"Edit","tool_use_id":"toolu_1","message":"Denied by host"}"#
        #expect(InboundDecoder.decode(Data(line.utf8))
            == .permissionDenied(toolName: "Edit", toolUseID: "toolu_1", message: "Denied by host"))
        let bare = #"{"type":"system","subtype":"permission_denied"}"#
        #expect(InboundDecoder.decode(Data(bare.utf8))
            == .permissionDenied(toolName: "", toolUseID: "", message: ""))
    }

    // MARK: Plan 3 wire additions

    @Test func askQuestionDecodesAsCanUseTool() throws {
        let msgs = decodeAll("ask-question")
        let req = try #require(msgs.compactMap { m -> ControlRequest? in
            if case .controlRequest(let r) = m { r } else { nil }
        }.first)
        guard case .canUseTool(let name, let input, _, _, _) = req.kind else { Issue.record("not can_use_tool"); return }
        #expect(name == "AskUserQuestion")
        let options = try #require(input["questions"]?.arrayValue?.first?["options"]?.arrayValue)
        #expect(!options.isEmpty)
    }

    @Test func slashLocalDecodesAsCommandOutput() {
        let msgs = decodeAll("slash-local")
        let outputs = msgs.compactMap { m -> String? in
            if case .localCommandOutput(let t) = m { t } else { nil }
        }
        #expect(outputs.count == 1)
        #expect(outputs.first?.isEmpty == false)
        #expect(!msgs.contains { if case .assistantBlock = $0 { true } else { false } })
    }

    @Test func clearDecodesReset() throws {
        let msgs = decodeAll("clear")
        let resetIdx = try #require(msgs.firstIndex { if case .conversationReset = $0 { true } else { false } })
        guard case .conversationReset(let newID) = msgs[resetIdx] else { return }
        let nextInit = try #require(msgs[resetIdx...].compactMap { m -> SystemInit? in
            if case .systemInit(let i) = m { i } else { nil }
        }.first)
        // The probe shows `new_conversation_id` (9b71eeda...) is NOT the following init's session_id
        // (4ba97075...); the init after a reset is what the CLI actually continues under.
        #expect(newID == "9b71eeda-bf44-4122-a0ed-978ed5bdc098")
        #expect(nextInit.sessionID == "4ba97075-8d57-4b30-b123-11a9a1edd39e")
    }

    @Test func statusCarriesMode() {
        let msgs = decodeAll("control-responses")
        #expect(msgs.contains(.statusChanged(permissionMode: "plan")))
        let line = Data(#"{"type":"system","subtype":"status","status":"compacting","session_id":"s"}"#.utf8)
        #expect(InboundDecoder.decode(line) == .statusChanged(permissionMode: nil))
    }

    @Test func imageEchoCountsImages() throws {
        let echo = try #require(decodeAll("image").compactMap { m -> (String, Int, String?, Bool)? in
            if case .userEcho(let t, let n, let id, let replay) = m { (t, n, id, replay) } else { nil }
        }.first)
        #expect(echo.1 == 1)
        #expect(echo.0.contains("color"))
        #expect(echo.2 != nil)
        #expect(echo.3)
    }

    @Test func initializeResponseDecodes() throws {
        let msgs = decodeAll("control-responses")
        let found = try #require(msgs.first { if case .controlResponse("c0", _) = $0 { true } else { false } })
        guard case .controlResponse(_, .success(let body)) = found else { Issue.record("not success"); return }
        #expect(body["commands"]?.arrayValue?.isEmpty == false)
    }

    @Test func controlErrorDecodes() {
        let msgs = decodeAll("control-responses")
        #expect(msgs.contains(.controlResponse(requestID: "sm3",
            result: .error(message: "Model 'nonexistent-model' not found", code: "not_found"))))
        #expect(msgs.contains { if case .controlResponse("pm2", .error(_, "bypass_not_launched")) = $0 { true } else { false } })
    }

    @Test func echoedHostControlResponsesStayIgnored() {
        for line in Fixture.lines("plan-deny") {
            guard let text = String(data: line, encoding: .utf8), text.contains(#""behavior":"deny""#),
                  text.hasPrefix(#"{"type":"control_response""#) else { continue }
            #expect(InboundDecoder.decode(line) == .ignored(type: "control_response"))
            return
        }
        Issue.record("no echoed deny response in fixture")
    }

    @Test func systemInitKeepsSkills() throws {
        let inits = decodeAll("slash-local").compactMap { m -> SystemInit? in
            if case .systemInit(let i) = m { i } else { nil }
        }
        let first = try #require(inits.first)
        #expect(!first.skills.isEmpty)
        #expect(!first.terminalSlashCommands.isEmpty)
        #expect(!first.agents.isEmpty)
        #expect(first.claudeCodeVersion != nil)
        #expect(first.cwd != nil)
    }

    @Test func commandsChangedDecodes() throws {
        let msgs = decodeAll("control-responses")
        let cmds = try #require(msgs.compactMap { m -> [SlashCommandInfo]? in
            if case .commandsChanged(let c) = m { c } else { nil }
        }.first)
        #expect(!cmds.isEmpty)
        #expect(!cmds[0].name.isEmpty)
    }

    @Test func planFixturesDecode() {
        let deny = decodeAll("plan-deny")
        #expect(deny.contains { if case .controlRequest(let r) = $0, case .canUseTool("ExitPlanMode", _, _, _, _) = r.kind { true } else { false } })
        let allow = decodeAll("plan-allow")
        #expect(allow.contains { if case .toolResult(let r) = $0, r.text.contains("approved your plan") { true } else { false } })
    }

    @Test func resultCarriesDurationAndTurns() throws {
        let r = try #require(decodeAll("queue-later").compactMap { m -> TurnResult? in
            if case .result(let r) = m { r } else { nil }
        }.first)
        #expect(r.durationMS != nil)
        #expect(r.numTurns != nil)
    }

    @Test func toolResultKeepsRawToolUseResult() throws {
        let r = try #require(decodeAll("ask-question").compactMap { m -> ToolResultMessage? in
            if case .toolResult(let r) = m { r } else { nil }
        }.first)
        #expect(r.raw?["answers"] != nil)
        #expect(r.raw?.objectValue != nil)
    }

    @Test func interruptStreamFixtureDecodes() {
        let msgs = decodeAll("interrupt-stream")
        #expect(msgs.contains { if case .result(let r) = $0, r.terminalReason == "aborted_streaming" { true } else { false } })
    }

    @Test func queueFixturesDecodeEchoUUIDs() {
        for name in ["queue-next", "queue-later"] {
            let echoes = decodeAll(name).compactMap { m -> String? in
                if case .userEcho(_, _, let id, true) = m { id } else { nil }
            }
            #expect(echoes.count >= 2, "\(name)")
        }
    }

    @Test func parseKeepsBooleansApartFromNumbers() {
        let v = JSONValue.parse(Data(#"{"t":true,"f":false,"one":1,"zero":0,"x":1.5}"#.utf8))
        #expect(v?["t"] == .bool(true) && v?["f"] == .bool(false))
        #expect(v?["one"] == .number(1) && v?["zero"] == .number(0) && v?["x"] == .number(1.5))
    }
}

@Suite struct InboundDecoderParentTests {
    @Test func subagentReadCarriesParent() throws {
        let msgs = decodeAll("subagent-read")
        var agentID: String?
        var readID: String?
        for m in msgs {
            if case .assistantBlock(_, .toolUse(let id, "Agent", _, let parent)) = m { agentID = id; #expect(parent == nil) }
            if case .assistantBlock(_, .toolUse(let id, "Read", _, _)) = m { readID = id }
        }
        let agent = try #require(agentID)
        let read = try #require(readID)
        let readUse = try #require(msgs.compactMap { m -> String? in
            if case .assistantBlock(_, .toolUse(let id, "Read", _, let parent)) = m, id == read { return parent }
            return nil
        }.first)
        #expect(readUse == agent)
        let result = try #require(msgs.compactMap { m -> ToolResultMessage? in
            if case .toolResult(let r) = m, r.toolUseID == read { return r }
            return nil
        }.first)
        #expect(result.parentToolUseID == agent)
        let top = try #require(msgs.compactMap { m -> ToolResultMessage? in
            if case .toolResult(let r) = m, r.toolUseID == agent { return r }
            return nil
        }.first)
        #expect(top.parentToolUseID == nil)
    }

    @Test func readResultDecodes() throws {
        let truncated = try #require(decodeAll("read-truncated").compactMap { m -> ReadResult? in
            if case .toolResult(let r) = m { return r.read }
            return nil
        }.first)
        #expect(truncated.truncated && truncated.numLines < truncated.totalLines)
        #expect(truncated.startLine == 1 && truncated.filePath.hasSuffix("huge.txt"))
        let edit = decodeAll("edit-turn").compactMap { m -> ReadResult? in
            if case .toolResult(let r) = m { return r.read }
            return nil
        }
        let read = try #require(edit.first)
        #expect(read.startLine == 1 && !read.truncated)
    }

    @Test func mcpToolResultContentIsAnArray() throws {
        let result = try #require(decodeAll("mcp-tool-call").compactMap { m -> ToolResultMessage? in
            if case .toolResult(let r) = m { return r }
            return nil
        }.first)
        #expect(result.text == "ECHO:hello5" && !result.isError)
        #expect(result.read == nil)
    }
}
