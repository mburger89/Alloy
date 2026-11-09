import Foundation

public struct SystemInit: Sendable, Equatable {
    public var model: String
    public var permissionMode: String
    public var sessionID: String
    public var tools: [String]
    public var slashCommands: [String]
    public var skills: [String]
    public var agents: [String]
    /// TUI-only commands (`/doctor`, ...) that must not be offered.
    public var terminalSlashCommands: [String]
    public var claudeCodeVersion: String?
    public var cwd: String?

    public init(model: String, permissionMode: String, sessionID: String, tools: [String], slashCommands: [String],
                skills: [String] = [], agents: [String] = [], terminalSlashCommands: [String] = [],
                claudeCodeVersion: String? = nil, cwd: String? = nil) {
        self.model = model
        self.permissionMode = permissionMode
        self.sessionID = sessionID
        self.tools = tools
        self.slashCommands = slashCommands
        self.skills = skills
        self.agents = agents
        self.terminalSlashCommands = terminalSlashCommands
        self.claudeCodeVersion = claudeCodeVersion
        self.cwd = cwd
    }
}

public struct SlashCommandInfo: Sendable, Equatable, Codable {
    public var name: String
    public var description: String
    public var argumentHint: String?

    public init(name: String, description: String, argumentHint: String?) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
    }
}

public enum ControlResult: Sendable, Equatable {
    case success(JSONValue)
    case error(message: String, code: String?)
}

public enum StreamDelta: Sendable, Equatable {
    case blockStart(index: Int, kind: String)
    case text(index: Int, String)
    case thinking(index: Int, String, estimatedTokens: Int?)
    case toolInput(index: Int, partialJSON: String)
    case blockStop(index: Int)
}

public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case thinking(String)
    /// `parentToolUseID` names the Agent tool_use whose subagent issued this call (nil for the main conversation).
    case toolUse(id: String, name: String, input: JSONValue, parentToolUseID: String? = nil)
}

public enum ToolUseResult: Sendable, Equatable {
    case edit(filePath: String, originalFile: String?, hunks: [PatchHunk])
    case write(filePath: String, isCreate: Bool, content: String, originalFile: String?, hunks: [PatchHunk])
    /// The plain-string form (failures).
    case message(String)
    case other(JSONValue)
    case none
}

/// A Read tool's `tool_use_result.file`.
public struct ReadResult: Sendable, Equatable {
    public var filePath: String
    public var startLine: Int
    public var numLines: Int
    public var totalLines: Int
    /// `truncatedByTokenCap`: the CLI cut the file short.
    public var truncated: Bool

    public init(filePath: String, startLine: Int, numLines: Int, totalLines: Int, truncated: Bool) {
        self.filePath = filePath
        self.startLine = startLine
        self.numLines = numLines
        self.totalLines = totalLines
        self.truncated = truncated
    }
}

public struct ToolResultMessage: Sendable, Equatable {
    public var toolUseID: String
    public var isError: Bool
    public var text: String
    public var result: ToolUseResult
    /// The CLI's `tool_use_result`, undecoded.
    public var raw: JSONValue?
    /// The Agent tool_use whose subagent produced this result (nil for the main conversation).
    public var parentToolUseID: String?

    /// The Read result, when `raw` is a Read's `{type: "text", file: {...}}`.
    public var read: ReadResult? {
        guard let file = raw?["file"], let path = file["filePath"]?.stringValue,
              let start = file["startLine"]?.intValue, let num = file["numLines"]?.intValue,
              let total = file["totalLines"]?.intValue else { return nil }
        return ReadResult(filePath: path, startLine: start, numLines: num, totalLines: total,
                          truncated: file["truncatedByTokenCap"]?.boolValue ?? false)
    }

    public init(toolUseID: String, isError: Bool, text: String, result: ToolUseResult, raw: JSONValue? = nil,
                parentToolUseID: String? = nil) {
        self.parentToolUseID = parentToolUseID
        self.toolUseID = toolUseID
        self.isError = isError
        self.text = text
        self.result = result
        self.raw = raw
    }
}

public struct TurnResult: Sendable, Equatable {
    public var subtype: String
    public var isError: Bool
    public var costUSD: Double
    public var inputTokens: Int
    public var outputTokens: Int
    public var sessionID: String
    public var terminalReason: String?
    public var durationMS: Int?
    public var numTurns: Int?
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int

    public init(subtype: String, isError: Bool, costUSD: Double, inputTokens: Int, outputTokens: Int,
                sessionID: String, terminalReason: String?, durationMS: Int? = nil, numTurns: Int? = nil,
                cacheCreationTokens: Int = 0, cacheReadTokens: Int = 0) {
        self.subtype = subtype
        self.isError = isError
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.sessionID = sessionID
        self.terminalReason = terminalReason
        self.durationMS = durationMS
        self.numTurns = numTurns
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }
}

public struct ControlRequest: Sendable, Equatable {
    public var requestID: String
    public var kind: Kind

    public enum Kind: Sendable, Equatable {
        case canUseTool(toolName: String, input: JSONValue, description: String?, toolUseID: String?, suggestions: [JSONValue])
        case other(subtype: String, body: JSONValue)
    }

    public init(requestID: String, kind: Kind) {
        self.requestID = requestID
        self.kind = kind
    }
}

public enum InboundMessage: Sendable, Equatable {
    case systemInit(SystemInit)
    case delta(StreamDelta)
    case assistantBlock(messageID: String, block: ContentBlock)
    case toolResult(ToolResultMessage)
    case userEcho(text: String, imageCount: Int, uuid: String?, isReplay: Bool)
    case result(TurnResult)
    case controlRequest(ControlRequest)
    case controlCancel(requestID: String)
    case permissionDenied(toolName: String, toolUseID: String, message: String)
    case compactBoundary(preTokens: Int?, postTokens: Int?)
    /// The CLI's own "This session is being continued..." summary line (`isCompactSummary`), never a user message.
    case compactSummary
    case thinkingTokens(Int)
    case commandsChanged([SlashCommandInfo])
    case statusChanged(permissionMode: String?)
    /// `/clear`: the conversation continues under a new session id.
    case conversationReset(newSessionID: String)
    /// A built-in slash command answered locally by the CLI (`/cost`, `/context`, ...).
    case localCommandOutput(text: String)
    case controlResponse(requestID: String, result: ControlResult)
    /// Known-but-unused, including the echoed `control_response` and hook events.
    case ignored(type: String)
    /// Unrecognised or malformed (`"<malformed>"`).
    case unknown(type: String)
}

public enum InboundDecoder {
    /// Decodes one stdout line. Never throws; odd shapes fall back to defaults or `.unknown`.
    public static func decode(_ line: Data) -> InboundMessage {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: line) else { return .unknown(type: malformed) }
        return decode(root)
    }

    /// Decodes one already-parsed stdout line.
    public static func decode(_ root: JSONValue) -> InboundMessage {
        guard case .object = root, let type = root["type"]?.stringValue else {
            return .unknown(type: malformed)
        }
        switch type {
        case "system": return decodeSystem(root)
        case "stream_event": return decodeStreamEvent(root["event"])
        case "assistant": return decodeAssistant(root)
        case "user": return decodeUser(root)
        case "result": return decodeResult(root)
        case "control_request": return decodeControlRequest(root)
        case "control_cancel_request":
            guard let id = root["request_id"]?.stringValue else { return .unknown(type: type) }
            return .controlCancel(requestID: id)
        case "control_response": return decodeControlResponse(root)
        case "conversation_reset":
            guard let id = root["new_conversation_id"]?.stringValue else { return .unknown(type: type) }
            return .conversationReset(newSessionID: id)
        case "rate_limit_event": return .ignored(type: type)
        default: return .unknown(type: type)
        }
    }

    private static let malformed = "<malformed>"

    private static func strings(_ v: JSONValue?) -> [String] {
        (v?.arrayValue ?? []).compactMap(\.stringValue)
    }

    static func commands(_ v: JSONValue?) -> [SlashCommandInfo] {
        (v?.arrayValue ?? []).compactMap { c in
            guard let name = c["name"]?.stringValue else { return nil }
            let hint = c["argumentHint"]?.stringValue
            return SlashCommandInfo(name: name, description: c["description"]?.stringValue ?? "",
                                    argumentHint: hint?.isEmpty == false ? hint : nil)
        }
    }

    private static func decodeControlResponse(_ root: JSONValue) -> InboundMessage {
        guard let response = root["response"], let id = response["request_id"]?.stringValue else {
            return .ignored(type: "control_response")
        }
        // The CLI also echoes the host's own permission answers; those carry a `behavior`.
        if response["response"]?["behavior"] != nil { return .ignored(type: "control_response") }
        switch response["subtype"]?.stringValue {
        case "success": return .controlResponse(requestID: id, result: .success(response["response"] ?? .null))
        case "error":
            return .controlResponse(requestID: id, result: .error(
                message: response["error"]?.stringValue ?? "", code: response["error_code"]?.stringValue))
        default: return .ignored(type: "control_response")
        }
    }

    private static func decodeSystem(_ root: JSONValue) -> InboundMessage {
        let subtype = root["subtype"]?.stringValue ?? ""
        switch subtype {
        case "init":
            return .systemInit(SystemInit(
                model: root["model"]?.stringValue ?? "",
                permissionMode: root["permissionMode"]?.stringValue ?? "",
                sessionID: root["session_id"]?.stringValue ?? "",
                tools: strings(root["tools"]),
                slashCommands: strings(root["slash_commands"]),
                skills: strings(root["skills"]),
                agents: strings(root["agents"]),
                terminalSlashCommands: strings(root["terminal_slash_commands"]),
                claudeCodeVersion: root["claude_code_version"]?.stringValue,
                cwd: root["cwd"]?.stringValue))
        case "commands_changed":
            return .commandsChanged(commands(root["commands"]))
        case "status":
            return .statusChanged(permissionMode: root["permissionMode"]?.stringValue)
        case "thinking_tokens":
            return .thinkingTokens(root["estimated_tokens"]?.intValue ?? 0)
        case "compact_boundary":
            let meta = root["compact_metadata"]
            return .compactBoundary(preTokens: meta?["pre_tokens"]?.intValue, postTokens: meta?["post_tokens"]?.intValue)
        case "permission_denied":
            return .permissionDenied(
                toolName: root["tool_name"]?.stringValue ?? "",
                toolUseID: root["tool_use_id"]?.stringValue ?? "",
                message: root["message"]?.stringValue ?? "")
        default:
            return .ignored(type: "system/\(subtype)")
        }
    }

    private static func decodeStreamEvent(_ event: JSONValue?) -> InboundMessage {
        guard let event, let type = event["type"]?.stringValue else { return .unknown(type: "stream_event") }
        let index = event["index"]?.intValue ?? 0
        switch type {
        case "content_block_start":
            return .delta(.blockStart(index: index, kind: event["content_block"]?["type"]?.stringValue ?? ""))
        case "content_block_stop":
            return .delta(.blockStop(index: index))
        case "content_block_delta":
            let d = event["delta"]
            switch d?["type"]?.stringValue {
            case "text_delta":
                return .delta(.text(index: index, d?["text"]?.stringValue ?? ""))
            case "thinking_delta":
                return .delta(.thinking(index: index, d?["thinking"]?.stringValue ?? "",
                                        estimatedTokens: d?["estimated_tokens"]?.intValue))
            case "input_json_delta":
                return .delta(.toolInput(index: index, partialJSON: d?["partial_json"]?.stringValue ?? ""))
            case "signature_delta":
                return .ignored(type: "stream_event/signature_delta")
            default:
                return .ignored(type: "stream_event/content_block_delta")
            }
        default:
            // message_start, message_delta, message_stop and anything newer.
            return .ignored(type: "stream_event/\(type)")
        }
    }

    private static func decodeAssistant(_ root: JSONValue) -> InboundMessage {
        let message = root["message"]
        if message?["model"]?.stringValue == "<synthetic>" || root["local_command_source"] != nil {
            var text = (message?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            if text.isEmpty, let source = root["local_command_source"]?.stringValue {
                text = source.replacingOccurrences(of: "<local-command-stdout>", with: "")
                    .replacingOccurrences(of: "</local-command-stdout>", with: "")
            }
            return .localCommandOutput(text: text)
        }
        let id = message?["id"]?.stringValue ?? ""
        // The CLI emits one content block per assistant message. If one ever carries several,
        // only the first decodable block is surfaced.
        for item in message?["content"]?.arrayValue ?? [] {
            switch item["type"]?.stringValue {
            case "text": return .assistantBlock(messageID: id, block: .text(item["text"]?.stringValue ?? ""))
            case "thinking": return .assistantBlock(messageID: id, block: .thinking(item["thinking"]?.stringValue ?? ""))
            case "tool_use":
                return .assistantBlock(messageID: id, block: .toolUse(
                    id: item["id"]?.stringValue ?? "",
                    name: item["name"]?.stringValue ?? "",
                    input: item["input"] ?? .null,
                    parentToolUseID: root["parent_tool_use_id"]?.stringValue))
            default: continue
            }
        }
        return .unknown(type: "assistant")
    }

    private static func decodeUser(_ root: JSONValue) -> InboundMessage {
        let content = root["message"]?["content"]
        if let blocks = content?.arrayValue,
           let block = blocks.first(where: { $0["type"]?.stringValue == "tool_result" }) {
            return .toolResult(ToolResultMessage(
                toolUseID: block["tool_use_id"]?.stringValue ?? "",
                isError: block["is_error"]?.boolValue ?? false,
                text: resultText(block["content"]),
                result: decodeToolUseResult(root["tool_use_result"]),
                raw: root["tool_use_result"],
                parentToolUseID: root["parent_tool_use_id"]?.stringValue))
        }
        let text: String
        if let s = content?.stringValue { text = s }
        else {
            // Alloy's "already read" block rides as a leading text part; the bubble and every echo compare only
            // what the user typed.
            var parts = (content?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
            if parts.count > 1, parts[0].hasPrefix(AlreadyRead.header) { parts.removeFirst() }
            else if parts.count == 1, AlreadyRead.isBlock(parts[0]) { parts.removeAll() }   // an image-only message
            text = parts.joined(separator: "\n")
        }
        let images = (content?.arrayValue ?? []).filter { $0["type"]?.stringValue == "image" }.count
        // Lines the CLI writes itself: the compaction summary, other synthetic echoes and the interrupt marker
        // (the "Interrupted" notice already covers it) are never user bubbles.
        if root["isCompactSummary"]?.boolValue == true { return .compactSummary }
        if root["isSynthetic"]?.boolValue == true || text.hasPrefix("[Request interrupted by user") {
            return .ignored(type: "user")
        }
        return .userEcho(text: text, imageCount: images, uuid: root["uuid"]?.stringValue,
                         isReplay: root["isReplay"]?.boolValue ?? false)
    }

    private static func resultText(_ v: JSONValue?) -> String {
        if let s = v?.stringValue { return s }
        return (v?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    private static func hunks(_ v: JSONValue?) -> [PatchHunk] {
        (v?.arrayValue ?? []).map {
            PatchHunk(oldStart: $0["oldStart"]?.intValue ?? 0, oldLines: $0["oldLines"]?.intValue ?? 0,
                      newStart: $0["newStart"]?.intValue ?? 0, newLines: $0["newLines"]?.intValue ?? 0,
                      lines: strings($0["lines"]))
        }
    }

    private static func decodeToolUseResult(_ v: JSONValue?) -> ToolUseResult {
        guard let v else { return .none }
        if case .null = v { return .none }
        if let s = v.stringValue { return .message(s) }
        guard case .object = v else { return .other(v) }
        let path = v["filePath"]?.stringValue
        switch v["type"]?.stringValue {
        case "create", "update":
            if let path {
                return .write(filePath: path, isCreate: v["type"]?.stringValue == "create",
                              content: v["content"]?.stringValue ?? "",
                              originalFile: v["originalFile"]?.stringValue, hunks: hunks(v["structuredPatch"]))
            }
        case nil:
            if let path, v["structuredPatch"] != nil, v["originalFile"] != nil {
                return .edit(filePath: path, originalFile: v["originalFile"]?.stringValue,
                             hunks: hunks(v["structuredPatch"]))
            }
        default: break
        }
        return .other(v)
    }

    private static func decodeResult(_ root: JSONValue) -> InboundMessage {
        let usage = root["usage"]
        return .result(TurnResult(
            subtype: root["subtype"]?.stringValue ?? "",
            isError: root["is_error"]?.boolValue ?? false,
            costUSD: root["total_cost_usd"]?.doubleValue ?? 0,
            inputTokens: usage?["input_tokens"]?.intValue ?? 0,
            outputTokens: usage?["output_tokens"]?.intValue ?? 0,
            sessionID: root["session_id"]?.stringValue ?? "",
            terminalReason: root["terminal_reason"]?.stringValue,
            durationMS: root["duration_ms"]?.intValue,
            numTurns: root["num_turns"]?.intValue,
            cacheCreationTokens: usage?["cache_creation_input_tokens"]?.intValue ?? 0,
            cacheReadTokens: usage?["cache_read_input_tokens"]?.intValue ?? 0))
    }

    private static func decodeControlRequest(_ root: JSONValue) -> InboundMessage {
        guard let id = root["request_id"]?.stringValue, let req = root["request"],
              let subtype = req["subtype"]?.stringValue else { return .unknown(type: "control_request") }
        if subtype == "can_use_tool" {
            return .controlRequest(ControlRequest(requestID: id, kind: .canUseTool(
                toolName: req["tool_name"]?.stringValue ?? "",
                input: req["input"] ?? .null,
                description: req["description"]?.stringValue,
                toolUseID: req["tool_use_id"]?.stringValue,
                suggestions: req["permission_suggestions"]?.arrayValue ?? [])))
        }
        return .controlRequest(ControlRequest(requestID: id, kind: .other(subtype: subtype, body: req)))
    }
}
