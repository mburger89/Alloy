import Foundation
import Observation

/// Names a list of open tabs: Chat's own list, or one editor group of Code mode.
public enum PaneID: Hashable, Codable, Sendable {
    case chat
    case group(UUID)
}

/// How a pane shows a file: the plain text, or its session edits inline or side by side.
public enum Presentation: String, Codable, Sendable {
    case plain, inline, sideBySide

    init(_ mode: DiffMode) {
        switch mode {
        case .inline: self = .inline
        case .sideBySide: self = .sideBySide
        }
    }
}

/// One editor group of Code mode: an ordered list of open file paths and the active one.
@MainActor @Observable
public final class EditorGroup: Identifiable {
    public let id: UUID
    public internal(set) var tabs: [String]
    public internal(set) var activeTab: String?

    public init(id: UUID = UUID(), tabs: [String] = [], activeTab: String? = nil) {
        self.id = id
        self.tabs = tabs
        self.activeTab = activeTab
    }
}

/// Code mode's editor groups and which one has focus. Starts with one empty group.
@MainActor @Observable
public final class CodeLayout {
    public internal(set) var groups: [UUID: EditorGroup]
    public internal(set) var focusedGroupID: UUID
    /// Stands in only if `focusedGroupID` ever names no group; `focus(_:)` keeps that from happening.
    private let fallbackGroup: EditorGroup
    /// Whether the chat column is folded to its strip. A change runs `onChatCollapsedChange` (the workspace schedules a state write).
    public var chatCollapsed = false {
        didSet { if chatCollapsed != oldValue { onChatCollapsedChange?() } }
    }
    @ObservationIgnored var onChatCollapsedChange: (() -> Void)?
    /// How the groups are split; leaves are the keys of `groups`.
    public internal(set) var tree: SplitTree

    public init() {
        let first = EditorGroup()
        groups = [first.id: first]
        focusedGroupID = first.id
        fallbackGroup = first
        tree = .group(first.id)
    }

    /// Moves focus to `id`; an id that is not a group is ignored.
    public func focus(_ id: UUID) {
        if groups[id] != nil { focusedGroupID = id }
    }

    public var focusedGroup: EditorGroup { groups[focusedGroupID] ?? fallbackGroup }
}
