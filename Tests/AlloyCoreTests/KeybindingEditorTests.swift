@testable import AlloyCore
import Foundation
import Testing

@Suite struct KeybindingEditorTests {
    private func c(_ s: String) -> KeyChord { KeyChord.parse(s)! }
    private func editor(cmd: Bool = true) -> KeybindingEditor {
        KeybindingEditor(
            defaults: [("file.save", c("primary+s")), ("edit.cut", c("primary+x")), ("free", nil), ("other", c("ctrl+x"))],
            primaryIsCmd: cmd)
    }

    @Test func bindingToDefaultRemovesTheOverride() {
        #expect(editor().binding("file.save", to: c("primary+s"), overrides: ["file.save": "primary+j", "x": "y"]) == ["x": "y"])
    }

    @Test func bindingARecordedCmdChordToAPrimaryDefaultRemovesTheOverride() {
        #expect(editor().binding("file.save", to: c("cmd+s"), overrides: ["file.save": "cmd+j"]).isEmpty)
        #expect(editor(cmd: false).binding("file.save", to: c("ctrl+s"), overrides: ["file.save": "cmd+j"]).isEmpty)
        #expect(editor(cmd: false).binding("file.save", to: c("cmd+s"), overrides: [:]) == ["file.save": "cmd+s"])
    }

    @Test func bindingToOtherChordStoresCanonicalText() {
        #expect(editor().binding("free", to: c("shift+primary+k"), overrides: [:]) == ["free": "primary+shift+k"])
    }

    @Test func clearingADefaultlessCommandRemovesTheKey() {
        #expect(editor().clearing("free", overrides: ["free": "primary+k"]).isEmpty)
    }

    @Test func clearingStoresNone() {
        #expect(editor().clearing("file.save", overrides: [:]) == ["file.save": "none"])
    }

    @Test func resettingRemovesOneKey() {
        #expect(editor().resetting("file.save", overrides: ["file.save": "none", "free": "f5"]) == ["free": "f5"])
    }

    @Test func resetAllKeepsUnknownIdsAndBadValues() {
        let out = editor().resettingAll(overrides: ["ghost": "primary+x", "file.save": "none", "edit.cut": "garbage"])
        #expect(out == ["ghost": "primary+x"])
    }

    @Test func holderUsesRegistryOrder() {
        let e = KeybindingEditor(defaults: [("a", c("primary+k")), ("b", c("primary+j"))], primaryIsCmd: true)
        #expect(e.holder(of: c("primary+k"), excluding: "z", overrides: ["b": "primary+k"]) == "a")
        #expect(e.holder(of: c("primary+k"), excluding: "a", overrides: ["b": "primary+k"]) == "b")
    }

    @Test func ctrlAndPrimaryClashOffMacOnly() {
        #expect(editor(cmd: false).holder(of: c("primary+x"), excluding: "free", overrides: [:]) == "edit.cut")
        #expect(editor(cmd: false).holder(of: c("ctrl+x"), excluding: "free", overrides: [:]) == "edit.cut")
        #expect(editor(cmd: true).holder(of: c("ctrl+x"), excluding: "free", overrides: [:]) == "other")
        #expect(editor(cmd: true).holder(of: c("primary+x"), excluding: "edit.cut", overrides: [:]) == nil)
    }

    @Test func reassignWritesBothInOneValue() {
        let out = editor().reassigning(c("primary+x"), to: "free", from: "edit.cut", overrides: ["ghost": "f1"])
        #expect(out == ["free": "primary+x", "edit.cut": "none", "ghost": "f1"])
    }

    @Test func rebindingToItsOwnChordFindsNoHolder() {
        #expect(editor().holder(of: c("primary+s"), excluding: "file.save", overrides: [:]) == nil)
    }

    @Test func effectiveAndIsCustom() {
        let o = ["file.save": "none", "edit.cut": "bad", "free": "f5"]
        #expect(editor().effective("file.save", overrides: o) == nil)
        #expect(editor().effective("edit.cut", overrides: o) == c("primary+x"))
        #expect(editor().isCustom("file.save", overrides: o))
        #expect(!editor().isCustom("edit.cut", overrides: o))
        #expect(editor().isCustom("free", overrides: o))
        #expect(!editor().isCustom("other", overrides: o))
    }
}
