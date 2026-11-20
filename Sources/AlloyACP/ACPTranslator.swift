import AlloyCore
import Foundation

/// ACP v1 to Alloy's wire model. Pure apart from reading files (injected) for the whole-file attribution of edits.
/// One translator per ACP session; it keeps the open text block and the table of tool calls.
public struct ACPTranslator: Sendable {
    public var projectRoot: URL
    /// The current text of a file, nil when it is missing or unreadable. Called for edit tool calls only, and only for
    /// paths inside the project.
    public var readFile: @Sendable (String) -> String?
    /// True while `session/load` replays history: user chunks become replayed user echoes.
    public var isReplaying = false

    private enum OpenBlock { case text, thinking }
    private struct Diff { var path: String; var oldText: String?; var newText: String }
    private struct Tool {
        var id: String
        var title: String
        var kind: String
        var input: JSONValue = .null
        var locations: [String] = []
        var diffs: [Diff] = []
        var text = ""
        var rawOutput: JSONValue?
        var before: [String: String?] = [:]
        var blockEmitted = false
        var finished = false
    }

    private var open: OpenBlock?
    private var openMessageID: String?
    private var tools: [String: Tool] = [:]
    private var toolOrder: [String] = []
    private var planCount = 0
    private var lastModes: [AgentChoice]?
    private var lastModels: [AgentChoice]?
    private var lastModeID: String?
    private var lastModelID: String?
    private var availableModes: [AgentChoice] = []
    private var availableModels: [AgentChoice] = []

    public init(projectRoot: URL, readFile: @escaping @Sendable (String) -> String? = ACPTranslator.readFromDisk) {
        self.projectRoot = projectRoot
        self.readFile = readFile
    }

    public static let readFromDisk: @Sendable (String) -> String? = { path in
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.size] as? Int ?? 0) <= 4_000_000,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: updates

    public mutating func translate(_ update: ACPSessionUpdate) -> [InboundMessage] {
        switch update {
        case .agentMessageChunk(let chunk): return message(chunk, thinking: false)
        case .agentThoughtChunk(let chunk): return message(chunk, thinking: true)
        case .userMessageChunk(let chunk):
            guard isReplaying else { return [] }
            open = nil; openMessageID = nil
            switch chunk.content {
            case .text(let t): return [.userEcho(text: t, imageCount: 0, uuid: nil, isReplay: true)]
            case .image: return [.userEcho(text: "", imageCount: 1, uuid: nil, isReplay: true)]
            default: return []
            }
        case .toolCall(let call): return tool(call)
        case .toolCallUpdate(let call): return tool(call)
        case .plan(let entries): return plan(entries)
        case .availableCommands(let commands):
            return [.commandsChanged(commands.map {
                SlashCommandInfo(name: $0.name, description: $0.description ?? "", argumentHint: $0.inputHint)
            })]
        case .currentMode(let id):
            guard !id.isEmpty else { return [] }
            lastModeID = id
            return [.statusChanged(permissionMode: id), .agentState(.modes(current: id, available: availableModes))]
        case .configOptions(let options): return state(modes: nil, models: nil, options: options)
        case .usage(let u):
            return [.agentState(.usage(SessionUsage(used: u.used, size: u.size, cost: u.cost?.amount, currency: u.cost?.currency)))]
        case .sessionInfo: return []
        case .compaction(let v):
            func count(_ keys: [String]) -> Int? { keys.lazy.compactMap { v[$0]?.intValue }.first }
            open = nil; openMessageID = nil
            return [.compactBoundary(preTokens: count(["preTokens", "pre_tokens", "tokensBefore", "before"]),
                                     postTokens: count(["postTokens", "post_tokens", "tokensAfter", "after"]))]
        case .notice(let n):
            guard let text = n.message, !text.isEmpty else { return [] }
            let kind: NoticeKind = n.level == "error" ? .error : n.level == "warning" || n.level == "warn" ? .warning : .commandOutput
            return [.notice(kind: kind, text: text)]
        case .unknown: return []
        }
    }

    private mutating func message(_ chunk: ACPMessageChunk, thinking: Bool) -> [InboundMessage] {
        guard let text = chunk.content.textValue, !text.isEmpty else { return [] }
        var out: [InboundMessage] = []
        let want: OpenBlock = thinking ? .thinking : .text
        let sameMessage = chunk.messageId == nil || openMessageID == nil || chunk.messageId == openMessageID
        if open != want || !sameMessage {
            out.append(.delta(.blockStart(index: 0, kind: thinking ? "thinking" : "text")))
            open = want
            openMessageID = chunk.messageId
        } else if openMessageID == nil {
            openMessageID = chunk.messageId
        }
        out.append(.delta(thinking ? .thinking(index: 0, text, estimatedTokens: nil) : .text(index: 0, text)))
        return out
    }

    // MARK: tool calls

    private func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : projectRoot.appendingPathComponent(path).path
    }

    private func isInsideProject(_ path: String) -> Bool {
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return p == root || p.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func snapshot(_ path: String) -> String? {
        isInsideProject(path) ? readFile(path) : nil
    }

    private static func pathInInput(_ input: JSONValue?) -> String? {
        for key in ["path", "filePath", "file_path", "filepath"] {
            if let p = input?[key]?.stringValue, !p.isEmpty { return p }
        }
        return nil
    }

    private static func contentText(_ blocks: [ACPToolContent]) -> String {
        blocks.compactMap { if case .content(.text(let t)) = $0 { t } else { nil } }.joined(separator: "\n")
    }

    private func summary(for t: Tool) -> String {
        let path = t.locations.first ?? t.diffs.first?.path ?? Self.pathInInput(t.input["rawInput"])
        switch t.kind {
        case "read", "edit", "delete", "move":
            if let path { return ToolSummary.relativePath(absolute(path), root: projectRoot) }
        case "execute":
            if let c = t.input["rawInput"]?["command"]?.stringValue, !c.isEmpty { return String(c.prefix(120)) }
        default: break
        }
        return t.title
    }

    private func blockInput(for t: Tool) -> JSONValue {
        var o: [String: JSONValue] = ["acpKind": .string(t.kind), "acpSummary": .string(summary(for: t)), "title": .string(t.title)]
        if let p = t.locations.first ?? Self.pathInInput(t.input["rawInput"]) { o["path"] = .string(p) }
        if let raw = t.input["rawInput"] { o["rawInput"] = raw }
        return .object(o)
    }

    /// Merges a `tool_call` or `tool_call_update` into the table; emits the block the first time, the result when the
    /// call completes or fails.
    private mutating func tool(_ call: ACPToolCall) -> [InboundMessage] {
        open = nil; openMessageID = nil
        var t = tools[call.toolCallId] ?? Tool(id: call.toolCallId, title: call.title ?? "Tool", kind: call.kind ?? "other")
        if tools[call.toolCallId] == nil { toolOrder.append(call.toolCallId) }
        if let title = call.title, !title.isEmpty { t.title = title }
        if let kind = call.kind { t.kind = kind }
        var input = t.input.objectValue ?? [:]
        if let raw = call.rawInput, raw != .null, raw != .object([:]) { input["rawInput"] = raw }
        t.input = .object(input)
        for loc in call.locations ?? [] where !t.locations.contains(loc.path) { t.locations.append(loc.path) }
        if let rawOutput = call.rawOutput, rawOutput != .null { t.rawOutput = rawOutput }
        if let content = call.content {
            for c in content {
                if case .diff(let path, let old, let new) = c {
                    t.diffs.removeAll { $0.path == path }
                    t.diffs.append(Diff(path: path, oldText: old, newText: new))
                }
            }
            let text = Self.contentText(content)
            if !text.isEmpty { t.text = text }
        }
        // File changes are attributed by comparing the file before and after: remember it as early as the path is known.
        if ["edit", "delete", "move"].contains(t.kind) {
            let paths = t.diffs.map(\.path) + t.locations + [Self.pathInInput(t.input["rawInput"])].compactMap { $0 }
            for p in paths where t.before[absolute(p)] == nil { t.before[absolute(p)] = .some(snapshot(absolute(p))) }
        }
        var out: [InboundMessage] = []
        if !t.blockEmitted {
            t.blockEmitted = true
            out.append(.assistantBlock(messageID: "acp-tool-\(t.id)",
                                       block: .toolUse(id: t.id, name: t.title, input: blockInput(for: t))))
        }
        let status = call.status ?? ""
        if (status == "completed" || status == "failed"), !t.finished {
            t.finished = true
            out += results(for: t, failed: status == "failed")
        }
        tools[t.id] = t
        trimTools()
        return out
    }

    private mutating func trimTools() {
        guard toolOrder.count > 600 else { return }
        for id in toolOrder.prefix(200) where tools[id]?.finished == true { tools[id] = nil }
        toolOrder.removeAll { tools[$0] == nil }
    }

    private func results(for t: Tool, failed: Bool) -> [InboundMessage] {
        var text = t.text
        if text.isEmpty, let s = t.rawOutput?.stringValue { text = s }
        let raw: JSONValue = .object(["acp": .object([
            "kind": .string(t.kind), "title": .string(t.title),
            "locations": .array(t.locations.map { .string($0) }),
        ])])
        var changes: [ToolUseResult] = []
        if !failed { changes = fileChanges(for: t) }
        var out: [InboundMessage] = []
        out.append(.toolResult(ToolResultMessage(toolUseID: t.id, isError: failed, text: text,
                                                 result: changes.first ?? .none, raw: raw)))
        for extra in changes.dropFirst() {
            out.append(.toolResult(ToolResultMessage(toolUseID: t.id, isError: false, text: text, result: extra, raw: raw)))
        }
        return out
    }

    /// Whole-file results for the files an edit call changed. Agents send snippets or nothing at all, so the
    /// before/after text comes from the file as it was when the call was first seen and as it is now.
    private func fileChanges(for t: Tool) -> [ToolUseResult] {
        guard ["edit", "delete", "move"].contains(t.kind) || !t.diffs.isEmpty else { return [] }
        var paths: [String] = []
        for p in t.diffs.map(\.path) + t.locations + [Self.pathInInput(t.input["rawInput"])].compactMap({ $0 }) {
            let a = absolute(p)
            if !paths.contains(a) { paths.append(a) }
        }
        var results: [ToolUseResult] = []
        for path in paths where isInsideProject(path) {
            let before: String? = t.before[path] ?? nil
            let after = readFile(path)
            let diff = t.diffs.last { absolute($0.path) == path }
            if let result = Self.change(path: path, before: before, after: after, diff: diff.map { ($0.oldText, $0.newText) }) {
                results.append(result)
            }
        }
        return results
    }

    static func change(path: String, before: String?, after: String?, diff: (old: String?, new: String)?) -> ToolUseResult? {
        if let diff {
            // A creation, or a whole-file replacement: the new text is the file.
            if diff.old == nil {
                let content = after ?? diff.new
                if let before, before == content { return nil }
                return .write(filePath: path, isCreate: before == nil, content: content, originalFile: before, hunks: [])
            }
            let old = diff.old ?? ""
            if let before, let after, before != after {
                return .write(filePath: path, isCreate: false, content: after, originalFile: before, hunks: [])
            }
            if before == nil, let after {
                // The file did not exist when the call began: a creation that sent its text as a diff.
                return .write(filePath: path, isCreate: true, content: after, originalFile: nil, hunks: [])
            }
            // The disk shows no change against the snapshot (the snapshot was taken after the write, or the file was
            // unreadable): rebuild the other side from the snippet.
            guard let disk = after ?? before else { return nil }
            if !diff.new.isEmpty, let range = disk.range(of: diff.new) {
                let original = disk.replacingCharacters(in: range, with: old)
                if original == disk { return nil }
                return .write(filePath: path, isCreate: false, content: disk, originalFile: original, hunks: [])
            }
            if !old.isEmpty, let range = disk.range(of: old) {
                return .write(filePath: path, isCreate: false, content: disk.replacingCharacters(in: range, with: diff.new),
                              originalFile: disk, hunks: [])
            }
            return nil
        }
        guard let after else { return nil }
        if before == after { return nil }
        return .write(filePath: path, isCreate: before == nil, content: after, originalFile: before, hunks: [])
    }

    /// Registers the tool call a permission request names (the agent may ask before it announced the call) and returns
    /// what the permission card needs.
    public mutating func permissionTool(_ call: ACPToolCall) -> (messages: [InboundMessage], name: String, input: JSONValue) {
        var probe = call
        probe.status = nil
        let messages = tool(probe)
        let t = tools[call.toolCallId]
        return (messages, t?.title ?? call.title ?? "Tool", t.map(blockInput) ?? .null)
    }

    // MARK: plan

    private mutating func plan(_ entries: [ACPPlanEntry]) -> [InboundMessage] {
        open = nil; openMessageID = nil
        planCount += 1
        let id = "acp-plan-\(planCount)"
        let todos: [JSONValue] = entries.map { e in
            let status = e.status == "completed" ? "completed" : e.status == "in_progress" ? "in_progress" : "pending"
            return .object(["content": .string(e.content), "status": .string(status), "activeForm": .string(e.content)])
        }
        return [
            .assistantBlock(messageID: id, block: .toolUse(id: id, name: "TodoWrite", input: .object(["todos": .array(todos)]))),
            .toolResult(ToolResultMessage(toolUseID: id, isError: false, text: "", result: .none)),
        ]
    }

    // MARK: modes, models

    /// Modes and models from a `session/new`, `session/load`, `session/resume` or `set_config_option` result, or from
    /// a `config_option_update`. A `mode` / `model` config option wins over the older `modes` / `models` state.
    public mutating func state(modes: ACPModes?, models: ACPModelState?, options: [ACPConfigOption]?) -> [InboundMessage] {
        var out: [InboundMessage] = []
        var modeList: [AgentChoice]?, modeCurrent: String?
        var modelList: [AgentChoice]?, modelCurrent: String?
        if let option = options?.first(where: { $0.category == "mode" }) {
            modeList = option.options.map { AgentChoice(id: $0.value, name: $0.name ?? $0.value, description: $0.description) }
            modeCurrent = option.currentValue?.stringValue
        } else if let modes {
            modeList = modes.availableModes.map { AgentChoice(id: $0.id, name: $0.name ?? $0.id, description: $0.description) }
            modeCurrent = modes.currentModeId
        }
        if let option = options?.first(where: { $0.category == "model" }) {
            modelList = option.options.map { AgentChoice(id: $0.value, name: $0.name ?? $0.value, description: $0.description) }
            modelCurrent = option.currentValue?.stringValue
        } else if let models {
            modelList = models.availableModels.map { AgentChoice(id: $0.modelId, name: $0.name ?? $0.modelId, description: $0.description) }
            modelCurrent = models.currentModelId
        }
        if let modeList, !modeList.isEmpty {
            availableModes = modeList
            if modeList != lastModes || modeCurrent != lastModeID {
                lastModes = modeList; lastModeID = modeCurrent
                out.append(.agentState(.modes(current: modeCurrent, available: modeList)))
            }
        }
        if let modelList, !modelList.isEmpty {
            availableModels = modelList
            if modelList != lastModels || modelCurrent != lastModelID {
                lastModels = modelList; lastModelID = modelCurrent
                out.append(.agentState(.models(current: modelCurrent, available: modelList)))
            }
        }
        return out
    }

    /// The model id and mode id the agent currently reports (for the synthesized `system/init`).
    public var currentModelID: String? { lastModelID }
    public var currentModeID: String? { lastModeID }

    // MARK: turn end

    public mutating func resetTurn() { open = nil; openMessageID = nil }

    /// The `session/prompt` response as the messages that end the turn.
    public mutating func result(for prompt: ACPPromptResult, sessionID: String) -> [InboundMessage] {
        resetTurn()
        var out: [InboundMessage] = []
        var reason: String?
        switch prompt.stopReason {
        case "end_turn": break
        case "cancelled": reason = "aborted_streaming"
        case "refusal": out.append(.notice(kind: .warning, text: "The agent refused to continue."))
        case "max_tokens": out.append(.notice(kind: .warning, text: "The agent stopped: it reached its token limit."))
        case "max_turn_requests": out.append(.notice(kind: .warning, text: "The agent stopped: it reached its turn limit."))
        case let other: out.append(.notice(kind: .warning, text: "The agent stopped: \(other)."))
        }
        out.append(.result(TurnResult(
            subtype: "success", isError: false, costUSD: 0,
            inputTokens: prompt.usage?.inputTokens ?? 0, outputTokens: prompt.usage?.outputTokens ?? 0,
            sessionID: sessionID, terminalReason: reason,
            cacheCreationTokens: prompt.usage?.cachedWriteTokens ?? 0, cacheReadTokens: prompt.usage?.cachedReadTokens ?? 0)))
        return out
    }
}
