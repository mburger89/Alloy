import Foundation

/// How the app picks its theme: one theme always, or a light and a dark theme that follow the system.
public enum ThemeMode: String, Codable, Sendable { case single, matchSystem }

/// Git integration settings.
public struct GitSettings: Codable, Equatable, Sendable {
    public var gutterMarks: Bool
    public var statusColours: Bool
    /// Recompute gutter marks after a typing pause (off: marks update on save and outside changes only).
    public var liveMarks: Bool
    /// A git executable to use instead of the one found on `PATH`; empty means search.
    public var gitPath: String

    public init(gutterMarks: Bool = true, statusColours: Bool = true, liveMarks: Bool = false, gitPath: String = "") {
        self.gutterMarks = gutterMarks; self.statusColours = statusColours; self.liveMarks = liveMarks; self.gitPath = gitPath
    }

    private enum CodingKeys: String, CodingKey { case gutterMarks, statusColours, liveMarks, gitPath }

    /// Every key is optional and a wrong-typed value falls back to its default without losing the others.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gutterMarks = (try? c.decodeIfPresent(Bool.self, forKey: .gutterMarks)) ?? true
        statusColours = (try? c.decodeIfPresent(Bool.self, forKey: .statusColours)) ?? true
        liveMarks = (try? c.decodeIfPresent(Bool.self, forKey: .liveMarks)) ?? false
        gitPath = (try? c.decodeIfPresent(String.self, forKey: .gitPath)) ?? ""
    }
}

/// Tints the user's own unsaved edits (off by default). `colorHex` is a picked `#RRGGBB` or `#RRGGBBAA`; nil follows the
/// theme's "you" colour.
public struct OwnEditTint: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var colorHex: String?

    public init(enabled: Bool = false, colorHex: String? = nil) {
        self.enabled = enabled; self.colorHex = colorHex
    }

    private enum CodingKeys: String, CodingKey { case enabled, colorHex }

    /// Every key is optional and a wrong-typed value falls back to its default without losing the other.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        colorHex = (try? c.decodeIfPresent(String.self, forKey: .colorHex)) ?? nil
    }
}

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

    /// Show commands that cannot run right now (greyed) in the command palette. Off hides them.
    public var paletteShowsDisabled: Bool

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

    /// The background image each theme shows, by theme id: the stored file name under Alloy's Backgrounds folder, or the
    /// empty string to hide the image the theme file names. A theme with no entry shows its file's own image, if any.
    public var backgroundImages: [String: String]

    /// Git integration (gutter marks, status colours, git path).
    public var git: GitSettings

    /// The integrated terminal's preferences.
    public var terminal: TerminalSettings

    /// The most matches a project search collects before it stops (clamped to `searchResultRange`).
    public var searchMaxResults: Int

    /// Glob patterns excluded from every project search, on top of the search box's own exclude field.
    public var searchExcludes: [String]

    public static let searchResultRange = 100...50_000
    public static let defaultSearchMaxResults = 10_000

    /// Key overrides by command id: a canonical chord such as `primary+shift+p`, or `"none"` to unbind. Unknown ids are
    /// kept; malformed chords are ignored when resolved.
    public var keybindings: [String: String]

    /// The server that formats a language when it has a main server and linters: language id -> server id. A language with no entry uses the automatic choice.
    public var formatters: [String: String]

    /// The user's custom ACP agents (presets are built in). Secret names only; values live in the Keychain.
    public var agents: [AgentDefinition]

    /// The agent a new session uses when none is picked: a preset or custom agent id, nil for Claude.
    public var defaultAgentID: String?

    /// Installed plugins by plugin id.
    public var plugins: [String: PluginSetting]

    /// Tint the user's own unsaved edits, in the editor and in tables.
    public var ownEditTint: OwnEditTint

    public init(claudePath: String? = nil, lastProjectPath: String? = nil,
                shareKnowledge: Bool = true, shareAcrossProjects: Bool = true, askBeforeSharedNotes: Bool = false, followEdits: Bool = true, paletteShowsDisabled: Bool = true,
                themeMode: ThemeMode = .single, theme: String = "dracula",
                lightTheme: String = "alloy-light", darkTheme: String = "dracula",
                languageServers: [String: ServerConfigOverride] = [:],
                appearance: AppearanceOverrides = AppearanceOverrides(), glass: Bool = true,
                backgroundImages: [String: String] = [:], terminal: TerminalSettings = TerminalSettings(),
                keybindings: [String: String] = [:],
                searchMaxResults: Int = AlloySettings.defaultSearchMaxResults, searchExcludes: [String] = [],
                formatters: [String: String] = [:], git: GitSettings = GitSettings(),
                agents: [AgentDefinition] = [], defaultAgentID: String? = nil,
                plugins: [String: PluginSetting] = [:], ownEditTint: OwnEditTint = OwnEditTint()) {
        self.ownEditTint = ownEditTint
        self.plugins = plugins
        self.agents = agents
        self.defaultAgentID = defaultAgentID
        self.terminal = terminal
        self.git = git
        self.searchMaxResults = min(max(searchMaxResults, Self.searchResultRange.lowerBound), Self.searchResultRange.upperBound)
        self.searchExcludes = searchExcludes
        self.keybindings = keybindings
        self.formatters = formatters
        self.backgroundImages = backgroundImages
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
        self.paletteShowsDisabled = paletteShowsDisabled
    }

    private enum CodingKeys: String, CodingKey {
        case claudePath, lastProjectPath, shareKnowledge, shareAcrossProjects, askBeforeSharedNotes, followEdits, paletteShowsDisabled, themeMode, theme, lightTheme, darkTheme, languageServers, appearance, glass, backgroundImages, keybindings, searchMaxResults, searchExcludes, terminal, formatters, git, agents, defaultAgentID, plugins, ownEditTint
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
        paletteShowsDisabled = try c.decodeIfPresent(Bool.self, forKey: .paletteShowsDisabled) ?? true
        // The theme keys are lenient: a hand-edited bad value falls back to the default instead of failing the whole file
        // (which would make `load` return defaults and the next save wipe every other setting).
        themeMode = (try? c.decodeIfPresent(ThemeMode.self, forKey: .themeMode)) ?? .single
        theme = (try? c.decodeIfPresent(String.self, forKey: .theme)) ?? "dracula"
        lightTheme = (try? c.decodeIfPresent(String.self, forKey: .lightTheme)) ?? "alloy-light"
        darkTheme = (try? c.decodeIfPresent(String.self, forKey: .darkTheme)) ?? "dracula"
        appearance = (try? c.decodeIfPresent(AppearanceOverrides.self, forKey: .appearance)) ?? AppearanceOverrides()
        glass = try c.decodeIfPresent(Bool.self, forKey: .glass) ?? true
        backgroundImages = (try? c.decodeIfPresent([String: String].self, forKey: .backgroundImages)) ?? [:]
        formatters = (try? c.decodeIfPresent([String: String].self, forKey: .formatters)) ?? [:]
        terminal = (try? c.decodeIfPresent(TerminalSettings.self, forKey: .terminal)) ?? TerminalSettings()
        let maxResults = (try? c.decodeIfPresent(Int.self, forKey: .searchMaxResults)) ?? Self.defaultSearchMaxResults
        searchMaxResults = min(max(maxResults, Self.searchResultRange.lowerBound), Self.searchResultRange.upperBound)
        searchExcludes = (try? c.decodeIfPresent([String].self, forKey: .searchExcludes)) ?? []
        keybindings = (try? c.decodeIfPresent([String: String].self, forKey: .keybindings)) ?? [:]
        git = (try? c.decodeIfPresent(GitSettings.self, forKey: .git)) ?? GitSettings()
        defaultAgentID = (try? c.decodeIfPresent(String.self, forKey: .defaultAgentID)) ?? nil
        // Entry by entry: one malformed agent is dropped without losing the others.
        agents = ((try? c.decodeIfPresent([LossyAgent].self, forKey: .agents)) ?? nil)?.compactMap(\.value) ?? []
        // Entry by entry: one malformed override is dropped without losing the others.
        let lossy = (try? c.decodeIfPresent([String: LossyOverride].self, forKey: .languageServers)) ?? nil
        languageServers = (lossy ?? [:]).compactMapValues(\.value)
        ownEditTint = (try? c.decodeIfPresent(OwnEditTint.self, forKey: .ownEditTint)) ?? OwnEditTint()
        let lossyPlugins = (try? c.decodeIfPresent([String: LossyPlugin].self, forKey: .plugins)) ?? nil
        plugins = (lossyPlugins ?? [:]).compactMapValues(\.value)
    }

    private struct LossyPlugin: Decodable {
        var value: PluginSetting?
        init(from decoder: Decoder) throws { value = try? PluginSetting(from: decoder) }
    }

    private struct LossyAgent: Decodable {
        var value: AgentDefinition?
        init(from decoder: Decoder) throws { value = try? AgentDefinition(from: decoder) }
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

    public struct LoadResult: Sendable {
        public var settings: AlloySettings
        /// Where an unreadable file was moved to; nil when the file was missing or fine.
        public var movedAside: URL?
    }

    /// Missing or unreadable files give defaults. `claudePath` is exactly what was stored.
    public static func load(appSupport: URL) -> AlloySettings { loadReportingCorruption(appSupport: appSupport).settings }

    /// Like ``load(appSupport:)``, but a file that exists and does not decode is moved to
    /// `settings.json.corrupt-<unix seconds>` (never over an existing file) so a later save cannot destroy it.
    public static func loadReportingCorruption(appSupport: URL, now: () -> Date = Date.init) -> LoadResult {
        let file = url(appSupport: appSupport)
        guard let data = try? Data(contentsOf: file) else { return LoadResult(settings: AlloySettings(), movedAside: nil) }
        if let s = try? JSONDecoder().decode(AlloySettings.self, from: data) { return LoadResult(settings: s, movedAside: nil) }
        let fm = FileManager.default
        var stamp = Int(now().timeIntervalSince1970)
        var target = file.deletingLastPathComponent().appendingPathComponent("settings.json.corrupt-\(stamp)")
        while fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
            stamp += 1
            target = file.deletingLastPathComponent().appendingPathComponent("settings.json.corrupt-\(stamp)")
        }
        let moved = (try? fm.moveItem(at: file, to: target)) != nil
        return LoadResult(settings: AlloySettings(), movedAside: moved ? target : nil)
    }

    /// The notice shown when ``loadReportingCorruption(appSupport:now:)`` moved a file aside.
    public static func corruptNotice(movedTo url: URL) -> String {
        "settings.json was unreadable; moved aside as \(url.lastPathComponent). Defaults are in use."
    }

    /// Creates `<appSupport>/Alloy` with mode 0700 and tightens an existing one. A symlink is replaced by nothing: it is
    /// refused rather than followed.
    public static func ensureSupportDirectory(appSupport: URL) throws {
        let dir = appSupport.appendingPathComponent("Alloy")
        var info = stat()
        if lstat(dir.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    /// A non-empty `ALLOY_CLAUDE_PATH` wins over the stored `claudePath`. Never written back by `save`.
    public func effectiveClaudePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let env = environment["ALLOY_CLAUDE_PATH"], !env.isEmpty { return env }
        return claudePath
    }

    public func save(appSupport: URL) throws {
        let u = Self.url(appSupport: appSupport)
        try Self.ensureSupportDirectory(appSupport: appSupport)
        try JSONEncoder().encode(self).write(to: u, options: .atomic)
    }
}
