import Foundation
import AlloyCore

public struct PluginMain: Equatable, Sendable {
    public var command: String
    public var args: [String]
    public init(command: String, args: [String] = []) {
        self.command = command
        self.args = args
    }
}

/// An event that starts a scripted plugin's process.
public enum PluginActivation: Hashable, Sendable {
    case command(String), language(String), panel(String), mcpTool(String), startup
}

public struct PluginThemeRef: Equatable, Sendable {
    public var path: String
    public init(path: String) { self.path = path }
}

public enum PluginSettingType: Equatable, Sendable {
    case bool, string, number
    case enumeration([String])
}

public struct PluginSettingSpec: Equatable, Sendable {
    public var key: String
    public var title: String
    public var type: PluginSettingType
    public var defaultValue: JSONValue?
    public init(key: String, title: String, type: PluginSettingType, defaultValue: JSONValue? = nil) {
        self.key = key
        self.title = title
        self.type = type
        self.defaultValue = defaultValue
    }
}

/// When a plugin command is available.
public enum CommandWhen: Equatable, Sendable {
    case always, codeMode, editorFocused
    case language(String)
}

public struct PluginCommandSpec: Equatable, Sendable {
    public var id: String
    public var title: String
    public var shortcut: KeyChord?
    public var inPluginsMenu: Bool
    public var when: CommandWhen
    public init(id: String, title: String, shortcut: KeyChord? = nil, inPluginsMenu: Bool = false, when: CommandWhen = .always) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.inPluginsMenu = inPluginsMenu
        self.when = when
    }
}

public struct PluginTaskSpec: Equatable, Sendable {
    public var id: String
    public var title: String
    public var command: String
    public var args: [String]
    public var cwd: String?
    public init(id: String, title: String, command: String, args: [String] = [], cwd: String? = nil) {
        self.id = id
        self.title = title
        self.command = command
        self.args = args
        self.cwd = cwd
    }
}

public struct PluginPanelSpec: Equatable, Sendable {
    public var id: String
    public var title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct PluginMCPToolSpec: Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct PluginContributions: Equatable, Sendable {
    public var themes: [PluginThemeRef] = []
    public var languageServers: [String: ServerConfigOverride] = [:]
    public var settings: [PluginSettingSpec] = []
    public var commands: [PluginCommandSpec] = []
    public var taskCommands: [PluginTaskSpec] = []
    public var panels: [PluginPanelSpec] = []
    public var mcpTools: [PluginMCPToolSpec] = []
    public init() {}
}

/// A validated `alloy-plugin.json`.
public struct PluginManifest: Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var apiVersion: Int
    public var main: PluginMain?
    public var permissions: Set<PluginPermission>
    public var activationEvents: [PluginActivation]
    public var contributes: PluginContributions

    public var isScripted: Bool { main != nil }

    public init(id: String, name: String, version: String, description: String = "", apiVersion: Int = 1, main: PluginMain? = nil,
                permissions: Set<PluginPermission> = [], activationEvents: [PluginActivation] = [],
                contributes: PluginContributions = PluginContributions()) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.apiVersion = apiVersion
        self.main = main
        self.permissions = permissions
        self.activationEvents = activationEvents
        self.contributes = contributes
    }
}

public enum PluginManifestError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingManifest, tooLarge, notJSON
    case unknownKey(String)
    case invalidField(String, String)
    case mainOutsideFolder, mainMissing, mainNotExecutable
    case mainNotFoundOnPath(String)
    case symlinkEscape(String)
    case needsMain(String)
    case missingPermission(PluginPermission)
    case duplicate(String)

    public var description: String {
        switch self {
        case .missingManifest: "No alloy-plugin.json in the folder"
        case .tooLarge: "alloy-plugin.json is larger than 256 KiB"
        case .notJSON: "alloy-plugin.json is not a JSON object"
        case .unknownKey(let k): "Unknown key \"\(k)\""
        case .invalidField(let f, let why): "Invalid \(f): \(why)"
        case .mainOutsideFolder: "main.command points outside the plugin folder"
        case .mainMissing: "main.command does not exist"
        case .mainNotExecutable: "main.command is not executable"
        case .mainNotFoundOnPath(let c): "\"\(c)\" was not found on PATH"
        case .symlinkEscape(let p): "\"\(p)\" resolves outside the plugin folder"
        case .needsMain(let what): "\"\(what)\" need a main entry"
        case .missingPermission(let p): "Needs the \(p.rawValue) permission"
        case .duplicate(let what): "Duplicate \(what)"
        }
    }
}
