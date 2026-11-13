import Foundation

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

    public init(name: String? = nil, languageID: String? = nil, languageIDs: [String: String]? = nil, extensions: [String]? = nil, fileNames: [String]? = nil,
                command: String? = nil, arguments: [String]? = nil, initializationOptions: JSONValue? = nil, enabled: Bool? = nil) {
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
