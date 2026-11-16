@testable import AlloyCore
import Foundation
import Testing

@Suite struct KeybindingSettingsTests {
    private func decode(_ json: String) throws -> AlloySettings {
        try JSONDecoder().decode(AlloySettings.self, from: Data(json.utf8))
    }

    @Test func missingKeyDecodesEmpty() throws {
        #expect(try decode("{\"theme\":\"x\"}").keybindings == [:])
    }

    @Test func malformedValueKeepsOtherFields() throws {
        let s = try decode("{\"theme\":\"x\",\"keybindings\":[1,2]}")
        #expect(s.keybindings == [:])
        #expect(s.theme == "x")
        let t = try decode("{\"theme\":\"x\",\"keybindings\":{\"a\":5}}")
        #expect(t.keybindings == [:] && t.theme == "x")
    }

    @Test func noneAndUnknownIdsSurviveSave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = AlloySettings(keybindings: ["file.save": "none", "ghost.command": "primary+shift+x", "bad": "shift"])
        try s.save(appSupport: dir)
        #expect(AlloySettings.load(appSupport: dir).keybindings == s.keybindings)
    }
}
