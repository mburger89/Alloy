import Foundation

/// User settings at `<appSupport>/Alloy/settings.json`.
public struct AlloySettings: Codable, Equatable, Sendable {
    public var claudePath: String?

    /// The project opened last, used when Alloy is launched without a folder argument.
    public var lastProjectPath: String?

    /// Sessions share notes about files through Alloy's local MCP server.
    public var shareKnowledge: Bool

    /// With sharing on, still ask before a session uses Alloy's tools (notes and coordination). The stored key keeps its
    /// original name so an older settings file still loads.
    public var askBeforeSharedNotes: Bool

    public init(claudePath: String? = nil, lastProjectPath: String? = nil,
                shareKnowledge: Bool = true, askBeforeSharedNotes: Bool = false) {
        self.claudePath = claudePath
        self.lastProjectPath = lastProjectPath
        self.shareKnowledge = shareKnowledge
        self.askBeforeSharedNotes = askBeforeSharedNotes
    }

    private enum CodingKeys: String, CodingKey {
        case claudePath, lastProjectPath, shareKnowledge, askBeforeSharedNotes
    }

    /// Every key is optional, so a file written by an older Alloy still loads with its values intact.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        lastProjectPath = try c.decodeIfPresent(String.self, forKey: .lastProjectPath)
        shareKnowledge = try c.decodeIfPresent(Bool.self, forKey: .shareKnowledge) ?? true
        askBeforeSharedNotes = try c.decodeIfPresent(Bool.self, forKey: .askBeforeSharedNotes) ?? false
    }

    /// Where Alloy keeps its settings, ledgers and sessions: a non-empty `ALLOY_DATA_DIR` replaces Application
    /// Support, so a benchmark or test launch leaves the user's real data alone.
    public static func appSupportDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                           default fallback: URL) -> URL {
        if let dir = environment["ALLOY_DATA_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return fallback
    }

    static func url(appSupport: URL) -> URL { appSupport.appendingPathComponent("Alloy/settings.json") }

    /// Missing or unreadable files give defaults. `claudePath` is exactly what was stored.
    public static func load(appSupport: URL) -> AlloySettings {
        (try? JSONDecoder().decode(AlloySettings.self, from: Data(contentsOf: url(appSupport: appSupport)))) ?? AlloySettings()
    }

    /// A non-empty `ALLOY_CLAUDE_PATH` wins over the stored `claudePath`. Never written back by `save`.
    public func effectiveClaudePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let env = environment["ALLOY_CLAUDE_PATH"], !env.isEmpty { return env }
        return claudePath
    }

    public func save(appSupport: URL) throws {
        let u = Self.url(appSupport: appSupport)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: u, options: .atomic)
    }
}
