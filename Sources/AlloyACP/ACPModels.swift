import AlloyCore
import Foundation

// ACP protocol version 1, written from the schema. Every decoder ignores unknown keys; optional fields use
// `decodeIfPresent` (the synthesized behaviour for optionals), so a newer agent never breaks a line.

public let acpProtocolVersion = 1

public struct ACPNameValue: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

// MARK: initialize

public struct ACPInitializeParams: Codable, Sendable, Equatable {
    public struct FS: Codable, Sendable, Equatable {
        public var readTextFile: Bool
        public var writeTextFile: Bool
        public init(readTextFile: Bool, writeTextFile: Bool) { self.readTextFile = readTextFile; self.writeTextFile = writeTextFile }
    }
    public struct Auth: Codable, Sendable, Equatable {
        public var terminal: Bool
        public init(terminal: Bool) { self.terminal = terminal }
    }
    public struct SessionCaps: Codable, Sendable, Equatable {
        public var notices: Bool
        public var compaction: Bool
        public init(notices: Bool, compaction: Bool) { self.notices = notices; self.compaction = compaction }
    }
    public struct ClientCapabilities: Codable, Sendable, Equatable {
        public var fs: FS
        public var auth: Auth
        public var session: SessionCaps
        public init(fs: FS, auth: Auth, session: SessionCaps) { self.fs = fs; self.auth = auth; self.session = session }
    }
    public struct ClientInfo: Codable, Sendable, Equatable {
        public var name: String
        public var title: String?
        public var version: String
        public init(name: String, title: String? = nil, version: String) { self.name = name; self.title = title; self.version = version }
    }

    public var protocolVersion: Int
    public var clientCapabilities: ClientCapabilities
    public var clientInfo: ClientInfo

    /// The capabilities Alloy implements: fs read/write, terminal auth, notices, compaction; never `terminal`.
    public init(clientInfo: ClientInfo) {
        self.protocolVersion = acpProtocolVersion
        self.clientCapabilities = ClientCapabilities(
            fs: FS(readTextFile: true, writeTextFile: true),
            auth: Auth(terminal: true),
            session: SessionCaps(notices: true, compaction: true))
        self.clientInfo = clientInfo
    }
}

public struct ACPAuthMethod: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var description: String?
    /// Absent for plain agent-run methods; `terminal` for methods Alloy runs in a terminal.
    public var type: String?
    public var args: [String]?
    /// Kept raw: the schema shape (list of name/value or a map) varies between agents.
    public var env: JSONValue?
}

public struct ACPAgentCapabilities: Codable, Sendable, Equatable {
    public struct Prompt: Codable, Sendable, Equatable {
        public var image: Bool?
        public var audio: Bool?
        public var embeddedContext: Bool?
    }
    public struct MCP: Codable, Sendable, Equatable {
        public var http: Bool?
        public var sse: Bool?
        public var acp: Bool?
    }
    /// A capability is present when its key exists (the value is usually `{}`).
    public struct SessionCaps: Codable, Sendable, Equatable {
        public var resume: JSONValue?
        public var list: JSONValue?
        public var close: JSONValue?
        public var fork: JSONValue?
        public var delete: JSONValue?
        public var title: JSONValue?
        public var systemPrompt: JSONValue?
    }

    public var loadSession: Bool?
    public var promptCapabilities: Prompt?
    public var mcpCapabilities: MCP?
    public var sessionCapabilities: SessionCaps?

    public var canLoad: Bool { loadSession == true }
    public var canResume: Bool { sessionCapabilities?.resume != nil }
    public var acceptsSystemPrompt: Bool { sessionCapabilities?.systemPrompt != nil }
    public var acceptsHTTPMCP: Bool { mcpCapabilities?.http == true }
    public var acceptsImages: Bool { promptCapabilities?.image == true }
}

public struct ACPAgentInfo: Codable, Sendable, Equatable {
    public var name: String?
    public var title: String?
    public var version: String?
}

public struct ACPInitializeResult: Codable, Sendable, Equatable {
    public var protocolVersion: Int?
    public var agentInfo: ACPAgentInfo?
    public var agentCapabilities: ACPAgentCapabilities?
    public var authMethods: [ACPAuthMethod]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion)
        agentInfo = try c.decodeIfPresent(ACPAgentInfo.self, forKey: .agentInfo)
        agentCapabilities = try c.decodeIfPresent(ACPAgentCapabilities.self, forKey: .agentCapabilities)
        authMethods = try c.decodeIfPresent([ACPAuthMethod].self, forKey: .authMethods) ?? []
    }
    private enum Keys: String, CodingKey { case protocolVersion, agentInfo, agentCapabilities, authMethods }
}

public struct ACPAuthenticateParams: Codable, Sendable, Equatable {
    public var methodId: String
    public init(methodId: String) { self.methodId = methodId }
}

// MARK: sessions

/// An MCP server offered to the agent in `session/new`, `session/load` and `session/resume`.
public enum ACPMCPServer: Encodable, Sendable, Equatable {
    case stdio(name: String, command: String, args: [String], env: [ACPNameValue])
    case http(name: String, url: String, headers: [ACPNameValue])

    private enum Keys: String, CodingKey { case type, name, command, args, env, url, headers }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .stdio(let name, let command, let args, let env):
            try c.encode(name, forKey: .name)
            try c.encode(command, forKey: .command)
            try c.encode(args, forKey: .args)
            try c.encode(env, forKey: .env)
        case .http(let name, let url, let headers):
            try c.encode("http", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(url, forKey: .url)
            try c.encode(headers, forKey: .headers)
        }
    }
}

/// Client-provided instructions, appended to the agent's own (only sent when the agent advertises the capability).
public struct ACPSystemPrompt: Encodable, Sendable, Equatable {
    public var mode = "append"
    public var content: [ACPContentBlock]
    public init(text: String) { content = [.text(text)] }
}

public struct ACPSessionNewParams: Encodable, Sendable {
    public var cwd: String
    public var mcpServers: [ACPMCPServer]
    public var systemPrompt: ACPSystemPrompt?
    public init(cwd: String, mcpServers: [ACPMCPServer] = [], systemPrompt: ACPSystemPrompt? = nil) {
        self.cwd = cwd; self.mcpServers = mcpServers; self.systemPrompt = systemPrompt
    }
}

public struct ACPSessionLoadParams: Encodable, Sendable {
    public var sessionId: String
    public var cwd: String
    public var mcpServers: [ACPMCPServer]
    public var systemPrompt: ACPSystemPrompt?
    public init(sessionId: String, cwd: String, mcpServers: [ACPMCPServer] = [], systemPrompt: ACPSystemPrompt? = nil) {
        self.sessionId = sessionId; self.cwd = cwd; self.mcpServers = mcpServers; self.systemPrompt = systemPrompt
    }
}

/// `session/resume` takes the same parameters as `session/load` but replays nothing.
public typealias ACPSessionResumeParams = ACPSessionLoadParams

public struct ACPMode: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var description: String?
}

public struct ACPModes: Codable, Sendable, Equatable {
    public var currentModeId: String?
    public var availableModes: [ACPMode]
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        currentModeId = try c.decodeIfPresent(String.self, forKey: .currentModeId)
        availableModes = try c.decodeIfPresent([ACPMode].self, forKey: .availableModes) ?? []
    }
    private enum Keys: String, CodingKey { case currentModeId, availableModes }
}

public struct ACPModelInfo: Codable, Sendable, Equatable {
    public var modelId: String
    public var name: String?
    public var description: String?
}

public struct ACPModelState: Codable, Sendable, Equatable {
    public var currentModelId: String?
    public var availableModels: [ACPModelInfo]
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        currentModelId = try c.decodeIfPresent(String.self, forKey: .currentModelId)
        availableModels = try c.decodeIfPresent([ACPModelInfo].self, forKey: .availableModels) ?? []
    }
    private enum Keys: String, CodingKey { case currentModelId, availableModels }
}

public struct ACPConfigChoice: Codable, Sendable, Equatable {
    public var value: String
    public var name: String?
    public var description: String?
}

/// A session config option (mode, model, thought level, ...). `category` is open: unknown categories are kept.
public struct ACPConfigOption: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var description: String?
    public var category: String?
    public var type: String?
    public var currentValue: JSONValue?
    /// Flattened: grouped options (`{group, options}`) contribute their members in order.
    public var options: [ACPConfigChoice]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        currentValue = try c.decodeIfPresent(JSONValue.self, forKey: .currentValue)
        var flat: [ACPConfigChoice] = []
        for raw in try c.decodeIfPresent([JSONValue].self, forKey: .options) ?? [] {
            if let nested = raw["options"]?.arrayValue {
                for item in nested { if let ch = Self.choice(item) { flat.append(ch) } }
            } else if let ch = Self.choice(raw) {
                flat.append(ch)
            }
        }
        options = flat
    }

    private static func choice(_ v: JSONValue) -> ACPConfigChoice? {
        guard let value = v["value"]?.stringValue else { return nil }
        return ACPConfigChoice(value: value, name: v["name"]?.stringValue, description: v["description"]?.stringValue)
    }

    private enum Keys: String, CodingKey { case id, name, description, category, type, currentValue, options }
}

public struct ACPSessionNewResult: Decodable, Sendable, Equatable {
    public var sessionId: String
    public var modes: ACPModes?
    public var models: ACPModelState?
    public var configOptions: [ACPConfigOption]?
}

/// The result of `session/load`, `session/resume` and `session/set_config_option`.
public struct ACPSessionStateResult: Decodable, Sendable, Equatable {
    public var modes: ACPModes?
    public var models: ACPModelState?
    public var configOptions: [ACPConfigOption]?
}

public struct ACPSetModeParams: Encodable, Sendable {
    public var sessionId: String
    public var modeId: String
    public init(sessionId: String, modeId: String) { self.sessionId = sessionId; self.modeId = modeId }
}

public struct ACPSetConfigOptionParams: Encodable, Sendable {
    public var sessionId: String
    public var configId: String
    public var value: String
    public init(sessionId: String, configId: String, value: String) {
        self.sessionId = sessionId; self.configId = configId; self.value = value
    }
}

public struct ACPCancelParams: Encodable, Sendable {
    public var sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
}

// MARK: prompt

public enum ACPContentBlock: Codable, Sendable, Equatable {
    case text(String)
    case image(data: String, mimeType: String)
    case resourceLink(uri: String, name: String?)
    case resource(JSONValue)
    case audio(JSONValue)
    case unknown(String)

    private enum Keys: String, CodingKey { case type, text, data, mimeType, uri, name, resource }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        switch type {
        case "text": self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "image":
            self = .image(data: try c.decodeIfPresent(String.self, forKey: .data) ?? "",
                          mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "")
        case "resource_link":
            self = .resourceLink(uri: try c.decodeIfPresent(String.self, forKey: .uri) ?? "",
                                 name: try c.decodeIfPresent(String.self, forKey: .name))
        case "resource": self = .resource(try c.decodeIfPresent(JSONValue.self, forKey: .resource) ?? .null)
        case "audio": self = .audio(try JSONValue(from: decoder))
        default: self = .unknown(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type); try c.encode(t, forKey: .text)
        case .image(let data, let mime):
            try c.encode("image", forKey: .type); try c.encode(data, forKey: .data); try c.encode(mime, forKey: .mimeType)
        case .resourceLink(let uri, let name):
            try c.encode("resource_link", forKey: .type); try c.encode(uri, forKey: .uri)
            try c.encodeIfPresent(name, forKey: .name)
        case .resource(let r):
            try c.encode("resource", forKey: .type); try c.encode(r, forKey: .resource)
        case .audio(let v): try v.encode(to: encoder)
        case .unknown(let t): try c.encode(t, forKey: .type)
        }
    }

    /// The text of a text block, else nil.
    public var textValue: String? { if case .text(let t) = self { t } else { nil } }
}

public struct ACPPromptParams: Encodable, Sendable {
    public var sessionId: String
    public var prompt: [ACPContentBlock]
    public init(sessionId: String, prompt: [ACPContentBlock]) { self.sessionId = sessionId; self.prompt = prompt }
}

public struct ACPTokenUsage: Codable, Sendable, Equatable {
    public var totalTokens: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedReadTokens: Int?
    public var cachedWriteTokens: Int?
    public var thoughtTokens: Int?
}

public struct ACPPromptResult: Decodable, Sendable, Equatable {
    /// `end_turn`, `max_tokens`, `max_turn_requests`, `refusal`, `cancelled`; kept open for newer values.
    public var stopReason: String
    public var usage: ACPTokenUsage?

    public init(stopReason: String, usage: ACPTokenUsage? = nil) { self.stopReason = stopReason; self.usage = usage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason) ?? "end_turn"
        usage = try? c.decodeIfPresent(ACPTokenUsage.self, forKey: .usage)
    }
    private enum Keys: String, CodingKey { case stopReason, usage }
}

// MARK: permission

public struct ACPPermissionOption: Codable, Sendable, Equatable {
    public var optionId: String
    public var name: String?
    /// `allow_once`, `allow_always`, `reject_once`, `reject_always`.
    public var kind: String?
}

public struct ACPPermissionRequest: Decodable, Sendable, Equatable {
    public var sessionId: String?
    public var toolCall: ACPToolCall
    public var options: [ACPPermissionOption]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        toolCall = try c.decode(ACPToolCall.self, forKey: .toolCall)
        options = try c.decodeIfPresent([ACPPermissionOption].self, forKey: .options) ?? []
    }
    private enum Keys: String, CodingKey { case sessionId, toolCall, options }
}

public enum ACPPermissionOutcome: Encodable, Sendable, Equatable {
    case selected(optionId: String)
    case cancelled

    private enum Keys: String, CodingKey { case outcome }
    private enum Inner: String, CodingKey { case outcome, optionId }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        var inner = c.nestedContainer(keyedBy: Inner.self, forKey: .outcome)
        switch self {
        case .selected(let id):
            try inner.encode("selected", forKey: .outcome)
            try inner.encode(id, forKey: .optionId)
        case .cancelled:
            try inner.encode("cancelled", forKey: .outcome)
        }
    }

    /// The JSON-RPC `result` for `respond(id:result:)`.
    public var json: JSONValue {
        switch self {
        case .selected(let id): .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(id)])])
        case .cancelled: .object(["outcome": .object(["outcome": .string("cancelled")])])
        }
    }
}

// MARK: files (agent-to-client)

public struct ACPReadTextFileParams: Decodable, Sendable, Equatable {
    public var sessionId: String?
    public var path: String
    public var line: Int?
    public var limit: Int?
}

public struct ACPWriteTextFileParams: Decodable, Sendable, Equatable {
    public var sessionId: String?
    public var path: String
    public var content: String
}
