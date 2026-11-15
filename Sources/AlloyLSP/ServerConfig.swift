import AlloyCore
import Foundation

/// One configured language server. `ServerRegistry` holds the built-in table and applies settings overrides.
public struct ServerConfig: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var languageID: String
    /// Per-extension language ids (lowercased, no dot) that differ from `languageID`, e.g. `tsx` -> `typescriptreact`.
    public var languageIDs: [String: String]
    public var extensions: [String]
    public var fileNames: [String]
    public var command: String
    public var arguments: [String]
    public var initializationOptions: JSONValue?
    public var enabled: Bool
    public var role: ServerRole
    /// Answers to `workspace/configuration`, keyed by section ("" for a request with no section).
    public var configurationAnswers: [String: JSONValue]
    /// Config file names the project must have (in the file's folder or above) before this server runs. Glob-free; a
    /// trailing `*` suffix wildcard (`eslint.config.*`) is allowed. `file#key` means a key inside a JSON file.
    public var requiresConfigFiles: [String]
    /// rust-analyzer only: run Clippy instead of `cargo check`.
    public var clippy: Bool

    public init(id: String, name: String, languageID: String, languageIDs: [String: String] = [:], extensions: [String] = [], fileNames: [String] = [],
                command: String, arguments: [String] = [], initializationOptions: JSONValue? = nil, enabled: Bool = true,
                role: ServerRole = .main, configurationAnswers: [String: JSONValue] = [:], requiresConfigFiles: [String] = [], clippy: Bool = false) {
        self.id = id
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
        self.configurationAnswers = configurationAnswers
        self.requiresConfigFiles = requiresConfigFiles
        self.clippy = clippy
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, languageID, languageIDs, extensions, fileNames, command, arguments, initializationOptions, enabled
        case role, configurationAnswers, requiresConfigFiles, clippy
    }

    /// Fields added after v1 decode with their defaults when absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        languageID = try c.decode(String.self, forKey: .languageID)
        languageIDs = try c.decodeIfPresent([String: String].self, forKey: .languageIDs) ?? [:]
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? []
        fileNames = try c.decodeIfPresent([String].self, forKey: .fileNames) ?? []
        command = try c.decode(String.self, forKey: .command)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        initializationOptions = try c.decodeIfPresent(JSONValue.self, forKey: .initializationOptions)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        role = try c.decodeIfPresent(ServerRole.self, forKey: .role) ?? .main
        configurationAnswers = try c.decodeIfPresent([String: JSONValue].self, forKey: .configurationAnswers) ?? [:]
        requiresConfigFiles = try c.decodeIfPresent([String].self, forKey: .requiresConfigFiles) ?? []
        clippy = try c.decodeIfPresent(Bool.self, forKey: .clippy) ?? false
    }
}
