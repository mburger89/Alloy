import Foundation

/// How a server is used for a file: the one `main` server (definitions, tokens, diagnostics), or any number of
/// `linter` servers (document sync and diagnostics only).
public enum ServerRole: String, Codable, Sendable { case main, linter }

/// A user's edit to one language server, stored in `AlloySettings.languageServers` under the server id. Every field is
/// optional: a set field replaces the built-in value. An entry whose id is not built in adds a server when it has a
/// `command` and `extensions`.
public struct ServerConfigOverride: Codable, Equatable, Sendable {
    public var name: String?
    public var languageID: String?
    /// Extension (lowercased, no dot) -> language id.
    public var languageIDs: [String: String]?
    public var extensions: [String]?
    public var fileNames: [String]?
    public var command: String?
    public var arguments: [String]?
    public var initializationOptions: JSONValue?
    public var enabled: Bool?
    /// `main` or `linter`; an unknown string decodes as nil (ignored).
    public var role: ServerRole?
    /// rust-analyzer: use Clippy for its checks.
    public var clippy: Bool?
    /// Format the file with this server before a deliberate save.
    public var formatOnSave: Bool?

    public init(name: String? = nil, languageID: String? = nil, languageIDs: [String: String]? = nil, extensions: [String]? = nil, fileNames: [String]? = nil,
                command: String? = nil, arguments: [String]? = nil, initializationOptions: JSONValue? = nil, enabled: Bool? = nil,
                role: ServerRole? = nil, clippy: Bool? = nil, formatOnSave: Bool? = nil) {
        self.name = name
        self.languageID = languageID
        self.languageIDs = languageIDs
        self.extensions = extensions
        self.fileNames = fileNames
        self.command = command
        self.arguments = arguments
        self.initializationOptions = initializationOptions
        self.enabled = enabled
        self.role = role
        self.clippy = clippy
        self.formatOnSave = formatOnSave
    }

    private enum CodingKeys: String, CodingKey {
        case name, languageID, languageIDs, extensions, fileNames, command, arguments, initializationOptions, enabled, role, clippy, formatOnSave
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        languageID = try c.decodeIfPresent(String.self, forKey: .languageID)
        languageIDs = try c.decodeIfPresent([String: String].self, forKey: .languageIDs)
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions)
        fileNames = try c.decodeIfPresent([String].self, forKey: .fileNames)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments)
        initializationOptions = try c.decodeIfPresent(JSONValue.self, forKey: .initializationOptions)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        role = (try? c.decodeIfPresent(String.self, forKey: .role)).flatMap { ServerRole(rawValue: $0) }
        clippy = try c.decodeIfPresent(Bool.self, forKey: .clippy)
        formatOnSave = try c.decodeIfPresent(Bool.self, forKey: .formatOnSave)
    }

    /// This override laid over `base`: every field `self` sets wins, every other keeps `base`'s value.
    public func overlaid(on base: ServerConfigOverride) -> ServerConfigOverride {
        ServerConfigOverride(name: name ?? base.name, languageID: languageID ?? base.languageID,
                             languageIDs: languageIDs ?? base.languageIDs, extensions: extensions ?? base.extensions,
                             fileNames: fileNames ?? base.fileNames, command: command ?? base.command,
                             arguments: arguments ?? base.arguments,
                             initializationOptions: initializationOptions ?? base.initializationOptions,
                             enabled: enabled ?? base.enabled, role: role ?? base.role, clippy: clippy ?? base.clippy,
                             formatOnSave: formatOnSave ?? base.formatOnSave)
    }

    /// The overrides in force: built-in table, then plugins, then the user (the user's fields win over a plugin's).
    public static func layered(plugin: [String: ServerConfigOverride], user: [String: ServerConfigOverride]) -> [String: ServerConfigOverride] {
        guard !plugin.isEmpty else { return user }
        var out = plugin
        for (id, o) in user { out[id] = plugin[id].map { o.overlaid(on: $0) } ?? o }
        return out
    }
}
