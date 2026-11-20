import AlloyCore
import Foundation
import Testing
@testable import AlloyACP

@Suite struct ModelsTests {
    private func decode<T: Decodable>(_ json: String, as: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func updateDecodingToleratesUnknownVariantAndFields() throws {
        let unknown = try decode(#"{"sessionId":"s","update":{"sessionUpdate":"brand_new","x":[1,2]}}"#, as: ACPSessionNotification.self)
        #expect(unknown.update == .unknown("brand_new"))
        let chunk = try decode(
            #"{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","messageId":"m1","future":true,"content":{"type":"text","text":"hi","extra":1}}}"#,
            as: ACPSessionNotification.self)
        #expect(chunk.update == .agentMessageChunk(ACPMessageChunk(messageId: "m1", content: .text("hi"))))
        // A known kind with a malformed body degrades instead of failing the line.
        let bad = try decode(#"{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":5}}"#, as: ACPSessionNotification.self)
        #expect(bad.update == .unknown("tool_call"))
    }

    @Test func toolCallAndDiffDecode() throws {
        let n = try decode(#"""
        {"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Edit a.txt","kind":"edit","status":"in_progress",
         "content":[{"type":"diff","path":"a.txt","oldText":null,"newText":"hello\n"},{"type":"terminal","terminalId":"x"},{"type":"mystery"}],
         "locations":[{"path":"a.txt","line":3}],"rawInput":{"path":"a.txt"}}}
        """#, as: ACPSessionNotification.self)
        guard case .toolCall(let call) = n.update else { Issue.record("not a tool call"); return }
        #expect(call.toolCallId == "t1")
        #expect(call.content == [.diff(path: "a.txt", oldText: nil, newText: "hello\n"), .terminal(terminalId: "x"), .unknown("mystery")])
        #expect(call.locations == [ACPLocation(path: "a.txt", line: 3)])
    }

    @Test func updateKindsDecode() throws {
        func u(_ body: String) throws -> ACPSessionUpdate { try decode(#"{"sessionId":"s","update":\#(body)}"#, as: ACPSessionNotification.self).update }
        #expect(try u(#"{"sessionUpdate":"plan","entries":[{"content":"a","priority":"high","status":"pending"}]}"#)
                == .plan([ACPPlanEntry(content: "a", priority: "high", status: "pending")]))
        #expect(try u(#"{"sessionUpdate":"current_mode_update","currentModeId":"plan"}"#) == .currentMode("plan"))
        #expect(try u(#"{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"a","description":"d","input":{"hint":"h"}},{"name":"b","input":null}]}"#).isCommands(2))
        guard case .usage(let usage) = try u(#"{"sessionUpdate":"usage_update","used":5,"size":100,"cost":{"amount":0.5,"currency":"USD"}}"#) else { Issue.record("usage"); return }
        #expect(usage.used == 5 && usage.size == 100 && usage.cost?.amount == 0.5)
        guard case .sessionInfo(let info) = try u(#"{"sessionUpdate":"session_info_update","_meta":{"codex":{"threadStatus":{"type":"idle"}}}}"#) else { Issue.record("info"); return }
        #expect(info.title == nil && info.meta?["codex"] != nil)
        guard case .notice(let n) = try u(#"{"sessionUpdate":"notice","level":"warning","message":"careful"}"#) else { Issue.record("notice"); return }
        #expect(n.message == "careful")
    }

    @Test func configOptionFlattensGroupsAndKeepsUnknownCategory() throws {
        let o = try decode(#"""
        {"id":"model","name":"Model","category":"brand_new","type":"select","currentValue":"a",
         "options":[{"value":"a","name":"A"},{"group":"G","name":"G","options":[{"value":"b","name":"B"},{"value":"c"}]}]}
        """#, as: ACPConfigOption.self)
        #expect(o.category == "brand_new")
        #expect(o.options.map(\.value) == ["a", "b", "c"])
        #expect(o.currentValue == .string("a"))
    }

    @Test func initializeResultAndCapabilities() throws {
        let r = try decode(#"""
        {"protocolVersion":1,"agentInfo":{"name":"x","title":"X","version":"1"},
         "agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true},"mcpCapabilities":{"http":true,"sse":false},
          "sessionCapabilities":{"resume":{},"list":{}},"somethingNew":1},
         "authMethods":[{"id":"a","name":"A","type":"terminal","args":["login"]},{"id":"b"}]}
        """#, as: ACPInitializeResult.self)
        #expect(r.agentCapabilities?.canLoad == true)
        #expect(r.agentCapabilities?.canResume == true)
        #expect(r.agentCapabilities?.acceptsImages == true)
        #expect(r.authMethods.map(\.id) == ["a", "b"])
        #expect(r.authMethods[0].args == ["login"])
        let empty = try decode("{}", as: ACPInitializeResult.self)
        #expect(empty.authMethods.isEmpty)
    }

    @Test func initializeParamsAdvertiseOnlyImplementedCapabilities() throws {
        let p = ACPInitializeParams(clientInfo: .init(name: "alloy", version: "1"))
        let json = try JSONValue.parse(JSONEncoder().encode(p))!
        #expect(json["protocolVersion"]?.intValue == 1)
        let caps = json["clientCapabilities"]!
        #expect(caps["terminal"] == nil)
        #expect(caps["fs"]?["readTextFile"]?.boolValue == true)
        #expect(caps["auth"]?["terminal"]?.boolValue == true)
        #expect(caps["session"]?["notices"]?.boolValue == true)
        #expect(caps["session"]?["compaction"]?.boolValue == true)
    }

    @Test func mcpServersEncodeStdioAndHTTP() throws {
        let p = ACPSessionNewParams(cwd: "/p", mcpServers: [
            .stdio(name: "n", command: "c", args: ["a"], env: [ACPNameValue(name: "K", value: "V")]),
            .http(name: "h", url: "http://127.0.0.1:1/", headers: [ACPNameValue(name: "Authorization", value: "Bearer t")]),
        ])
        let json = try JSONValue.parse(JSONEncoder().encode(p))!
        let servers = json["mcpServers"]!.arrayValue!
        #expect(servers[0]["command"]?.stringValue == "c")
        #expect(servers[0]["type"] == nil)
        #expect(servers[1]["type"]?.stringValue == "http")
        #expect(servers[1]["headers"]?.arrayValue?.first?["name"]?.stringValue == "Authorization")
    }

    @Test func promptAndPermissionShapes() throws {
        let p = ACPPromptParams(sessionId: "s", prompt: [.text("hi"), .image(data: "AAA", mimeType: "image/png")])
        let json = try JSONValue.parse(JSONEncoder().encode(p))!
        #expect(json["prompt"]?.arrayValue?[0]["type"]?.stringValue == "text")
        #expect(json["prompt"]?.arrayValue?[1]["mimeType"]?.stringValue == "image/png")
        let req = try decode(#"""
        {"sessionId":"s","toolCall":{"toolCallId":"t","title":"Edit files","kind":"edit","status":"pending"},
         "options":[{"optionId":"o1","name":"Yes","kind":"allow_once"},{"optionId":"o2","name":"No","kind":"reject_once"}]}
        """#, as: ACPPermissionRequest.self)
        #expect(req.options.map(\.kind) == ["allow_once", "reject_once"])
        #expect(ACPPermissionOutcome.cancelled.json["outcome"]?["outcome"]?.stringValue == "cancelled")
        let enc = try JSONValue.parse(JSONEncoder().encode(ACPPermissionOutcome.selected(optionId: "o1")))!
        #expect(enc["outcome"]?["optionId"]?.stringValue == "o1")
    }

    @Test func promptResultToleratesOddStopReasonAndUsage() throws {
        let r = try decode(#"{"stopReason":"new_reason","usage":{"totalTokens":3},"_meta":{}}"#, as: ACPPromptResult.self)
        #expect(r.stopReason == "new_reason" && r.usage?.totalTokens == 3)
        #expect(try decode(#"{"stopReason":"cancelled","usage":null}"#, as: ACPPromptResult.self).usage == nil)
    }

    // MARK: probe fixtures

    private func fixtureLines(_ name: String) throws -> [(dir: String, value: JSONValue)] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { raw in
            guard let rec = JSONValue.parse(Data(raw.utf8)), let dir = rec["dir"]?.stringValue,
                  let line = rec["line"]?.stringValue, let v = JSONValue.parse(Data(line.utf8)) else { return nil }
            return (dir, v)
        }
    }

    @Test(arguments: ["probe-codex-session", "probe-codex-permission", "probe-opencode-qwen7b", "probe-opencode-qwen27b"])
    func decodesEveryProbeFixture(_ name: String) throws {
        let lines = try fixtureLines(name)
        #expect(lines.count > 10)
        var updates = 0, results = 0, requests = 0
        var unknownKinds = Set<String>()
        for (dir, msg) in lines where dir == "a2c" {
            if let method = msg["method"]?.stringValue {
                let params = msg["params"] ?? .null
                if method == "session/update" {
                    let n: ACPSessionNotification = try params.decode()
                    updates += 1
                    if case .unknown(let k) = n.update { unknownKinds.insert(k) }
                } else if method == "session/request_permission" {
                    let r: ACPPermissionRequest = try params.decode()
                    #expect(!r.options.isEmpty)
                    requests += 1
                }
            } else if let result = msg["result"], result != .null {
                // Initialize, session/new, load, resume, set_config_option and prompt results share no marker;
                // decode by the keys present.
                if result["agentCapabilities"] != nil || result["authMethods"] != nil { _ = try result.decode(ACPInitializeResult.self) }
                else if result["sessionId"] != nil { _ = try result.decode(ACPSessionNewResult.self) }
                else if result["stopReason"] != nil { _ = try result.decode(ACPPromptResult.self); results += 1 }
                else { _ = try result.decode(ACPSessionStateResult.self) }
            }
        }
        #expect(updates > 0)
        #expect(results > 0)
        // Every kind in the probes is a known one.
        #expect(unknownKinds.isEmpty, "unknown kinds: \(unknownKinds)")
        if name == "probe-codex-permission" { #expect(requests == 1) }
    }
}

private extension ACPSessionUpdate {
    func isCommands(_ n: Int) -> Bool { if case .availableCommands(let c) = self { c.count == n } else { false } }
}
