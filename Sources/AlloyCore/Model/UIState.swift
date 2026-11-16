import Foundation

/// Which screen the window shows.
public enum WorkspaceMode: String, Codable, Sendable { case chat, code }

/// The per-project window state kept in `ui-state.json`. Later tasks add fields the same way: read with
/// `decodeIfPresent` and a default, so a file written before the field existed still loads.
public struct UIState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let defaults = UIState(version: currentVersion, mode: .chat)

    public var version: Int
    public var mode: WorkspaceMode
    /// Split sizes in points by MetalUI autosave name (`code-main`, ...), one entry per pane.
    public var paneSizes: [String: [Double]]

    /// Whether Code mode's chat column is folded to its strip.
    public var chatCollapsed: Bool
    /// Code mode's split tree, groups, tabs and focus; nil until one was saved.
    public var layout: CodeLayoutState?
    /// Project-relative paths of the file tree's open folders.
    public var expandedFolders: [String]

    public init(version: Int = UIState.currentVersion, mode: WorkspaceMode = .chat, paneSizes: [String: [Double]] = [:],
                chatCollapsed: Bool = false, layout: CodeLayoutState? = nil, expandedFolders: [String] = []) {
        self.version = version; self.mode = mode; self.paneSizes = paneSizes
        self.chatCollapsed = chatCollapsed; self.layout = layout; self.expandedFolders = expandedFolders
    }

    private enum CodingKeys: String, CodingKey { case version, mode, paneSizes, chatCollapsed, layout, expandedFolders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        // An unknown mode string (a later Alloy's) falls back to Chat; it never makes the file corrupt.
        mode = (try? c.decodeIfPresent(WorkspaceMode.self, forKey: .mode)) ?? .chat
        paneSizes = (try? c.decodeIfPresent([String: [Double]].self, forKey: .paneSizes)) ?? [:]
        // Each later field is tolerant the same way: a malformed value gets its default, never a corrupt file.
        chatCollapsed = (try? c.decodeIfPresent(Bool.self, forKey: .chatCollapsed)) ?? false
        layout = (try? c.decodeIfPresent(CodeLayoutState.self, forKey: .layout)) ?? nil
        expandedFolders = (try? c.decodeIfPresent([String].self, forKey: .expandedFolders)) ?? []
    }
}

/// One editor group as saved: its tabs in order and the active one.
public struct GroupState: Codable, Equatable, Sendable {
    public var id: UUID
    public var tabs: [String]
    public var active: String?

    public init(id: UUID, tabs: [String], active: String?) { self.id = id; self.tabs = tabs; self.active = active }

    private enum CodingKeys: String, CodingKey { case id, tabs, active }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        tabs = (try? c.decodeIfPresent([String].self, forKey: .tabs)) ?? []
        active = (try? c.decodeIfPresent(String.self, forKey: .active)) ?? nil
    }
}

/// Code mode's editor layout as saved.
public struct CodeLayoutState: Codable, Equatable, Sendable {
    public var tree: SplitTree
    public var groups: [GroupState]
    public var focused: UUID

    public init(tree: SplitTree, groups: [GroupState], focused: UUID) {
        self.tree = tree; self.groups = groups; self.focused = focused
    }

    private enum CodingKeys: String, CodingKey { case tree, groups, focused }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tree = try c.decode(SplitTree.self, forKey: .tree)
        groups = (try? c.decodeIfPresent([GroupState].self, forKey: .groups)) ?? []
        // A missing focused id becomes the first group on restore.
        focused = (try? c.decodeIfPresent(UUID.self, forKey: .focused)) ?? tree.groupIDs.first ?? UUID()
    }
}

public enum UIStateFile {
    public enum Loaded: Equatable { case missing, corrupt, newer(Int), state(UIState) }

    /// Reads `url`. A file without a positive `version`, or that doesn't parse, is `.corrupt`; one from a newer
    /// Alloy is `.newer` (its other fields are not interpreted).
    public static func load(_ url: URL) -> Loaded {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int, version >= 1 else { return .corrupt }
        if version > UIState.currentVersion { return .newer(version) }
        guard let state = try? JSONDecoder().decode(UIState.self, from: data) else { return .corrupt }
        return .state(state)
    }

    public static func save(_ state: UIState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
