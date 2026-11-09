import Foundation
import Network
import Testing
@testable import AlloyCore

private func fixtureBodies() throws -> [Data] {
    let url = try #require(Bundle.module.url(forResource: "hook-write", withExtension: "jsonl", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
}

private func blockThread(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

private actor Seen {
    var requests: [(HookRequest, MCPCaller)] = []
    func add(_ r: HookRequest, _ c: MCPCaller) { requests.append((r, c)) }
}

private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

private struct Harness {
    let server: LocalServer
    let url: URL
    let session: UUID
    let token: String
    let urlSession = URLSession(configuration: .ephemeral)

    static func make(limits: LocalServer.Limits = .init(), report: (@Sendable (String) -> Void)? = nil) async throws -> Harness {
        let server = LocalServer(tools: [], limits: limits, report: report)
        let url = try await server.start()
        let session = UUID()
        let token = await server.token(for: session)
        return Harness(server: server, url: url, session: session, token: token)
    }

    func stop() async { urlSession.invalidateAndCancel(); await server.stop() }

    func post(_ event: HookEvent, _ body: Data, token: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: Hooks.url(for: event, serverURL: url))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token ?? self.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await urlSession.data(for: req)
        return (data, resp as! HTTPURLResponse)
    }
}

private final class Raw: @unchecked Sendable {
    let conn: NWConnection
    init(port: Int) {
        conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        conn.start(queue: .global())
    }
    deinit { conn.cancel() }
    /// Sends `text`, then reads until the server has sent a full head and closes or the body is complete.
    func exchange(_ text: String) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in cont.resume() })
        }
        var buffer = Data()
        while true {
            let chunk: Data? = await withCheckedContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, _, _ in cont.resume(returning: d) }
            }
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let r = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[0..<r.lowerBound], as: UTF8.self)
                let n = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                if buffer.count >= r.upperBound + n { break }
            }
        }
        return String(decoding: buffer, as: UTF8.self)
    }
}

private func port(of url: URL) -> Int { url.port ?? 0 }

@Suite struct HookServerTests {
    @Test func oversizedHookBodyGets200EmptyAndIsReportedOnce() async throws {
        let log = Messages()
        let h = try await Harness.make(report: { log.add($0) })
        let big = Data(repeating: 0x20, count: LocalServer.maxBodyBytes + 1)
        for _ in 0..<2 {
            let (data, resp) = try await h.post(.postToolUse, big)
            #expect(resp.statusCode == 200 && data == Data("{}".utf8))
        }
        #expect(log.all.count == 1)
        // The connection still serves a normal hook afterwards.
        let (ok, resp) = try await h.post(.preToolUse, try fixtureBodies()[0])
        #expect(resp.statusCode == 200 && ok == Data("{}".utf8))
        await h.stop()
    }

    @Test func hookBodyAboveDrainLimitGetsEmptyReplyThenClose() async throws {
        let h = try await Harness.make()
        let raw = Raw(port: port(of: h.url))
        let head = "POST /hooks/post-tool-use HTTP/1.1\r\nHost: 127.0.0.1:\(port(of: h.url))\r\nAuthorization: Bearer \(h.token)\r\nContent-Length: 999999999\r\n\r\n"
        let reply = await raw.exchange(head)
        #expect(reply.hasPrefix("HTTP/1.1 200"))
        #expect(reply.hasSuffix("{}"))
        await h.stop()
    }

    @Test func eventMismatchWithRouteGetsEmptyAndIsNotHandled() async throws {
        let h = try await Harness.make()
        let seen = Seen()
        await h.server.setHookHandler { req, caller in await seen.add(req, caller); return HookReply(additionalContext: "x") }
        let (data, resp) = try await h.post(.postToolUse, try fixtureBodies()[0]) // a PreToolUse body
        #expect(resp.statusCode == 200 && data == Data("{}".utf8))
        #expect(await seen.requests.isEmpty)
        await h.stop()
    }

    @Test func additionalContextIsTruncatedAtTheEncoder() throws {
        let long = String(repeating: "a", count: 20_000)
        let json = try #require(JSONValue.parse(HookReply(additionalContext: long).json(for: .preToolUse)))
        let text = try #require(json["hookSpecificOutput"]?["additionalContext"]?.stringValue)
        #expect(text.count == 9_500 && text.hasSuffix("…"))
        let short = String(repeating: "b", count: 9_500)
        let kept = JSONValue.parse(HookReply(additionalContext: short).json(for: .preToolUse))
        #expect(kept?["hookSpecificOutput"]?["additionalContext"]?.stringValue == short)
    }

    @Test func hookRouteRejectsBadHostAndOrigin() async throws {
        let h = try await Harness.make()
        let p = port(of: h.url)
        let body = "{}"
        func req(host: String, extra: String = "") -> String {
            "POST /hooks/pre-tool-use HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(h.token)\r\n\(extra)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        }
        #expect(await Raw(port: p).exchange(req(host: "evil.example:\(p)")).hasPrefix("HTTP/1.1 403"))
        #expect(await Raw(port: p).exchange(req(host: "127.0.0.1:\(p)", extra: "Origin: http://evil.example\r\n")).hasPrefix("HTTP/1.1 403"))
        #expect(await Raw(port: p).exchange(req(host: "127.0.0.1:\(p)")).hasPrefix("HTTP/1.1 200"))
        await h.stop()
    }

    @Test func getOnHookRouteIs405() async throws {
        let h = try await Harness.make()
        var r = URLRequest(url: Hooks.url(for: .preToolUse, serverURL: h.url))
        r.httpMethod = "GET"
        r.setValue("Bearer \(h.token)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await h.urlSession.data(for: r)
        #expect((resp as? HTTPURLResponse)?.statusCode == 405)
        await h.stop()
    }

    @Test func reportRearmsAfterRevoke() async throws {
        let log = Messages()
        let h = try await Harness.make(report: { log.add($0) })
        _ = try await h.post(.preToolUse, Data("junk".utf8))
        _ = try await h.post(.preToolUse, Data("junk".utf8))
        #expect(log.all.count == 1)
        await h.server.revoke(session: h.session)
        let again = await h.server.token(for: h.session)
        _ = try await h.post(.preToolUse, Data("junk".utf8), token: again)
        #expect(log.all.count == 2)
        await h.stop()
    }

    @Test func hookRoutesRoundTripWithToken() async throws {
        let h = try await Harness.make()
        let seen = Seen()
        await h.server.setHookHandler { req, caller in
            await seen.add(req, caller)
            return HookReply(additionalContext: "note for \(req.event.rawValue)")
        }
        let bodies = try fixtureBodies()
        let (pre, preResp) = try await h.post(.preToolUse, bodies[0])
        let (post, postResp) = try await h.post(.postToolUse, bodies[1])
        #expect(preResp.statusCode == 200 && postResp.statusCode == 200)
        #expect(JSONValue.parse(pre)?["hookSpecificOutput"]?["hookEventName"]?.stringValue == "PreToolUse")
        #expect(JSONValue.parse(pre)?["hookSpecificOutput"]?["additionalContext"]?.stringValue == "note for PreToolUse")
        #expect(JSONValue.parse(post)?["hookSpecificOutput"]?["hookEventName"]?.stringValue == "PostToolUse")
        let got = await seen.requests
        #expect(got.count == 2)
        #expect(got[0].0.event == .preToolUse && got[0].0.toolName == "Write" && got[0].0.toolResponse == nil)
        #expect(got[0].0.toolUseID.hasPrefix("toolu_") && got[0].0.toolInput["file_path"]?.stringValue != nil)
        #expect(!got[0].0.cliSessionID.isEmpty)
        #expect(got[1].0.event == .postToolUse && got[1].0.toolResponse != nil)
        #expect(got.allSatisfy { $0.1.sessionID == h.session })
        await h.stop()
    }

    @Test func noHandlerRepliesEmptyAtOnce() async throws {
        let h = try await Harness.make()
        let (data, resp) = try await h.post(.preToolUse, try fixtureBodies()[0])
        #expect(resp.statusCode == 200 && data == Data("{}".utf8))
        await h.stop()
    }

    @Test func hookWithRevokedTokenIs401AndHarmless() async throws {
        let h = try await Harness.make()
        let seen = Seen()
        await h.server.setHookHandler { req, caller in await seen.add(req, caller); return HookReply() }
        await h.server.revoke(session: h.session)
        let (_, resp) = try await h.post(.preToolUse, try fixtureBodies()[0])
        #expect(resp.statusCode == 401)
        let (_, bad) = try await h.post(.postToolUse, try fixtureBodies()[1], token: "nope")
        #expect(bad.statusCode == 401)
        #expect(await seen.requests.isEmpty)
        await h.stop()
    }

    @Test func replyNeverCarriesPermissionDecision() throws {
        for event in [HookEvent.preToolUse, .postToolUse] {
            for reply in [HookReply(), HookReply(additionalContext: "x"), HookReply(additionalContext: "")] {
                let json = try #require(JSONValue.parse(reply.json(for: event)))
                func keys(_ v: JSONValue) -> Set<String> {
                    guard case .object(let o) = v else { return [] }
                    return o.reduce(into: Set(o.keys)) { $0.formUnion(keys($1.value)) }
                }
                let all = keys(json)
                #expect(all.isDisjoint(with: ["permissionDecision", "decision", "updatedInput", "permissionDecisionReason", "continue"]))
            }
        }
        #expect(HookReply().json(for: .preToolUse) == Data("{}".utf8))
        #expect(HookReply(additionalContext: "hi").json(for: .postToolUse)
                == Data(#"{"hookSpecificOutput":{"additionalContext":"hi","hookEventName":"PostToolUse"}}"#.utf8))
    }

    @Test func slowHandlerRepliesEmptyWithinBudget() async throws {
        var limits = LocalServer.Limits()
        limits.hookDeadline = .milliseconds(200)
        let h = try await Harness.make(limits: limits)
        await h.server.setHookHandler { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return HookReply(additionalContext: "late")
        }
        let started = ContinuousClock.now
        let (data, resp) = try await h.post(.preToolUse, try fixtureBodies()[0])
        let took = started.duration(to: .now)
        #expect(resp.statusCode == 200 && data == Data("{}".utf8))
        #expect(took < .seconds(2))
        await h.stop()
    }

    @Test func uncooperativeHandlerStillGetsEmptyReply() async throws {
        var limits = LocalServer.Limits()
        limits.hookDeadline = .milliseconds(100)
        let h = try await Harness.make(limits: limits)
        await h.server.setHookHandler { _, _ in
            // Ignores cancellation: blocks a thread for a while.
            blockThread(1.5)
            return HookReply(additionalContext: "late")
        }
        let (data, resp) = try await h.post(.preToolUse, try fixtureBodies()[0])
        #expect(resp.statusCode == 200 && data == Data("{}".utf8))
        await h.stop()
    }

    @Test func undecodableBodyGets200EmptyAndIsReportedOncePerSession() async throws {
        let log = Messages()
        let h = try await Harness.make(report: { log.add($0) })
        let seen = Seen()
        await h.server.setHookHandler { req, caller in await seen.add(req, caller); return HookReply() }
        for body in ["not json", #"{"hook_event_name":"Stop"}"#, #"{"hook_event_name":"PreToolUse"}"#] {
            let (data, resp) = try await h.post(.preToolUse, Data(body.utf8))
            #expect(resp.statusCode == 200 && data == Data("{}".utf8))
        }
        #expect(log.all.count == 1)
        #expect(await seen.requests.isEmpty)
        await h.stop()
    }

    @Test func realEditAndNotebookEditBodiesDecode() throws {
        let url = try #require(Bundle.module.url(forResource: "hook-edit", withExtension: "jsonl", subdirectory: "Fixtures"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
        let requests = try lines.map { try #require(HookRequest(body: $0)) }
        #expect(requests.count == 8)
        #expect(Set(requests.map(\.toolName)) == ["Edit", "NotebookEdit"])
        #expect(requests.filter { $0.event == .postToolUse }.allSatisfy { $0.toolResponse != nil })
        #expect(requests.filter { $0.event == .preToolUse }.allSatisfy { $0.toolResponse == nil })
        let edit = try #require(requests.first { $0.toolName == "Edit" })
        #expect(edit.toolInput["old_string"]?.stringValue == "beta" && edit.toolInput["file_path"]?.stringValue?.hasPrefix("/tmp/alloy-fixture") == true)
        let nb = try #require(requests.first { $0.toolName == "NotebookEdit" })
        #expect(nb.toolInput["notebook_path"]?.stringValue != nil && nb.toolInput["cell_id"]?.stringValue == "c1")
    }

    @Test func toolNameIsDecodedExactlyAsSent() throws {
        var obj = try #require(JSONValue.parse(try fixtureBodies()[0]))
        guard case .object(var o) = obj else { return }
        o["tool_name"] = .string("mcp__x__Edit")
        obj = .object(o)
        let req = try #require(HookRequest(body: try JSONEncoder().encode(obj)))
        #expect(req.toolName == "mcp__x__Edit")
    }

    @Test func settingsJSONHasNoPermissionsKey() throws {
        let url = URL(string: "http://127.0.0.1:52000/mcp")!
        let text = Hooks.settingsJSON(url: url, token: "tok123")
        let json = try #require(JSONValue.parse(Data(text.utf8)))
        guard case .object(let top) = json else { Issue.record("not an object"); return }
        #expect(Set(top.keys) == ["hooks"])
        #expect(!text.contains("permissions"))
        for (event, path) in [("PreToolUse", "/hooks/pre-tool-use"), ("PostToolUse", "/hooks/post-tool-use")] {
            guard case .array(let entries)? = json["hooks"]?[event], entries.count == 1 else { Issue.record("no \(event)"); continue }
            #expect(entries[0]["matcher"]?.stringValue == "Edit|MultiEdit|Write|NotebookEdit")
            guard case .array(let hooks)? = entries[0]["hooks"], hooks.count == 1 else { Issue.record("no hooks"); continue }
            #expect(hooks[0]["type"]?.stringValue == "http")
            #expect(hooks[0]["url"]?.stringValue == "http://127.0.0.1:52000\(path)")
            #expect(hooks[0]["headers"]?["Authorization"]?.stringValue == "Bearer tok123")
            #expect(hooks[0]["timeout"] == .number(3))
        }
    }
}
