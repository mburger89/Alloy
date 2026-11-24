import Foundation

/// What a plugin may be granted. The user approves the manifest's list when enabling the plugin.
public enum PluginPermission: String, Codable, CaseIterable, Comparable, Sendable {
    case projectRead = "project.read"
    case projectWrite = "project.write"
    case network
    case processSpawn = "process.spawn"
    case sessionsRead = "sessions.read"
    case mcpTools = "mcp.tools"

    public static func < (a: PluginPermission, b: PluginPermission) -> Bool { a.rawValue < b.rawValue }
}

/// Where an installed plugin came from.
public enum PluginSource: Codable, Equatable, Sendable {
    case folder(path: String)
    case git(url: String, tag: String, commit: String)

    private enum CodingKeys: String, CodingKey { case kind, path, url, tag, commit }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "folder":
            self = .folder(path: try c.decode(String.self, forKey: .path))
        case "git":
            self = .git(url: try c.decode(String.self, forKey: .url), tag: try c.decode(String.self, forKey: .tag),
                        commit: try c.decode(String.self, forKey: .commit))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown plugin source kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folder(let path):
            try c.encode("folder", forKey: .kind)
            try c.encode(path, forKey: .path)
        case .git(let url, let tag, let commit):
            try c.encode("git", forKey: .kind)
            try c.encode(url, forKey: .url)
            try c.encode(tag, forKey: .tag)
            try c.encode(commit, forKey: .commit)
        }
    }
}

/// One installed plugin's entry in `AlloySettings.plugins`, keyed by plugin id.
public struct PluginSetting: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var version: String
    public var source: PluginSource
    /// The permissions the user approved.
    public var grants: Set<PluginPermission>
    /// The plugin's own settings values (never secrets; those live in the Keychain).
    public var values: [String: JSONValue]
    /// Orders plugins by when they were enabled (later wins a shortcut or server-id collision).
    public var enableOrder: Int
    /// Set when Alloy switched the plugin off after repeated crashes.
    public var disabledAfterCrashes: Bool

    public init(enabled: Bool = false, version: String = "", source: PluginSource, grants: Set<PluginPermission> = [],
                values: [String: JSONValue] = [:], enableOrder: Int = 0, disabledAfterCrashes: Bool = false) {
        self.enabled = enabled
        self.version = version
        self.source = source
        self.grants = grants
        self.values = values
        self.enableOrder = enableOrder
        self.disabledAfterCrashes = disabledAfterCrashes
    }

    private enum CodingKeys: String, CodingKey { case enabled, version, source, grants, values, enableOrder, disabledAfterCrashes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        source = try c.decode(PluginSource.self, forKey: .source)
        let raw = try c.decodeIfPresent([String].self, forKey: .grants) ?? []
        grants = Set(raw.compactMap { PluginPermission(rawValue: $0) })
        values = try c.decodeIfPresent([String: JSONValue].self, forKey: .values) ?? [:]
        enableOrder = try c.decodeIfPresent(Int.self, forKey: .enableOrder) ?? 0
        disabledAfterCrashes = try c.decodeIfPresent(Bool.self, forKey: .disabledAfterCrashes) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(version, forKey: .version)
        try c.encode(source, forKey: .source)
        try c.encode(grants.sorted().map(\.rawValue), forKey: .grants)
        try c.encode(values, forKey: .values)
        try c.encode(enableOrder, forKey: .enableOrder)
        try c.encode(disabledAfterCrashes, forKey: .disabledAfterCrashes)
    }
}
