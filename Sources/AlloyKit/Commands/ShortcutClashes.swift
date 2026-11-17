import AlloyCore
import MetalUI

/// One thing a candidate chord would collide with.
struct ShortcutClash: Equatable {
    enum Kind: Equatable {
        /// Another registry command holds the chord (the one a "Reassign from X?" prompt names).
        case command(id: String)
        /// A MetalUI standard menu item (Quit, Copy, ...).
        case standardMenu
        /// A key the desktop takes first.
        case system
        /// A code view key that always applies; the built-in wins.
        case codeViewHard
        /// A code view key that applies only sometimes (`condition` says when).
        case codeViewSoft
    }

    var kind: Kind
    /// The holder's title: the command's, or the claim's (English).
    var title: String
    /// When a soft claim applies; nil otherwise.
    var condition: String?
}

/// Classifies a candidate chord against everything that already owns it: registry commands (by effective chord, with
/// the platform's `primary` resolution), MetalUI's standard menu items, the desktop's reserved keys and the code
/// view's built-in keys. Own `.command` claims from `App.commandShortcuts()` are never read: the registry is the
/// authority (hidden global keys are not menu items, and menu items can lag a rebind).
@MainActor
struct ShortcutClashes {
    let center: CommandCenter
    let platform: KeyboardShortcut.Platform
    private let codeViewKeys: [ClaimedShortcut]
    /// The standard menu claims, read once per classifier so a list of rows asks the app once.
    private let menuClaims: [ClaimedShortcut]

    init(center: CommandCenter, platform: KeyboardShortcut.Platform = .current) {
        self.center = center
        self.platform = platform
        codeViewKeys = CodeView.builtInKeyBindings(platform: platform)
        menuClaims = center.standardMenuClaims()
    }

    /// Everything `chord` collides with if bound to `id`, given the current `overrides`: registry holders first, then
    /// the standard menu, system keys and code view keys.
    func clashes(for chord: KeyChord, excluding id: String, overrides: [String: String]) -> [ShortcutClash] {
        var result: [ShortcutClash] = []
        let registry = center.registry
        let editor = KeybindingEditor(defaults: registry.commands.map { ($0.descriptor.id, $0.descriptor.shortcut) },
                                      primaryIsCmd: platform == .macOS)
        if let holder = editor.holder(of: chord, excluding: id, overrides: overrides) {
            let title = registry.command(id: holder)?.descriptor.title ?? holder
            result.append(ShortcutClash(kind: .command(id: holder), title: title, condition: nil))
        }
        let candidate = chord.shortcut(for: platform)
        for claim in menuClaims where claim.source == .standardMenu && claim.shortcut.conflicts(with: candidate) {
            result.append(ShortcutClash(kind: .standardMenu, title: claim.title, condition: nil))
        }
        for claim in KeyboardShortcut.systemReserved(on: platform) where claim.shortcut.conflicts(with: candidate) {
            result.append(ShortcutClash(kind: .system, title: claim.title, condition: nil))
        }
        for claim in codeViewKeys where claim.shortcut.conflicts(with: candidate) {
            result.append(ShortcutClash(kind: claim.isConditional ? .codeViewSoft : .codeViewHard, title: claim.title,
                                        condition: claim.condition))
        }
        return result
    }

    /// The read-only "Built-in" group: the code view's keys, then Alloy's own in-place keys.
    var builtInRows: [ClaimedShortcut] {
        let primary = platform.primaryModifiers
        let alloy = [
            ClaimedShortcut(title: "Close Settings or Quick Open", shortcut: KeyboardShortcut(.escape, modifiers: []), source: .command),
            ClaimedShortcut(title: "Find", shortcut: KeyboardShortcut("f", modifiers: primary), source: .command),
            ClaimedShortcut(title: "Send Message (composer)", shortcut: KeyboardShortcut(.return, modifiers: []), source: .command),
        ]
        return codeViewKeys + alloy
    }

    /// Whether a clash always wins over the binding (everything except the code view's conditional keys).
    var hard: (ShortcutClash) -> Bool { { $0.kind != .codeViewSoft } }
}
