import Foundation

/// How the app picks its theme: one theme always, or a light and a dark theme that follow the system.
public enum ThemeMode: String, Codable, Sendable { case single, matchSystem }

/// User settings at `<appSupport>/Alloy/settings.json`.
public struct AlloySettings: Codable, Equatable, Sendable {
    public var claudePath: String?

    /// The project opened last, used when Alloy is launched without a folder argument.
    public var lastProjectPath: String?

    /// Sessions share notes about files through Alloy's local MCP server.
    public var shareKnowledge: Bool

    /// With sharing on, notes and reads are also shared with every other project opened in Alloy; off keeps each
    /// project's knowledge to itself.
    public var shareAcrossProjects: Bool

    /// With sharing on, still ask before a session uses Alloy's tools (notes and coordination). The stored key keeps its
    /// original name so an older settings file still loads.
    public var askBeforeSharedNotes: Bool

    /// Show a session's edits in the right pane as they happen.
    public var followEdits: Bool

    public var themeMode: ThemeMode
    /// The theme id used in `.single` mode.
    public var theme: String
    /// The theme ids used in `.matchSystem` mode.
    public var lightTheme: String
    public var darkTheme: String

    /// Per-server overrides for the language server registry, keyed by server id. An unknown id with `command` and
    /// `extensions` adds a server.
    public var languageServers: [String: ServerConfigOverride]

    /// Glass on (the default) or off: off draws solid controls and an opaque window, no blur anywhere. The See-through and
    /// Blur values are kept while it is off.
    public var glass: Bool

    /// The user's look overrides, applied over the theme's style.
    public var appearance: AppearanceOverrides

    public init(claudePath: String? = nil, lastProjectPath: String? = nil,
                shareKnowledge: Bool = true, shareAcrossProjects: Bool = true, askBeforeSharedNotes: Bool = false, followEdits: Bool = true,
                themeMode: ThemeMode = .single, theme: String = "dracula",
                lightTheme: String = "alloy-light", darkTheme: String = "dracula",
                languageServers: [String: ServerConfigOverride] = [:],
                appearance: AppearanceOverrides = AppearanceOverrides(), glass: Bool = true) {
        self.glass = glass
        self.appearance = appearance
        self.languageServers = languageServers
        self.themeMode = themeMode
        self.theme = theme
        self.lightTheme = lightTheme
        self.darkTheme = darkTheme
        self.claudePath = claudePath
        self.lastProjectPath = lastProjectPath
        self.shareKnowledge = shareKnowledge
        self.shareAcrossProjects = shareAcrossProjects
        self.askBeforeSharedNotes = askBeforeSharedNotes
        self.followEdits = followEdits
    }

    private enum CodingKeys: String, CodingKey {
        case claudePath, lastProjectPath, shareKnowledge, shareAcrossProjects, askBeforeSharedNotes, followEdits, themeMode, theme, lightTheme, darkTheme, languageServers, appearance, glass
    }

    /// Every key is optional, so a file written by an older Alloy still loads with its values intact.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        lastProjectPath = try c.decodeIfPresent(String.self, forKey: .lastProjectPath)
        shareKnowledge = try c.decodeIfPresent(Bool.self, forKey: .shareKnowledge) ?? true
        shareAcrossProjects = try c.decodeIfPresent(Bool.self, forKey: .shareAcrossProjects) ?? true
        askBeforeSharedNotes = try c.decodeIfPresent(Bool.self, forKey: .askBeforeSharedNotes) ?? false
        followEdits = try c.decodeIfPresent(Bool.self, forKey: .followEdits) ?? true
        // The theme keys are lenient: a hand-edited bad value falls back to the default instead of failing the whole file
        // (which would make `load` return defaults and the next save wipe every other setting).
        themeMode = (try? c.decodeIfPresent(ThemeMode.self, forKey: .themeMode)) ?? .single
        theme = (try? c.decodeIfPresent(String.self, forKey: .theme)) ?? "dracula"
        lightTheme = (try? c.decodeIfPresent(String.self, forKey: .lightTheme)) ?? "alloy-light"
        darkTheme = (try? c.decodeIfPresent(String.self, forKey: .darkTheme)) ?? "dracula"
        appearance = (try? c.decodeIfPresent(AppearanceOverrides.self, forKey: .appearance)) ?? AppearanceOverrides()
        glass = try c.decodeIfPresent(Bool.self, forKey: .glass) ?? true
        // Entry by entry: one malformed override is dropped without losing the others.
        let lossy = (try? c.decodeIfPresent([String: LossyOverride].self, forKey: .languageServers)) ?? nil
        languageServers = (lossy ?? [:]).compactMapValues(\.value)
    }

    private struct LossyOverride: Decodable {
        var value: ServerConfigOverride?
        init(from decoder: Decoder) throws { value = try? ServerConfigOverride(from: decoder) }
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
