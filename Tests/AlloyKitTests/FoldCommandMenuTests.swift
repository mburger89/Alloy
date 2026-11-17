@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// The four fold commands: registration, the View > Folding submenu, chords and enabled state.
@MainActor @Suite struct FoldCommandMenuTests {
    private static let ids = ["editor.fold", "editor.unfold", "editor.foldAll", "editor.unfoldAll"]
    private func isDisabled(_ window: TestWindow, _ id: String) -> Bool {
        do { try window.testApp.performMenuBarItem(accessibilityIdentifier: "cmd-\(id)"); return false } catch { return true }
    }

    @Test func registersWithoutRejectionOrChordCollision() {
        let rig = Rig()
        let registry = testCenter(for: rig.workspace).registry
        for id in Self.ids {
            #expect(registry.command(id: id) != nil)
            #expect(!registry.rejections.contains { $0.id == id })
        }
        var seen: [KeyChord: String] = [:]
        for command in registry.commands {
            guard let chord = command.descriptor.shortcut else { continue }
            #expect(seen[chord] == nil, "\(command.descriptor.id) shares its chord with \(seen[chord] ?? "")")
            seen[chord] = command.descriptor.id
        }
    }

    @Test func viewMenuHoldsTheFoldingSubmenu() throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let view = try #require(window.testApp.menuBar.first { $0.title == "View" })
        let sub = view.items.compactMap { item -> [PlatformMenuItem]? in
            if case .submenu(let items) = item.kind, item.title == "Folding" { return items }
            return nil
        }.first
        let items = try #require(sub)
        #expect(items.map(\.title) == ["Fold", "Unfold", "Fold All", "Unfold All"])
        #expect(items.compactMap(\.accessibilityIdentifier) == Self.ids.map { "cmd-\($0)" })
        let left = "\u{f702}", right = "\u{f703}"
        #expect(items.map(\.shortcut) == [
            PlatformKeyEquivalent(key: left, modifiers: [.option, .command]),
            PlatformKeyEquivalent(key: right, modifiers: [.option, .command]),
            PlatformKeyEquivalent(key: left, modifiers: [.option, .shift, .command]),
            PlatformKeyEquivalent(key: right, modifiers: [.option, .shift, .command]),
        ])
    }

    @Test func disabledWithNoCodeViewAndRunFoldsOtherwise() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let registry = testCenter(for: rig.workspace).registry
        for id in Self.ids {
            #expect(isDisabled(window, id))
            #expect(!registry.run(id: id))
        }
        try "a\nb\nc\nd\n".write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        rig.workspace.openFilePath = "a.txt"
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        let fold = try #require(rig.workspace.foldState(for: "a.txt", in: .chat))
        fold.foldableRanges = [0..<3]
        #expect(registry.run(id: "editor.foldAll"))
        #expect(fold.folded == [0..<3])
        #expect(registry.run(id: "editor.unfoldAll"))
        #expect(fold.folded.isEmpty)
        #expect(registry.rejections.isEmpty)
    }
}
