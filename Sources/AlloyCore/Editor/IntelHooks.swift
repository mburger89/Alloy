import Foundation

/// A code-intelligence action the menus and keys can run on the focused editor.
public enum IntelCommand: String, Sendable {
    case showHover, goToSymbol, findReferences, formatDocument, formatSelection, triggerCompletion, triggerSignature, quickFix, rename
    /// The focused editor's find bar: open it, and step to the next or previous match.
    case find, findNext, findPrevious
}

/// What the UI layer lets the app run for each ``IntelCommand``: a closure per command and whether it can run now.
/// The code panel installs them; the defaults run nothing and enable nothing.
public struct IntelHooks {
    public var run: [IntelCommand: @MainActor () -> Void] = [:]
    public var isEnabled: @MainActor (IntelCommand) -> Bool = { _ in false }

    public init() {}
}
