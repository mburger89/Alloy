import Foundation
import Testing
@testable import AlloyCore

private struct SharedTool: MCPTool {
    let name = "notes_lookup"
    let description = "A built-in tool"
    let inputSchema: JSONValue = .object(["type": .string("object")])
    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult { MCPToolResult(text: "shared") }
}

private struct PluginStub: MCPTool {
    let name: String
    let owner: String
    let description = "A plugin tool"
    let inputSchema: JSONValue = .object(["type": .string("object")])
    var scope: MCPToolScope { .plugin(owner) }
    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult { MCPToolResult(text: "from \(owner)") }
}

private struct Client {
    let url: URL
    let token: String
    let session = URLSession(configuration: .ephemeral)

    func rpc(_ json: String) async throws -> JSONValue? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(json.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        return JSONValue.parse(data)
    }

    func names() async throws -> [String] {
        let list = try await rpc(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        return list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }.sorted() ?? []
    }

    func call(_ name: String) async throws -> JSONValue? {
        try await rpc(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"\#(name)"}}"#)
    }
}

@Suite(.serialized) struct PluginMCPScopeTests {
    private func make(scopes: Set<MCPToolScope>) async throws -> (LocalServer, Client, UUID) {
        let server = LocalServer(tools: [SharedTool()])
        await server.setPluginTools([PluginStub(name: "p_aaaaaa_one", owner: "a"), PluginStub(name: "p_bbbbbb_two", owner: "b")])
        let url = try await server.start()
        let session = UUID()
        let token = await server.token(for: session, scopes: scopes)
        return (server, Client(url: url, token: token), session)
    }

    @Test func pluginToolListedOnlyForItsScope() async throws {
        let (server, mine, _) = try await make(scopes: [.shared, .plugin("a")])
        #expect(try await mine.names() == ["notes_lookup", "p_aaaaaa_one"])
        let (other, theirs, _) = try await make(scopes: [.shared])
        #expect(try await theirs.names() == ["notes_lookup"])
        let refused = try await theirs.call("p_aaaaaa_one")
        #expect(refused?["error"]?["message"]?.stringValue?.contains("Unknown tool") == true)
        await server.stop()
        await other.stop()
    }

    @Test func removeScopeHidesToolFromLiveTokenAtOnce() async throws {
        let (server, client, _) = try await make(scopes: [.shared, .plugin("a")])
        #expect(try await client.call("p_aaaaaa_one")?["result"]?["isError"]?.boolValue == false)
        await server.removeScope(.plugin("a"))
        let after = try await client.call("p_aaaaaa_one")
        #expect(after?["error"]?["message"]?.stringValue?.contains("Unknown tool") == true)
        #expect(try await client.names() == ["notes_lookup"])
        await server.stop()
    }

    @Test func setPluginToolsKeepsBuiltInTools() async throws {
        let (server, client, _) = try await make(scopes: [.shared, .plugin("a"), .plugin("b")])
        await server.setPluginTools([PluginStub(name: "p_bbbbbb_two", owner: "b")])
        #expect(try await client.names() == ["notes_lookup", "p_bbbbbb_two"])
        await server.setPluginTools([PluginStub(name: "notes_lookup", owner: "a")])
        #expect(try await client.names() == ["notes_lookup"], "a plugin tool never replaces a built-in name")
        #expect(try await client.call("notes_lookup")?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "shared")
        await server.stop()
    }
}
