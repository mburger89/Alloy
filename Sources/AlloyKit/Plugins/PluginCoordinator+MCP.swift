import AlloyCore
import AlloyPlugins
import AlloyRPC
import Foundation

/// MCP tools from plugins: the list Alloy's MCP server serves is rebuilt from the effectively enabled plugins holding
/// `mcp.tools` when that set changes (enable, disable, grant change), never per call.
extension PluginCoordinator {
    static let mcpRowNote = "Sessions started before this was enabled see its tools after they restart."

    /// The scopes a session launched now holds: one per plugin currently offering tools.
    var pluginToolScopes: Set<MCPToolScope> { Set(appliedMCP.keys.map { .plugin($0) }) }

    /// Brings the workspace's server in line with `specs`. A plugin that no longer offers tools loses its scope on every
    /// live token before the new list is set.
    func applyMCPTools(_ specs: [String: [PluginMCPToolSpec]]) {
        guard specs != appliedMCP || mcpWorkspace != workspace.map(ObjectIdentifier.init) else { return }
        let removed = appliedMCP.keys.filter { specs[$0] == nil }.sorted()
        appliedMCP = specs
        mcpWorkspace = workspace.map(ObjectIdentifier.init)
        guard let workspace else { return }
        var tools: [any MCPTool] = []
        for id in specs.keys.sorted() {
            for spec in specs[id] ?? [] {
                tools.append(PluginMCPTool(pluginID: id, spec: spec) { [weak self] tool, arguments in
                    guard let self else { throw JSONRPCError(code: JSONRPCError.requestCancelled, message: "Cancelled") }
                    return try await self.callMCP(plugin: id, tool: tool, arguments: arguments)
                })
            }
        }
        let previous = mcpUpdate
        mcpUpdate = Task { @MainActor in
            await previous?.value
            for id in removed { await workspace.revokePluginScope(id) }
            await workspace.setPluginMCPTools(tools)
        }
    }

    /// Test seam: waits for the latest server update.
    func settleMCP() async { await mcpUpdate?.value }

    private func callMCP(plugin id: String, tool: String, arguments: JSONValue) async throws -> JSONValue {
        guard await activate(plugin: id, .mcpTool), let host else { throw JSONRPCError.connectionClosed }
        return try await host.request(id, "mcp/call", .object(["tool": .string(tool), "arguments": arguments]))
    }
}
