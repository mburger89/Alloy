import Foundation

/// What runs a session: the native Claude CLI, or an ACP agent named by its definition id.
public enum SessionBackend: Codable, Sendable, Equatable, Hashable {
    case claude
    case acp(agentID: String)

    public var isACP: Bool { if case .acp = self { true } else { false } }
    public var agentID: String? { if case .acp(let id) = self { id } else { nil } }

    private enum CodingKeys: String, CodingKey { case kind, agentID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .kind) {
        case "acp":
            if let id = try c.decodeIfPresent(String.self, forKey: .agentID), !id.isEmpty { self = .acp(agentID: id) }
            else { self = .claude }
        default: self = .claude
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .claude: try c.encode("claude", forKey: .kind)
        case .acp(let id):
            try c.encode("acp", forKey: .kind)
            try c.encode(id, forKey: .agentID)
        }
    }
}

/// A selectable mode or model an agent offers.
public struct AgentChoice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public init(id: String, name: String, description: String? = nil) {
        self.id = id; self.name = name; self.description = description
    }
}

/// Context use and cost an agent reports for a session.
public struct SessionUsage: Sendable, Equatable {
    public var used: Int?
    public var size: Int?
    public var cost: Double?
    public var currency: String?
    public init(used: Int? = nil, size: Int? = nil, cost: Double? = nil, currency: String? = nil) {
        self.used = used; self.size = size; self.cost = cost; self.currency = currency
    }
}

/// Agent state that has no Claude equivalent, carried through the wire model.
public enum AgentStateUpdate: Sendable, Equatable {
    case modes(current: String?, available: [AgentChoice])
    case models(current: String?, available: [AgentChoice])
    case usage(SessionUsage)
}
