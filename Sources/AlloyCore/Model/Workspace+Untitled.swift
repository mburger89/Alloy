import Foundation
import MetalUICodeBuffer

/// Untitled documents (File > New File). One lives in `documents` and in a tab list under a reserved key
/// (`untitled:<n>`), and nothing that expects a file touches it: autosave never writes it, and git, the language
/// servers, plugins, the ledger, the outside-edit watcher, search and the saved layout all skip it. `untitledNumbers`
/// membership is the only test for "is Untitled" (see ``isUntitled(_:)``); the key's text is never parsed.
extension Workspace {
    /// The keys of the open Untitled documents.
    public var untitled: Set<String> { Set(untitledNumbers.keys) }

    public func isUntitled(_ path: String) -> Bool { untitledNumbers[path] != nil }

    /// The tab title: "Untitled", "Untitled 2"… for an Untitled key, the file name otherwise.
    public func title(of path: String) -> String {
        guard let number = untitledNumbers[path] else { return (path as NSString).lastPathComponent }
        return number == 1 ? "Untitled" : "Untitled \(number)"
    }

    /// Opens an empty, editable Untitled tab in `pane` (the default pane when nil), makes it active and returns its key.
    /// The number is the lowest free one. Autosave never writes it.
    @discardableResult
    public func newUntitled(in pane: PaneID? = nil) -> String {
        let pane = pane ?? defaultPane
        var number = 1
        let used = Set(untitledNumbers.values)
        while used.contains(number) { number += 1 }
        let key = "untitled:\(number)"
        let buffer = CodeBuffer(utf8: [UInt8]())
        let doc = EditorDocument(path: key, buffer: buffer, language: nil, state: .editable,
                                 diskStamp: FileStamp(modified: nil, size: 0))
        doc.isUntitled = true
        untitledNumbers[key] = number
        documents[key] = doc
        // Watched only so the tab's unsaved dot follows typing; the watch never schedules a save for it.
        autosave.watch(doc) { [weak self] d in self?.documents[d.path] === d }
        addTab(key, in: pane)
        setActive(key, in: pane)
        return key
    }

    /// True when the Untitled document has any text (an empty one closes without asking).
    public func untitledHasText(_ key: String) -> Bool {
        guard let doc = documents[key], isUntitled(key) else { return false }
        return doc.buffer.snapshot().utf8Count > 0
    }

    /// "Don't Save": drops the Untitled tab and its text, with no write.
    public func discardUntitled(_ key: String, in pane: PaneID? = nil) {
        guard isUntitled(key) else { return }
        let pane = pane ?? panesHolding(key).first ?? defaultPane
        dropUntitled(key, from: pane)
    }

    /// Every pane whose tab list holds `path`: Chat first, then the groups in tree order.
    func panesHolding(_ path: String) -> [PaneID] {
        var panes: [PaneID] = tabs.contains(path) ? [.chat] : []
        for id in codeLayout.tree.groupIDs where codeLayout.groups[id]?.tabs.contains(path) == true { panes.append(.group(id)) }
        return panes
    }

    /// Removes the tab and, with the last holder, the document and everything keyed by it.
    func dropUntitled(_ key: String, from pane: PaneID) {
        guard tabs(in: pane).contains(key) else { return }
        removeTab(key, from: pane)
        guard !holds(key) else { return }
        autosave.unwatch(key)
        documents.removeValue(forKey: key)
        untitledNumbers.removeValue(forKey: key)
        latestFold.removeValue(forKey: key)
        tabMessages.removeValue(forKey: key)
        syncGeneration.removeValue(forKey: key)
        saveEpoch.removeValue(forKey: key)
    }
}

/// What the user chose in the "Save changes to “Untitled”?" alert.
public enum UntitledChoice: Sendable { case save, discard, cancel }

/// The alert's state: which Untitled tab it asks about, and how to answer it (only the first answer counts).
public struct UntitledPrompt {
    public let key: String
    public let title: String
    let respond: @MainActor (UntitledChoice) -> Void

    public static let message = "Your changes will be lost if you don't save them."
    /// The alert's title for a tab called `title`.
    public static func question(for title: String) -> String { "Save changes to \u{201C}\(title)\u{201D}?" }

    @MainActor public func answer(_ choice: UntitledChoice) { respond(choice) }
}

extension Workspace {
    /// The Untitled tabs that hold text, in tab order: Chat's, then each group's in layout order.
    public func untitledKeysWithText() -> [String] {
        var order: [String] = tabs
        for id in codeLayout.tree.groupIDs { order += codeLayout.groups[id]?.tabs ?? [] }
        var seen = Set<String>()
        return order.filter { isUntitled($0) && untitledHasText($0) && seen.insert($0).inserted }
    }

    /// Settles an Untitled tab before it goes away. An empty one is dropped without asking. One with text asks Save… /
    /// Don't Save / Cancel (`untitledPrompt`, answered by the screen's alert): Save… runs the first-save flow, Don't Save
    /// drops the tab. Returns true when the tab is gone (saved or discarded) and false when the user cancelled, the save
    /// dialog was cancelled, or another question is already open. A tab also shown in another group just closes in this one.
    public func resolveUntitled(_ key: String, closing pane: PaneID? = nil) async -> Bool {
        guard isUntitled(key) else { return true }
        if let pane, panesHolding(key).count > 1 { dropUntitled(key, from: pane); return true }
        guard untitledHasText(key) else { discardUntitled(key); return true }
        guard untitledPrompt == nil else { return false }
        let choice: UntitledChoice = await withCheckedContinuation { continuation in
            untitledPrompt = UntitledPrompt(key: key, title: title(of: key)) { [weak self] choice in
                guard let self, untitledPrompt?.key == key else { return }
                untitledPrompt = nil
                continuation.resume(returning: choice)
            }
        }
        switch choice {
        case .discard: discardUntitled(key); return true
        case .cancel: return false
        case .save:
            guard let handler = saveUntitledHandler else { return false }
            return await handler(key)
        }
    }
}
