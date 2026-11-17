import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import MetalUI
import Testing

/// The Built-in group mirrors CodeView's own key table, so it cannot drift from what the view runs.
@MainActor @Suite struct CodeViewBuiltInKeysTests {
    @Test(arguments: KeyboardShortcut.Platform.allCases)
    func builtInRowsEqualCodeViewBuiltInKeyBindingsPlusAlloyKeys(platform: KeyboardShortcut.Platform) throws {
        let rig = Rig()
        _ = try alloyWindow(rig.workspace)
        let rows = ShortcutClashes(center: testCenter(for: rig.workspace), platform: platform).builtInRows
        let codeView = CodeView.builtInKeyBindings(platform: platform)
        #expect(!codeView.isEmpty)
        #expect(rows.count == codeView.count + 3)
        #expect(Array(rows.prefix(codeView.count)) == codeView)
        for entry in codeView {
            #expect(rows.contains { $0.shortcut == entry.shortcut && $0.title == entry.title })
        }
        for extra in rows.dropFirst(codeView.count) {
            #expect(!codeView.contains { $0.shortcut == extra.shortcut && $0.title == extra.title })
            #expect(extra.source == .command)
        }
    }

    @Test func linuxAndWindowsShareOneList() {
        #expect(CodeView.builtInKeyBindings(platform: .linux) == CodeView.builtInKeyBindings(platform: .windows))
    }
}
