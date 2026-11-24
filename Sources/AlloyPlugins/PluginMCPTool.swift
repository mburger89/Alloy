import AlloyCore
import AlloyRPC
import Foundation

/// How plugin tools are named in Alloy's MCP server: `p_<short>_<tool>`, where `<short>` is a stable hash of the plugin
/// id, so two plugins cannot collide with each other or with Alloy's own tools.
public enum PluginToolNaming {
    /// The first 6 lowercase hex digits of the 64-bit FNV-1a hash of the id's UTF-8 bytes.
    public static func short(_ pluginID: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in pluginID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        return String((String(repeating: "0", count: 16 - hex.count) + hex).prefix(6))
    }

    public static func name(pluginID: String, tool: String) -> String { "p_\(short(pluginID))_\(tool)" }
}

/// A manifest-declared tool of a plugin, served to sessions holding `.plugin(id)`. A call sends `mcp/call` to the plugin
/// (the host starts it when needed and applies the request timeout).
public struct PluginMCPTool: MCPTool {
    public typealias Send = @Sendable (_ tool: String, _ arguments: JSONValue) async throws -> JSONValue

    public let pluginID: String
    public let tool: String
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    private let send: Send

    public var scope: MCPToolScope { .plugin(pluginID) }

    public init(pluginID: String, spec: PluginMCPToolSpec, send: @escaping Send) {
        self.pluginID = pluginID
        tool = spec.name
        name = PluginToolNaming.name(pluginID: pluginID, tool: spec.name)
        description = spec.description
        inputSchema = spec.inputSchema
        self.send = send
    }

    public func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        do {
            let answer = try await send(tool, arguments)
            return MCPToolResult(text: answer["text"]?.stringValue ?? "", isError: answer["isError"]?.boolValue ?? false)
        } catch let error as JSONRPCError {
            if error.code == JSONRPCError.timedOut.code { return MCPToolResult(text: "The plugin did not answer in time.", isError: true) }
            return MCPToolResult(text: "The plugin failed: \(error.message)", isError: true)
        } catch {
            return MCPToolResult(text: "The plugin failed: \(error.localizedDescription)", isError: true)
        }
    }
}
