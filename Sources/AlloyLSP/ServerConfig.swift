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

    public init(id: String, name: String, languageID: String, languageIDs: [String: String] = [:], extensions: [String] = [], fileNames: [String] = [],
                command: String, arguments: [String] = [], initializationOptions: JSONValue? = nil, enabled: Bool = true) {
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
    }
}
