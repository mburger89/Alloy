@testable import AlloyCore
import Foundation
import Testing

@Suite struct CommandDescriptorTests {
    @Test func codableRoundTrip() throws {
        let d = CommandDescriptor(id: "go.quickOpen", title: "Quick Open", category: .go,
                                  shortcut: KeyChord.parse("primary+p"), binding: .global, menu: .go,
                                  recordsRecent: true, source: .plugin(id: "x"), menuAccessibilityID: "m", keyAccessibilityID: "k")
        let back = try JSONDecoder().decode(CommandDescriptor.self, from: JSONEncoder().encode(d))
        #expect(back == d)
    }

    @Test func displayTitleAndDefaultIDs() {
        let d = CommandDescriptor(id: "view.zoom", title: "Zoom In", category: .view)
        #expect(d.displayTitle == "View: Zoom In")
        #expect(d.menuID == "menu-view.zoom")
        #expect(d.keyID == "global-key-view.zoom")
        #expect(d.binding == .none && d.menu == nil && !d.recordsRecent && d.source == .builtin)
        let e = CommandDescriptor(id: "a", title: "A", category: .app, menuAccessibilityID: "menu-x", keyAccessibilityID: "global-key-y")
        #expect(e.menuID == "menu-x" && e.keyID == "global-key-y")
    }
}
