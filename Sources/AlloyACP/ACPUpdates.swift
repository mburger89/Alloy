import AlloyCore
import Foundation

// `session/update` notification payloads (ACP v1). Unknown variants decode to `.unknown`; unknown fields are ignored.

public struct ACPLocation: Codable, Sendable, Equatable {
    public var path: String
    public var line: Int?
}

public enum ACPToolContent: Decodable, Sendable, Equatable {
    case content(ACPContentBlock)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(terminalId: String)
    case unknown(String)

    private enum Keys: String, CodingKey { case type, content, path, oldText, newText, terminalId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decodeIfPresent(String.self, forKey: .type) ?? "" {
        case "content":
            self = .content(try c.decodeIfPresent(ACPContentBlock.self, forKey: .content) ?? .unknown("content"))
        case "diff":
            self = .diff(path: try c.decodeIfPresent(String.self, forKey: .path) ?? "",
                         oldText: try c.decodeIfPresent(String.self, forKey: .oldText),
                         newText: try c.decodeIfPresent(String.self, forKey: .newText) ?? "")
        case "terminal":
            self = .terminal(terminalId: try c.decodeIfPresent(String.self, forKey: .terminalId) ?? "")
        case let other: self = .unknown(other)
        }
    }
}

/// A `tool_call` and a `tool_call_update` share this shape; on an update every field but the id may be absent.
public struct ACPToolCall: Decodable, Sendable, Equatable {
    public var toolCallId: String
    public var title: String?
    /// `read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `other`; open.
    public var kind: String?
    /// `pending`, `in_progress`, `completed`, `failed`; open.
    public var status: String?
    public var content: [ACPToolContent]?
    public var locations: [ACPLocation]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?
}

public typealias ACPToolCallUpdate = ACPToolCall

public struct ACPMessageChunk: Decodable, Sendable, Equatable {
    public var messageId: String?
    public var content: ACPContentBlock
    public init(messageId: String? = nil, content: ACPContentBlock) { self.messageId = messageId; self.content = content }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        messageId = try c.decodeIfPresent(String.self, forKey: .messageId)
        content = try c.decodeIfPresent(ACPContentBlock.self, forKey: .content) ?? .unknown("")
    }
    private enum Keys: String, CodingKey { case messageId, content }
}

public struct ACPPlanEntry: Decodable, Sendable, Equatable {
    public var content: String
    public var priority: String?
    public var status: String?
    public init(content: String, priority: String? = nil, status: String? = nil) {
        self.content = content; self.priority = priority; self.status = status
    }
}

public struct ACPCommand: Decodable, Sendable, Equatable {
    public var name: String
    public var description: String?
    /// The argument hint (`input.hint`), when the command takes input.
    public var inputHint: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        inputHint = try c.decodeIfPresent(JSONValue.self, forKey: .input)?["hint"]?.stringValue
    }
    private enum Keys: String, CodingKey { case name, description, input }
}

public struct ACPUsageUpdate: Decodable, Sendable, Equatable {
    public struct Cost: Decodable, Sendable, Equatable {
        public var amount: Double
        public var currency: String?
    }
    public var used: Int?
    public var size: Int?
    public var cost: Cost?
}

public struct ACPSessionInfoUpdate: Decodable, Sendable, Equatable {
    public var title: String?
    public var updatedAt: String?
    /// Agent-specific extras (Codex reports a busy/idle thread status here).
    public var meta: JSONValue?
    private enum Keys: String, CodingKey { case title, updatedAt, meta = "_meta" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        meta = try c.decodeIfPresent(JSONValue.self, forKey: .meta)
    }
}

public struct ACPNotice: Decodable, Sendable, Equatable {
    public var level: String?
    public var message: String?
}

public enum ACPSessionUpdate: Decodable, Sendable, Equatable {
    case agentMessageChunk(ACPMessageChunk)
    case agentThoughtChunk(ACPMessageChunk)
    case userMessageChunk(ACPMessageChunk)
    case toolCall(ACPToolCall)
    case toolCallUpdate(ACPToolCall)
    case plan([ACPPlanEntry])
    case availableCommands([ACPCommand])
    case currentMode(String)
    case configOptions([ACPConfigOption])
    case usage(ACPUsageUpdate)
    case sessionInfo(ACPSessionInfoUpdate)
    case compaction(JSONValue)
    case notice(ACPNotice)
    case unknown(String)

    private enum Keys: String, CodingKey {
        case sessionUpdate, entries, availableCommands, currentModeId, configOptions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .sessionUpdate) ?? ""
        do {
            switch kind {
            case "agent_message_chunk": self = .agentMessageChunk(try ACPMessageChunk(from: decoder))
            case "agent_thought_chunk": self = .agentThoughtChunk(try ACPMessageChunk(from: decoder))
            case "user_message_chunk": self = .userMessageChunk(try ACPMessageChunk(from: decoder))
            case "tool_call": self = .toolCall(try ACPToolCall(from: decoder))
            case "tool_call_update": self = .toolCallUpdate(try ACPToolCall(from: decoder))
            case "plan": self = .plan(try c.decodeIfPresent([ACPPlanEntry].self, forKey: .entries) ?? [])
            case "available_commands_update":
                self = .availableCommands(try c.decodeIfPresent([ACPCommand].self, forKey: .availableCommands) ?? [])
            case "current_mode_update": self = .currentMode(try c.decodeIfPresent(String.self, forKey: .currentModeId) ?? "")
            case "config_option_update":
                self = .configOptions(try c.decodeIfPresent([ACPConfigOption].self, forKey: .configOptions) ?? [])
            case "usage_update": self = .usage(try ACPUsageUpdate(from: decoder))
            case "session_info_update": self = .sessionInfo(try ACPSessionInfoUpdate(from: decoder))
            case "compaction_update": self = .compaction(try JSONValue(from: decoder))
            case "notice": self = .notice(try ACPNotice(from: decoder))
            default: self = .unknown(kind)
            }
        } catch {
            // A known kind whose body has an unexpected shape degrades to unknown instead of failing the line.
            self = .unknown(kind)
        }
    }
}

public struct ACPSessionNotification: Decodable, Sendable, Equatable {
    public var sessionId: String?
    public var update: ACPSessionUpdate
}
