import Foundation
import Network
import Testing
@testable import AlloyCore

private struct EchoTool: MCPTool {
    let name = "echo"
    let description = "Echoes text and the caller session"
    let inputSchema: JSONValue = .object(["type": .string("object")])
    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        MCPToolResult(text: "echo:\(arguments["text"]?.stringValue ?? "") session:\(caller.sessionID.uuidString)")
    }
}

private struct ThemeEchoTool: MCPTool {
    let name = "theme_echo"
    let description = "A theme-scoped tool"
    let inputSchema: JSONValue = .object(["type": .string("object")])
    var scope: MCPToolScope { .theme }
    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        MCPToolResult(text: "theme")
    }
}

private struct Harness {
    let server: LocalServer
    let url: URL
    let session: UUID
    let token: String
    let urlSession: URLSession

    static func make(tools: [MCPTool] = [EchoTool()], scopes: Set<MCPToolScope> = [.shared]) async throws -> Harness {
        let server = LocalServer(tools: tools)
        let url = try await server.start()
        let session = UUID()
        let token = await server.token(for: session, scopes: scopes)
        return Harness(server: server, url: url, session: session, token: token,
                       urlSession: URLSession(configuration: .ephemeral))
    }

    func stop() async {
        urlSession.invalidateAndCancel()
        await server.stop()
    }

    func post(_ body: Data, token: String? = nil, headers: [String: String] = [:], useToken: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if useToken { req.setValue("Bearer \(token ?? self.token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await urlSession.data(for: req)
        return (data, resp as! HTTPURLResponse)
    }

    func rpc(_ json: String, headers: [String: String] = [:]) async throws -> (JSONValue?, HTTPURLResponse) {
        let (data, resp) = try await post(Data(json.utf8), headers: headers)
        return (JSONValue.parse(data), resp)
    }
}

/// A raw TCP client for cases URLSession cannot express: header control, pipelining, idle and dribbled connections.
private final class RawClient: @unchecked Sendable {
    let conn: NWConnection
    private var buffer = Data()
    init(port: Int) {
        conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        conn.start(queue: .global())
    }
    deinit { conn.cancel() }
    func send(_ text: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in cont.resume() })
        }
    }
    private func more() async -> Bool {
        let chunk: Data? = await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, _, _ in cont.resume(returning: d) }
        }
        guard let chunk, !chunk.isEmpty else { return false }
        buffer.append(chunk)
        return true
    }
    /// One full response (head plus Content-Length body), or nil when the connection closed first.
    func readResponse() async -> String? {
        let sep = Data("\r\n\r\n".utf8)
        while buffer.range(of: sep) == nil { guard await more() else { return nil } }
        let r = buffer.range(of: sep)!
        let head = String(decoding: buffer[0..<r.lowerBound], as: UTF8.self)
        var length = 0
        for line in head.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        while buffer.count < r.upperBound + length { guard await more() else { return nil } }
        let out = String(decoding: buffer[0..<(r.upperBound + length)], as: UTF8.self)
        buffer = Data(buffer[(r.upperBound + length)...])
        return out
    }
    /// True once the server has closed the connection (blocks until then).
    func waitsForClose() async -> Bool {
        while await more() {}
        return true
    }
}

/// Connects and reports whether the TCP handshake completed.
private func canConnect(host: String, port: Int) async -> Bool {
    let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
    defer { conn.cancel() }
    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        let once = OnceFlag()
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: if once.take() { cont.resume(returning: true) }
            case .failed, .waiting, .cancelled: if once.take() { cont.resume(returning: false) }
            default: break
            }
        }
        conn.start(queue: .global())
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

private func nonLoopbackIPv4Address() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let f = p.pointee
        guard let sa = f.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              Int32(f.ifa_flags) & IFF_UP != 0, Int32(f.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let s = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !s.hasPrefix("169.254.") { return s }
        }
    }
    return nil
}

private let pingBody = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#

private func rawPost(port: Int, token: String, body: String = pingBody, extra: String = "", host: String? = nil) -> String {
    "POST /mcp HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\nAuthorization: Bearer \(token)\r\n\(extra)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
}

@Suite(.timeLimit(.minutes(1))) struct MCPServerTests {
    @Test func initializeEchoesSupportedVersion() async throws {
        let h = try await Harness.make()
        let (a, ra) = try await h.rpc(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        #expect(ra.statusCode == 200)
        #expect(ra.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(ra.value(forHTTPHeaderField: "Mcp-Session-Id") == nil)
        #expect(a?["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(a?["result"]?["capabilities"]?["tools"] != nil)
        #expect(a?["id"]?.intValue == 0)
        let (b, _) = try await h.rpc(#"{"jsonrpc":"2.0","id":"x","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        #expect(b?["result"]?["protocolVersion"]?.stringValue == "2025-11-25")
        #expect(b?["id"]?.stringValue == "x")
        await h.stop()
    }

    @Test func toolsListAndCallRoundTrip() async throws {
        let h = try await Harness.make()
        let (list, _) = try await h.rpc(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, headers: ["mcp-protocol-version": "2025-11-25"])
        let tools = list?["result"]?["tools"]?.arrayValue ?? []
        #expect(tools.count == 1)
        #expect(tools.first?["name"]?.stringValue == "echo")
        #expect(tools.first?["inputSchema"]?["type"]?.stringValue == "object")
        let (call, _) = try await h.rpc(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        #expect(call?["result"]?["isError"]?.boolValue == false)
        let text = call?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        #expect(text == "echo:hi session:\(h.session.uuidString)")
        let (bad, rb) = try await h.rpc(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope"}}"#)
        #expect(rb.statusCode == 200)
        #expect(bad?["error"]?["code"]?.intValue == -32602)
        let (ping, _) = try await h.rpc(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)
        #expect(ping?["result"] == .object([:]))
        await h.stop()
    }

    @Test func readOnlyToolsAreAnnotatedInTheList() async throws {
        struct ReadTool: MCPTool {
            let name = "peek"
            let description = "reads"
            let inputSchema: JSONValue = .object(["type": .string("object")])
            var readOnly: Bool { true }
            func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult { MCPToolResult(text: "") }
        }
        let h = try await Harness.make(tools: [EchoTool(), ReadTool()])
        let (list, _) = try await h.rpc(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, headers: ["mcp-protocol-version": "2025-11-25"])
        let tools = list?["result"]?["tools"]?.arrayValue ?? []
        #expect(tools.first { $0["name"]?.stringValue == "peek" }?["annotations"]?["readOnlyHint"]?.boolValue == true)
        #expect(tools.first { $0["name"]?.stringValue == "echo" }?["annotations"] == nil)
    }

    @Test @MainActor func alloysReadOnlyToolsDeclareIt() {
        let e = Env(); defer { e.cleanup() }
        let all = NotesTools.make(workspace: e.ws) + CoordinationTools.make(workspace: e.ws)
        let readOnly = Set(all.filter(\.readOnly).map(\.name))
        #expect(readOnly == ["notes_lookup", "notes_read", "sessions_changes"])
    }

    private func listedNames(_ h: Harness, token: String? = nil) async throws -> [String] {
        let (data, _) = try await h.post(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8), token: token)
        let list = JSONValue.parse(data)
        return (list?["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
    }

    private func callTheme(_ h: Harness, token: String? = nil) async throws -> JSONValue? {
        let (data, _) = try await h.post(
            Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"theme_echo"}}"#.utf8), token: token)
        return JSONValue.parse(data)
    }

    @Test func toolsOutsideTheCallersScopeAreInvisible() async throws {
        let tools: [MCPTool] = [EchoTool(), ThemeEchoTool()]
        let shared = try await Harness.make(tools: tools, scopes: [.shared])
        #expect(try await listedNames(shared) == ["echo"])
        let hidden = try await callTheme(shared)
        #expect(hidden?["error"]?["code"]?.intValue == -32602)
        #expect(hidden?["error"]?["message"]?.stringValue == "Unknown tool: theme_echo")
        await shared.stop()

        let both = try await Harness.make(tools: tools, scopes: [.shared, .theme])
        #expect(Set(try await listedNames(both)) == ["echo", "theme_echo"])
        let ok = try await callTheme(both)
        #expect(ok?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "theme")
        await both.stop()

        let themeOnly = try await Harness.make(tools: tools, scopes: [.theme])
        #expect(try await listedNames(themeOnly) == ["theme_echo"])
        await themeOnly.stop()
    }

    @Test func scopesFollowTheLatestTokenCall() async throws {
        let h = try await Harness.make(tools: [EchoTool(), ThemeEchoTool()], scopes: [.shared])
        let again = await h.server.token(for: h.session, scopes: [.theme])
        #expect(again == h.token)
        #expect(try await listedNames(h) == ["theme_echo"])
        await h.stop()
    }

    @Test func revokeDropsScopes() async throws {
        let h = try await Harness.make(tools: [EchoTool(), ThemeEchoTool()], scopes: [.theme])
        await h.server.revoke(session: h.session)
        let fresh = await h.server.token(for: h.session)
        #expect(try await listedNames(h, token: fresh) == ["echo"])
        await h.stop()
    }

    @Test func notificationsGet202() async throws {
        let h = try await Harness.make()
        let (data, resp) = try await h.post(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(resp.statusCode == 202)
        #expect(data.isEmpty)
        await h.stop()
    }

    @Test func unknownMethodIsMethodNotFound() async throws {
        let h = try await Harness.make()
        let (a, ra) = try await h.rpc(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
        #expect(ra.statusCode == 200)
        #expect(a?["error"]?["code"]?.intValue == -32601)
        // The CLI's newer-spec probe carries an unsupported protocol header and must still get -32601.
        let (b, rb) = try await h.rpc(#"{"jsonrpc":"2.0","id":"d","method":"server/discover"}"#, headers: ["mcp-protocol-version": "2026-07-28"])
        #expect(rb.statusCode == 200)
        #expect(b?["error"]?["code"]?.intValue == -32601)
        await h.stop()
    }

    @Test func unsupportedProtocolHeaderIs400() async throws {
        let h = try await Harness.make()
        let (_, resp) = try await h.post(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8), headers: ["mcp-protocol-version": "2024-01-01"])
        #expect(resp.statusCode == 400)
        await h.stop()
    }

    @Test func getAndDeleteAre405() async throws {
        let h = try await Harness.make()
        for method in ["GET", "DELETE"] {
            var req = URLRequest(url: h.url)
            req.httpMethod = method
            req.setValue("Bearer \(h.token)", forHTTPHeaderField: "Authorization")
            let (_, resp) = try await h.urlSession.data(for: req)
            #expect((resp as! HTTPURLResponse).statusCode == 405)
        }
        await h.stop()
    }

    @Test func serverRejectsUnauthenticatedAndForeignOrigin() async throws {
        let h = try await Harness.make()
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let (_, none) = try await h.post(body, useToken: false)
        #expect(none.statusCode == 401)
        let (_, wrong) = try await h.post(body, token: String(repeating: "0", count: 64))
        #expect(wrong.statusCode == 401)
        let (_, evil) = try await h.post(body, headers: ["Origin": "https://evil.example"])
        #expect(evil.statusCode == 403)

        let (_, sameHostNewPort) = try await h.post(body, headers: ["Origin": "http://127.0.0.1:1"])
        #expect(sameHostNewPort.statusCode == 403)
        let (_, httpsOrigin) = try await h.post(body, headers: ["Origin": "https://127.0.0.1:\(h.url.port!)"])
        #expect(httpsOrigin.statusCode == 403)
        let (_, sameOrigin) = try await h.post(body, headers: ["Origin": "http://localhost:\(h.url.port!)"])
        #expect(sameOrigin.statusCode == 200)

        let port = h.url.port!
        let foreign = RawClient(port: port)
        await foreign.send(rawPost(port: port, token: h.token, host: "example.com"))
        #expect(await foreign.readResponse()?.hasPrefix("HTTP/1.1 403") == true)
        let local = RawClient(port: port)
        await local.send(rawPost(port: port, token: h.token, host: "localhost:\(port)"))
        #expect(await local.readResponse()?.hasPrefix("HTTP/1.1 200") == true)
        await h.stop()
    }

    @Test func chunkedBodyIs411() async throws {
        let h = try await Harness.make()
        let port = h.url.port!
        let c = RawClient(port: port)
        await c.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(h.token)\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
        #expect(await c.readResponse()?.hasPrefix("HTTP/1.1 411") == true)
        await h.stop()
    }

    @Test func missingContentLengthIs411() async throws {
        let h = try await Harness.make()
        let port = h.url.port!
        let c = RawClient(port: port)
        await c.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(h.token)\r\n\r\n")
        #expect(await c.readResponse()?.hasPrefix("HTTP/1.1 411") == true)
        await h.stop()
    }

    @Test func oversizedHeadIs400() async throws {
        let h = try await Harness.make()
        let port = h.url.port!
        let c = RawClient(port: port)
        await c.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-Pad: \(String(repeating: "a", count: 20_000))\r\n\r\n")
        #expect(await c.readResponse()?.hasPrefix("HTTP/1.1 400") == true)
        await h.stop()
    }

    @Test func malformedFramingIs400() async throws {
        let h = try await Harness.make()
        let port = h.url.port!
        let base = "POST /mcp HTTP/1.1\r\nAuthorization: Bearer \(h.token)\r\n"
        let cases = [
            base + "Host: 127.0.0.1:\(port)\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 0\r\n\r\n",
            base + "Host: 127.0.0.1:\(port)\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}",
            base + "Host: 127.0.0.1:\(port)\r\nContent-Length: -1\r\n\r\n",
            base + "Host: 127.0.0.1:\(port)\r\nContent-Length: +2\r\n\r\n{}",
        ]
        for text in cases {
            let c = RawClient(port: port)
            await c.send(text)
            #expect(await c.readResponse()?.hasPrefix("HTTP/1.1 400") == true)
        }
        await h.stop()
    }

    @Test func tokenWithExtraBytesIs401() async throws {
        let h = try await Harness.make()
        let body = Data(pingBody.utf8)
        // 256 extra bytes used to wrap the length XOR to zero.
        let (_, resp) = try await h.post(body, token: h.token + String(repeating: "0", count: 256))
        #expect(resp.statusCode == 401)
        let (_, ok) = try await h.post(body)
        #expect(ok.statusCode == 200)
        await h.stop()
    }

    @Test func pipelinedRequestsInOneWriteBothAnswered() async throws {
        let h = try await Harness.make()
        let port = h.url.port!
        let c = RawClient(port: port)
        let one = rawPost(port: port, token: h.token)
        await c.send(one + one)
        #expect(await c.readResponse()?.hasPrefix("HTTP/1.1 200") == true)
        #expect(await c.readResponse()?.hasPrefix("HTTP/1.1 200") == true)
        await h.stop()
    }

    @Test func revocationAppliesOnReusedConnection() async throws {
        let h = try await Harness.make()
        let port = h.url.port!
        let c = RawClient(port: port)
        await c.send(rawPost(port: port, token: h.token))
        #expect(await c.readResponse()?.hasPrefix("HTTP/1.1 200") == true)
        await h.server.revoke(session: h.session)
        await c.send(rawPost(port: port, token: h.token))
        #expect(await c.readResponse()?.hasPrefix("HTTP/1.1 401") == true)
        await h.stop()
    }

    @Test func http10WithoutKeepAliveClosesAfterResponse() async throws {
        let h = try await Harness.make()
        let port = h.url.port!
        let c = RawClient(port: port)
        await c.send(rawPost(port: port, token: h.token).replacingOccurrences(of: "HTTP/1.1", with: "HTTP/1.0"))
        #expect(await c.readResponse()?.contains(" 200 ") == true)
        #expect(await c.waitsForClose())
        await h.stop()
    }

    @Test func stopClosesOpenKeepAliveConnection() async throws {
        let h = try await Harness.make()
        let port = h.url.port!
        let c = RawClient(port: port)
        await c.send(rawPost(port: port, token: h.token))
        #expect(await c.readResponse()?.hasPrefix("HTTP/1.1 200") == true)
        await h.server.stop()
        #expect(await c.waitsForClose())
        #expect(await h.server.openConnectionCount == 0)
        h.urlSession.invalidateAndCancel()
    }

    @Test func jsonRpcVersionMustBe2() async throws {
        let h = try await Harness.make()
        let (a, _) = try await h.rpc(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#)
        #expect(a?["error"]?["code"]?.intValue == -32600)
        let (b, _) = try await h.rpc(#"{"id":1,"method":"ping"}"#)
        #expect(b?["error"]?["code"]?.intValue == -32600)
        await h.stop()
    }

    @Test func acceptsOldestSupportedVersion() async throws {
        let h = try await Harness.make()
        let (a, _) = try await h.rpc(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        #expect(a?["result"]?["protocolVersion"]?.stringValue == "2024-11-05")
        await h.stop()
    }

    @Test func bodyOverCapIs413() async throws {
        let h = try await Harness.make()
        let big = Data(repeating: UInt8(ascii: "a"), count: LocalServer.maxBodyBytes + 1024)
        let (_, resp) = try await h.post(big)
        #expect(resp.statusCode == 413)
        // The server is still healthy afterwards.
        let (_, ok) = try await h.rpc(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(ok.statusCode == 200)
        await h.stop()
    }

    @Test func revokedTokenIs401() async throws {
        let h = try await Harness.make()
        let (_, before) = try await h.rpc(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(before.statusCode == 200)
        await h.server.revoke(session: h.session)
        let (_, after) = try await h.post(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
        #expect(after.statusCode == 401)
        await h.stop()
    }

    @Test func tokensAreRandomHexPerSession() async throws {
        let server = LocalServer(tools: [])
        let a = await server.token(for: UUID())
        let b = await server.token(for: UUID())
        #expect(a.count == 64 && b.count == 64)
        #expect(a != b)
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    @Test func listensOnLoopbackOnly() async throws {
        let h = try await Harness.make()
        #expect(h.url.host == "127.0.0.1")
        #expect(h.url.path == "/mcp")
        let port = h.url.port!
        #expect(port > 0)
        let endpoint = await h.server.listenerEndpoint
        guard case .hostPort(let host, let boundPort)? = endpoint else {
            Issue.record("listener has no bound endpoint"); await h.stop(); return
        }
        #expect(host == .ipv4(.loopback))
        #expect(Int(boundPort.rawValue) == port)
        #expect(await canConnect(host: "127.0.0.1", port: port))
        if let other = nonLoopbackIPv4Address() {
            #expect(await canConnect(host: other, port: port) == false)
        }
        #expect(MCPServer.config(url: h.url, token: "abc") ==
            #"{"mcpServers":{"alloy":{"type":"http","url":"\#(h.url.absoluteString)","headers":{"Authorization":"Bearer abc"}}}}"#)
        await h.stop()
    }

    // MARK: Resource limits

    private static func fastLimits(maxConnections: Int = 48) -> LocalServer.Limits {
        var l = LocalServer.Limits()
        l.maxConnections = maxConnections
        l.requestDeadline = 0.4
        l.idleTimeout = 0.4
        l.drainDeadline = 0.4
        return l
    }

    /// Polls `condition` for up to `timeout` seconds; false if it never held.
    private func eventually(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private static func started(_ limits: LocalServer.Limits) async throws -> (LocalServer, URL, String) {
        let server = LocalServer(tools: [EchoTool()], limits: limits)
        let url = try await server.start()
        return (server, url, await server.token(for: UUID()))
    }

    @Test func connectionsOverTheCapAreClosed() async throws {
        // Long deadlines so only the cap can close the extra connection.
        var limits = Self.fastLimits(maxConnections: 3)
        limits.requestDeadline = 30
        let (capped, cappedURL, _) = try await Self.started(limits)
        let cport = cappedURL.port!
        let idle = (0..<3).map { _ in RawClient(port: cport) }
        // Bounded: a regression fails here instead of hanging the suite.
        #expect(await eventually { await capped.openConnectionCount >= 3 })
        let extra = RawClient(port: cport)
        #expect(await extra.waitsForClose())
        #expect(await capped.openConnectionCount == 3)
        withExtendedLifetime(idle) {}
        await capped.stop()
    }

    @Test func dribbledHeadIsClosedAtDeadline() async throws {
        let (server, url, _) = try await Self.started(Self.fastLimits())
        let c = RawClient(port: url.port!)
        await c.send("POST /mcp HTTP/1.1\r\nHo")
        #expect(await c.waitsForClose())
        await server.stop()
    }

    @Test func silentNewConnectionIsClosedAtDeadline() async throws {
        let (server, url, _) = try await Self.started(Self.fastLimits())
        let c = RawClient(port: url.port!)
        #expect(await c.waitsForClose())
        await server.stop()
    }

    @Test func idleKeepAliveConnectionIsClosed() async throws {
        // A full request is sent, so its deadline must not be the thing under test (or flake under load); the idle
        // timeout is.
        var limits = Self.fastLimits()
        limits.requestDeadline = 5
        let (server, url, token) = try await Self.started(limits)
        let port = url.port!
        let c = RawClient(port: port)
        await c.send(rawPost(port: port, token: token))
        #expect(await c.readResponse()?.hasPrefix("HTTP/1.1 200") == true)
        #expect(await c.waitsForClose())
        await server.stop()
    }

    @Test func drainWithHugeContentLengthEndsAtDeadline() async throws {
        let (server, url, _) = try await Self.started(Self.fastLimits())
        let port = url.port!
        let c = RawClient(port: port)
        await c.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 4000000\r\n\r\n")
        #expect(await c.readResponse()?.hasPrefix("HTTP/1.1 401") == true)
        #expect(await c.waitsForClose())
        await server.stop()
    }

    @Test func stopClosesListenerAndConnections() async throws {
        let h = try await Harness.make()
        let (_, ok) = try await h.rpc(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(ok.statusCode == 200)
        await h.stop()
        var req = URLRequest(url: h.url)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        let fresh = URLSession(configuration: .ephemeral)
        defer { fresh.invalidateAndCancel() }
        await #expect(throws: (any Error).self) { _ = try await fresh.data(for: req) }
    }
}
