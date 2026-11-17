import Foundation

/// Where a command came from. Built-ins register first and win every clash.
public enum CommandSource: Hashable, Codable, Sendable {
    case builtin
    case plugin(id: String)
}

/// The palette's category prefix ("Go: Quick Open").
public struct CommandCategory: Hashable, Codable, Sendable {
    public var name: String
    public init(name: String) { self.name = name }

    public static let app = CommandCategory(name: "App")
    public static let go = CommandCategory(name: "Go")
    public static let view = CommandCategory(name: "View")
    public static let tab = CommandCategory(name: "Tab")
    public static let session = CommandCategory(name: "Session")
    public static let edit = CommandCategory(name: "Edit")
    public static let file = CommandCategory(name: "File")
    public static let git = CommandCategory(name: "Git")
    public static let selection = CommandCategory(name: "Selection")
}

/// How a command's chord is delivered: through its menu item, through a hidden global key (always, or only in Code
/// mode), or not at all (palette only).
public enum CommandBinding: String, Hashable, Codable, Sendable {
    case menu, global, globalInCode, none
}

/// The menu a command appears in; nil means the palette only.
public enum MenuPlacement: String, Hashable, Codable, Sendable {
    case appSettings, edit, go, git, view, plugins
}

/// What a command is, with no closures: Codable and Sendable so it can be listed, tested and (later) shown in settings.
public struct CommandDescriptor: Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var category: CommandCategory
    /// The default chord; the user's overrides are applied by `Keymap`.
    public var shortcut: CommandShortcut?
    public var binding: CommandBinding
    public var menu: MenuPlacement?
    /// Whether running it moves it to the front of the project's recents.
    public var recordsRecent: Bool
    public var source: CommandSource
    public var menuAccessibilityID: String?
    public var keyAccessibilityID: String?

    public init(id: String, title: String, category: CommandCategory, shortcut: CommandShortcut? = nil,
                binding: CommandBinding = .none, menu: MenuPlacement? = nil, recordsRecent: Bool = false,
                source: CommandSource = .builtin, menuAccessibilityID: String? = nil, keyAccessibilityID: String? = nil) {
        self.id = id; self.title = title; self.category = category; self.shortcut = shortcut
        self.binding = binding; self.menu = menu; self.recordsRecent = recordsRecent; self.source = source
        self.menuAccessibilityID = menuAccessibilityID; self.keyAccessibilityID = keyAccessibilityID
    }

    public var menuID: String { menuAccessibilityID ?? "menu-\(id)" }
    public var keyID: String { keyAccessibilityID ?? "global-key-\(id)" }
    public var displayTitle: String { "\(category.name): \(title)" }
}
