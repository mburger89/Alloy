import Foundation

/// Who is calling a tool: the Alloy session whose token authenticated the request.
public struct MCPCaller: Sendable {
    public let sessionID: UUID
    public init(sessionID: UUID) { self.sessionID = sessionID }
}

public struct MCPToolResult: Sendable, Equatable {
    public let text: String
    public let isError: Bool
    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// One tool exposed to Claude sessions through the loopback MCP server.
public protocol MCPTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// A JSON Schema object; its `type` must be `"object"`.
    var inputSchema: JSONValue { get }
    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult
}

/// JSON-RPC handling for the MCP subset Alloy serves: initialize, ping, tools/list, tools/call.
public enum MCPServer {
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let latestVersion = "2025-11-25"
    /// What the spec says to assume when a request carries no `mcp-protocol-version` header.
    public static let defaultVersion = "2025-03-26"

    /// The `--mcp-config` JSON that points a Claude session at this server.
    public static func config(url: URL, token: String) -> String {
        func quoted(_ s: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            guard let data = try? encoder.encode(s), let out = String(data: data, encoding: .utf8) else { return "\"\"" }
            return out
        }
        return "{\"mcpServers\":{\"alloy\":{\"type\":\"http\",\"url\":\(quoted(url.absoluteString)),"
            + "\"headers\":{\"Authorization\":\(quoted("Bearer " + token))}}}}"
    }

    enum Reply: Sendable {
        /// Notifications and responses: HTTP 202, empty body.
        case accepted
        /// A JSON-RPC response object, HTTP 200.
        case json(Data)
    }

    /// Handles one parsed JSON-RPC message. `message` is nil when the body was not valid JSON.
    static func handle(_ message: JSONValue?, tools: [MCPTool], caller: MCPCaller) async -> Reply {
        guard let message else { return error(id: .null, code: -32700, "Parse error") }
        guard case .object = message else { return error(id: .null, code: -32600, "Invalid Request") }
        // No id: a notification (or a client response). Nothing to answer.
        guard let id = message["id"], id != .null else { return .accepted }
        guard let method = message["method"]?.stringValue else { return error(id: id, code: -32600, "Invalid Request") }
        guard message["jsonrpc"]?.stringValue == "2.0" else { return error(id: id, code: -32600, "Invalid Request") }
        let params = message["params"] ?? .object([:])

        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue
            let version = asked.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? latestVersion
            return result(id: id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("alloy"), "version": .string("1")]),
            ]))
        case "ping":
            return result(id: id, .object([:]))
        case "tools/list":
            let list = tools.map { tool -> JSONValue in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                ])
            }
            return result(id: id, .object(["tools": .array(list)]))
        case "tools/call":
            guard let name = params["name"]?.stringValue else { return error(id: id, code: -32602, "Missing tool name") }
            guard let tool = tools.first(where: { $0.name == name }) else {
                return error(id: id, code: -32602, "Unknown tool: \(name)")
            }
            let outcome: MCPToolResult
            switch checkedArguments(params["arguments"], for: tool) {
            case .refused(let refusal): outcome = refusal
            case .ok(let arguments): outcome = await tool.call(arguments, caller: caller)
            }
            return result(id: id, .object([
                "content": .array([.object(["type": .string("text"), "text": .string(outcome.text)])]),
                "isError": .bool(outcome.isError),
            ]))
        default:
            return error(id: id, code: -32601, "Method not found: \(method)")
        }
    }

    /// The arguments of a `tools/call`, or the tool result that tells the model what it got wrong: `arguments` must be
    /// an object, and (when the schema lists `properties`) may only use keys the schema names. A misspelled key would
    /// otherwise be ignored without a word. The refusal is a tool result, not a JSON-RPC error, so the model sees the
    /// text and retries.
    enum Checked { case ok(JSONValue), refused(MCPToolResult) }

    static func checkedArguments(_ raw: JSONValue?, for tool: MCPTool) -> Checked {
        let valid: [String]? = {
            guard case .object(let props)? = tool.inputSchema["properties"] else { return nil }
            let required = Set(tool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            return props.keys.sorted { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }
        }()
        guard let raw, raw != .null else { return .ok(.object([:])) }
        guard case .object(let given) = raw else {
            let list = valid?.joined(separator: ", ") ?? "named arguments"
            return .refused(MCPToolResult(text: "\(tool.name) takes an object with: \(list).", isError: true))
        }
        guard let valid else { return .ok(raw) }
        let unknown = given.keys.filter { !valid.contains($0) }.sorted()
        guard unknown.isEmpty else {
            let named = unknown.map { "\"\($0)\"" }.joined(separator: ", ")
            return .refused(MCPToolResult(
                text: "Unknown argument\(unknown.count == 1 ? "" : "s") \(named). \(tool.name) takes \(valid.joined(separator: ", ")).",
                isError: true))
        }
        return .ok(raw)
    }

    private static func result(id: JSONValue, _ value: JSONValue) -> Reply {
        encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": value]))
    }

    private static func error(id: JSONValue, code: Int, _ message: String) -> Reply {
        encode(.object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ]))
    }

    private static func encode(_ value: JSONValue) -> Reply {
        .json((try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }
}
