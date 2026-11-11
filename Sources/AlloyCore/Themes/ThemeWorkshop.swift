import Foundation

/// One colour slot a theme file may set, with what it paints.
public struct ThemeSlotInfo: Equatable, Sendable {
    public let name: String
    public let purpose: String
    public init(name: String, purpose: String) {
        self.name = name
        self.purpose = purpose
    }
}

/// What the theme tools reach in the UI. AlloyKit's theme controller conforms to it.
@MainActor
public protocol ThemeWorkshop: AnyObject {
    /// Every slot a theme file may set, in display order.
    var slotCatalog: [ThemeSlotInfo] { get }
    var library: ThemeLibrary { get }
    /// The theme the app shows right now: the preview when one is active, else the user's active theme.
    var shownTheme: ResolvedTheme? { get }
    func preview(_ draft: ThemeFile, resolved: ResolvedTheme, session: UUID)
    /// Reloads the library and marks the preview saved when it matches `file`.
    func didSave(_ saved: SavedTheme, file: ThemeFile, session: UUID) async
    func themeSessionEnded(_ session: UUID)
}
